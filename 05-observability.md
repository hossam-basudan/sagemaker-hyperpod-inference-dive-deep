# 5. Observability

A HyperPod inference endpoint produces signals at four layers. Knowing which layer emits what tells you where to look.

| Layer | Source | Examples |
|---|---|---|
| Request (per pod) | `sidecar-reverse-proxy`, `:9113/metrics` | `model_invocations_total`, `model_errors_total`, `model_concurrent_requests`, `model_latency_milliseconds`, `model_ttfb_milliseconds`, `model_requests_received_total`, `model_requests_shed_total` |
| Model server | Your container, at `spec.metrics.modelMetrics.port` / `path` | vLLM `vllm:*` (queue, KV cache usage, prefix cache hits), TGI `tgi_*`, LMI djl-serving metrics |
| Endpoint | CloudWatch `AWS/SageMaker` | `Invocations` and error counts for the SageMaker AI endpoint |
| Control plane | Operator logs, optionally in CloudWatch Logs | Reconcile errors, certificate and endpoint creation |

Request metrics carry labels such as `cluster_name`, `namespace`, `resource_name`, `resource_type` (`inference-endpoint` or `jumpstart`), `model_name`, `pod_name`, `node_name`, `instance_type`, and `metric_source` (`reverse-proxy` or `model-container`).

## Metrics settings in the custom resource

```yaml
spec:
  metrics:
    enabled: true                    # default; also required for request limits
    metricsScrapeIntervalSeconds: 15 # 5–300
    modelMetrics:
      port: 8000                     # default 8080. Use the vLLM API port for upstream vLLM
      path: /metrics
```

Check the scrape status for a deployment:

```bash
export ENDPOINT_NAME=tinyllama-dd
kubectl get inferenceendpointconfig $ENDPOINT_NAME -n $NAMESPACE -o jsonpath='{.status.metricsStatus}' | jq
```

## Lab: read the raw metrics

```bash
POD=$(kubectl get pods -n $NAMESPACE -l app=$ENDPOINT_NAME -o jsonpath='{.items[0].metadata.name}')

# Request metrics from the reverse-proxy sidecar
kubectl port-forward pod/$POD 9113:9113 -n $NAMESPACE >/dev/null & PF=$!
until curl -s -o /dev/null localhost:9113/metrics; do sleep 1; done
curl -s localhost:9113/metrics | grep -E '^model_(invocations_total|errors_total|concurrent_requests|latency_milliseconds_(sum|count))'
kill $PF

# Model-server metrics from vLLM itself
kubectl port-forward pod/$POD 8000:8000 -n $NAMESPACE >/dev/null & PF=$!
until curl -s -o /dev/null localhost:8000/health; do sleep 1; done
curl -s localhost:8000/metrics | grep -E '^vllm:(num_requests_(running|waiting)|gpu_cache_usage_perc|kv_cache_usage_perc|prefix_cache_hits_total)'
kill $PF
```

Read the sidecar logs when requests vanish between the ALB and the model. Without the observability add-on, `otel-collector` logs `Exporting failed` repeatedly; that's expected, because it has nowhere to send metrics:

```bash
kubectl logs $POD -n $NAMESPACE -c sidecar-reverse-proxy --tail=20
kubectl logs $POD -n $NAMESPACE -c otel-collector --tail=20
```

## Metrics in Prometheus and dashboards

The **HyperPod observability** add-on collects these metrics, plus GPU, node, and cluster metrics, into Amazon Managed Service for Prometheus. With Amazon Managed Grafana it also ships dashboards, including an **Inference** dashboard: request rate, success rate, latency, time to first token, token throughput, errors, and pod and node allocation.

<details open>
<summary><b>Query Prometheus (workshop accounts)</b></summary>

Workshop accounts can't sign in to Grafana, because it needs IAM Identity Center. Query the same metrics the dashboard plots. This needs the add-on from the optional step of [0. Set up your environment](00-setup.md#optional-prometheus-metrics):

```bash
export AMP_ENDPOINT=$(aws eks describe-addon --cluster-name $EKS_CLUSTER_NAME \
  --addon-name amazon-sagemaker-hyperpod-observability --region $REGION \
  --query addon.configurationValues --output text | jq -r '.ampWorkspace.prometheusEndpoint | rtrimstr("/")')
pip install -q awscurl
promql() {  # usage: promql '<query>'
  awscurl --service aps --region $REGION -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "query=$1" $AMP_ENDPOINT/api/v1/query | jq -c '[.data.result[] | {labels: .metric | del(.__name__), value: .value[1]}]'
}

promql 'sum(rate(model_invocations_total{resource_name="tinyllama-dd"}[5m]))'          # requests per second
promql 'histogram_quantile(0.95, sum by (le) (rate(model_latency_milliseconds_bucket{resource_name="tinyllama-dd"}[5m])))'   # p95 latency, ms
promql 'histogram_quantile(0.5, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket{resource_name="tinyllama-dd"}[5m])))'  # median time to first token, s
promql 'max(vllm:kv_cache_usage_perc{resource_name="tinyllama-dd"})'                     # KV cache in use, 0 to 1
promql 'max by (hostname) (DCGM_FI_DEV_GPU_UTIL)'                                         # GPU utilization per node, %
```

Rerun the load generator from module 4 and query again: request rate, latency, and GPU utilization climb. Prometheus queries are SigV4-signed HTTP calls, which `awscurl` signs with your credentials. The `-X POST` form keeps PromQL's braces and quotes out of the URL.

</details>

<details>
<summary><b>Grafana (your own account)</b></summary>

1. In the SageMaker AI console, open **HyperPod clusters**, select your cluster, and install observability from the **Dashboard** tab. Grafana needs IAM Identity Center in the account.
2. Open the Grafana workspace link, then **Dashboards** → **Inference**.
3. Filter to `tinyllama-dd` and run the load generator from module 4 with the autoscaling spec applied. You'll see request rate and concurrency climb, then replicas follow.

You can also open the dashboards with the HyperPod CLI: `hyp observability view`.

</details>


## Lab: protect the model with request limits

An overloaded LLM server doesn't fail fast. It queues until every request times out. `worker.requestLimits` makes the reverse proxy reject excess requests immediately, so clients can back off and the autoscaler gets a clean signal.

```bash
kubectl patch inferenceendpointconfig $ENDPOINT_NAME -n $NAMESPACE --type merge -p '{
  "spec": {"worker": {"requestLimits": {
    "maxConcurrentRequests": 4,
    "maxQueueSize": 4,
    "overflowStatusCode": 503
  }}}
}'
```

| Field | Meaning |
|---|---|
| `maxConcurrentRequests` | Requests in flight to the model, per pod |
| `maxQueueSize` | Requests allowed to wait (up to 60 s) when the concurrency limit is reached |
| `overflowStatusCode` | Returned when the queue is full (default 429) |

Changing `worker` fields triggers a **rolling update**: the operator starts a new pod with the limits and removes the old one once the new pod is ready. Wait for it, otherwise the old pod (without limits) answers your test:

```bash
kubectl rollout status deployment/$ENDPOINT_NAME -n $NAMESPACE --timeout=10m
```

> [!WARNING]
> The rollout surges one extra pod, so it needs a free GPU. With two `ml.g5.2xlarge` nodes, make sure only `tinyllama-dd` is running before you patch.

Send 32 concurrent requests. With 4 in flight and 4 queued per replica, at least 8 return `OK` and most of the rest `SHED`. The split changes from run to run (8/24 and 12/20 in testing), because the 32 calls don't arrive at the same instant and every finished request frees a slot:

```bash
seq 32 | xargs -P 32 -I{} sh -c '
  aws sagemaker-runtime invoke-endpoint --endpoint-name '"$ENDPOINT_NAME"' --region '"$REGION"' \
    --content-type application/json --cli-binary-format raw-in-base64-out \
    --body "{\"model\":\"tinyllama\",\"messages\":[{\"role\":\"user\",\"content\":\"Count to 200.\"}],\"max_tokens\":512}" \
    /dev/null >/dev/null 2>&1 && echo OK || echo SHED' | sort | uniq -c
```

Confirm on the sidecar that the proxy shed the requests, not the model:

```bash
POD=$(kubectl get pods -n $NAMESPACE -l app=$ENDPOINT_NAME -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward pod/$POD 9113:9113 -n $NAMESPACE >/dev/null & PF=$!
until curl -s -o /dev/null localhost:9113/metrics; do sleep 1; done
curl -s localhost:9113/metrics | grep -E '^model_requests_(received|shed)_total'
kill $PF
```

Remove the limits:

```bash
kubectl patch inferenceendpointconfig $ENDPOINT_NAME -n $NAMESPACE --type json \
  -p '[{"op":"remove","path":"/spec/worker/requestLimits"}]'
kubectl rollout status deployment/$ENDPOINT_NAME -n $NAMESPACE --timeout=10m
```

## Endpoint metrics in CloudWatch

List what CloudWatch has for your SageMaker AI endpoint (`Invocations`, `ModelLatency`, `OverheadLatency`, `Invocation4XXErrors`, `Invocation5XXErrors`, `InvocationModelErrors`, `ConcurrentRequestsPerModel`, and more), then read the invocation count from the module 4 load test:

```bash
aws cloudwatch list-metrics --namespace AWS/SageMaker \
  --dimensions Name=EndpointName,Value=$ENDPOINT_NAME --region $REGION \
  --query 'Metrics[].MetricName' --output text | tr '\t' '\n' | sort -u

aws cloudwatch get-metric-statistics --namespace AWS/SageMaker --metric-name Invocations \
  --dimensions Name=EndpointName,Value=$ENDPOINT_NAME Name=VariantName,Value=AllTraffic \
  --start-time $(date -u -d '-1 hour' +%FT%TZ 2>/dev/null || date -u -v-1H +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) --period 60 --statistics Sum --region $REGION \
  --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Sum]' --output text
```

## Operator logs in CloudWatch Logs

Operator logs normally live only in the controller pod. Turn on CloudWatch publishing in the add-on configuration so they survive pod restarts.

> [!WARNING]
> `aws eks update-addon --configuration-values` **replaces** the whole configuration. The command below merges the new setting into the current configuration so that roles and buckets are preserved.

```bash
CURRENT=$(aws eks describe-addon --cluster-name $EKS_CLUSTER_NAME \
  --addon-name amazon-sagemaker-hyperpod-inference --region $REGION \
  --query addon.configurationValues --output text)

echo "$CURRENT" | jq '. * {"logging": {"cloudWatch": {"enabled": true, "logLevel": "info"}}}' > addon-config-logging.json
diff <(echo "$CURRENT" | jq -S .) <(jq -S . addon-config-logging.json) || true   # only "logging" should be added

aws eks update-addon --cluster-name $EKS_CLUSTER_NAME \
  --addon-name amazon-sagemaker-hyperpod-inference --region $REGION \
  --configuration-values file://addon-config-logging.json
```

Once the add-on returns to `ACTIVE`:

```bash
aws logs describe-log-groups --log-group-name-prefix /aws/hyperpod/ --region $REGION \
  --query 'logGroups[].logGroupName' --output text | tr '\t' '\n' | grep inference-operator
```
