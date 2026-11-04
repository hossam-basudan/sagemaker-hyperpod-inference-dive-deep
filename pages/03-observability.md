# 3. Observability

In this lab you read the metrics and logs of the `tinyllama-dd` endpoint from lab 1, protect it from overload with request limits, and turn on operator logs in CloudWatch Logs. When an endpoint is slow or failing, these signals tell you whether the cause is the request path, the model server, or the operator.

What you need:

- The `tinyllama-dd` endpoint from lab 1, running, and no other model on the GPU nodes (lab 2's "Free the second GPU" step and clean up leave it that way).
- For the Prometheus queries only: the observability add-on from [lab 0, "Optional: Prometheus metrics"](00-setup.md#optional-prometheus-metrics). Every other step works without it.
- Some recent traffic helps: the CloudWatch step reads the load test from lab 2.

## Where the signals come from

A HyperPod inference endpoint produces signals at four layers. Knowing which layer emits what tells you where to look. For reference; nothing to run.

| Layer | Source | Examples |
|---|---|---|
| Request (per pod) | `sidecar-reverse-proxy`, `:9113/metrics` | `model_invocations_total`, `model_errors_total`, `model_concurrent_requests`, `model_latency_milliseconds`, `model_ttfb_milliseconds`, `model_requests_received_total`, `model_requests_shed_total` |
| Model server | Your container, at `spec.metrics.modelMetrics.port` / `path` | vLLM `vllm:*` (queue, KV cache usage, prefix cache hits), TGI `tgi_*`, LMI djl-serving metrics |
| Endpoint | CloudWatch `AWS/SageMaker` | `Invocations` and error counts for the SageMaker AI endpoint |
| Control plane | Operator logs, optionally in CloudWatch Logs | Reconcile errors, certificate and endpoint creation |

- The **reverse-proxy sidecar** is a container the operator adds to every model pod. Requests pass through it before they reach the model, so it can count them, time them, and limit them.
- The **model server** (here vLLM) publishes its own metrics, such as how many requests wait in its queue and how full its KV cache is (the GPU memory that holds the attention state of requests in flight).
- `ttfb` is time to first byte; for a streaming LLM response, that's close to time to first token.

Request metrics carry labels such as `cluster_name`, `namespace`, `resource_name`, `resource_type` (`inference-endpoint` or `jumpstart`), `model_name`, `pod_name`, `node_name`, `instance_type`, and `metric_source` (`reverse-proxy` or `model-container`). You filter on these labels in queries, for example `resource_name="tinyllama-dd"`.

## Metrics settings in the custom resource

Metrics are on by default. The `spec.metrics` block of an `InferenceEndpointConfig` controls them. For reference; nothing to run:

```yaml
spec:
  metrics:
    enabled: true                    # default; also required for request limits
    metricsScrapeIntervalSeconds: 15 # 5–300
    modelMetrics:
      port: 8000                     # default 8080. Use the vLLM API port for upstream vLLM
      path: /metrics
```

The command below sets `ENDPOINT_NAME` for the rest of this page and prints the metrics status the operator reports for `tinyllama-dd`:

```bash
export ENDPOINT_NAME=tinyllama-dd
kubectl get inferenceendpointconfig $ENDPOINT_NAME -n $NAMESPACE -o jsonpath='{.status.metricsStatus}' | jq
```

Expected: a short JSON object describing the metrics setup for the endpoint, with no error message in it. If it prints nothing, check that `tinyllama-dd` exists with `kubectl get inferenceendpointconfig -n $NAMESPACE`.

## Lab: read the raw metrics

Before you use dashboards or queries, look at the raw metrics the pod exposes. That's what every other tool reads.

The command below finds the model pod, opens a temporary port-forward to the sidecar (port 9113) and prints its request metrics, then does the same for vLLM's own metrics (port 8000). Each port-forward is closed when its part is done.

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

Expected: two groups of lines in Prometheus text format, `metric_name{labels} value`:

- From the sidecar: `model_invocations_total`, `model_concurrent_requests`, and the latency `_sum` and `_count`. Counters count since the pod started, so after the lab 2 load test `model_invocations_total` is in the hundreds. `model_errors_total` may be missing if there were no errors.
- From vLLM: `vllm:num_requests_running` and `vllm:num_requests_waiting` (0 when idle), KV cache usage between 0 and 1, and the prefix cache hit counter. Which of `gpu_cache_usage_perc` and `kv_cache_usage_perc` appears depends on the vLLM version.

The sidecar logs show each request as it passes through the proxy; read them when requests vanish between the load balancer and the model. The `otel-collector` container ships metrics to Prometheus. The command below prints the last 20 lines of each:

```bash
kubectl logs $POD -n $NAMESPACE -c sidecar-reverse-proxy --tail=20
kubectl logs $POD -n $NAMESPACE -c otel-collector --tail=20
```

Expected: recent log lines from each container. Without the observability add-on, `otel-collector` logs `Exporting failed` repeatedly. That's expected: it has nowhere to send the metrics.

## Metrics in Prometheus and dashboards

The **HyperPod observability** add-on collects these metrics, plus GPU, node, and cluster metrics, into **Amazon Managed Service for Prometheus**, an AWS-managed, Prometheus-compatible metrics store. With Amazon Managed Grafana it also ships dashboards, including an **Inference** dashboard: request rate, success rate, latency, time to first token, token throughput, errors, and pod and node allocation.

Use the first tab in a workshop account. The second tab is for your own account, with Grafana.

<details open>
<summary><b>Query Prometheus (workshop accounts)</b></summary>

Workshop accounts can't sign in to Grafana, because it needs IAM Identity Center. Instead, you query the same metrics the dashboard plots, with **PromQL** (the Prometheus query language).

This tab needs the add-on from the optional step of [0. Set up your environment](00-setup.md#optional-prometheus-metrics). If you didn't install it, skip to [Lab: protect the model with request limits](#lab-protect-the-model-with-request-limits).

The command below finds your workspace URL, installs `awscurl`, defines a small `promql` helper, and runs five queries. Requests to Amazon Managed Service for Prometheus must be signed with **SigV4** (AWS Signature Version 4, the way AWS APIs authenticate a request with your credentials); `awscurl` signs them. The `-X POST` form keeps PromQL's braces and quotes out of the URL.

```bash
export AMP_ENDPOINT=$(aws eks describe-addon --cluster-name $EKS_CLUSTER_NAME \
  --addon-name amazon-sagemaker-hyperpod-observability --region $REGION \
  --query addon.configurationValues --output text | jq -r '.ampWorkspace.prometheusEndpoint | rtrimstr("/")')
pip install -q awscurl
promql() {  # usage: promql '<title>' '<query>': prints the title, then one line per result
  echo "$1:"
  awscurl --service aps --region $REGION -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "query=$2" $AMP_ENDPOINT/api/v1/query \
  | jq -r 'if (.data.result | length) == 0 then "  (no data yet)" else .data.result[]
      | "  \(.metric | del(.__name__) | to_entries | map("\(.key)=\(.value)") | join(" ") | if . == "" then "total" else . end): \(.value[1] | if test("NaN|Inf") then "no traffic" else (tonumber * 100 | round / 100 | tostring) end)" end'
}

promql 'Requests per second' 'sum(rate(model_invocations_total{resource_name="tinyllama-dd"}[5m]))'
promql 'p95 latency (ms)' 'histogram_quantile(0.95, sum by (le) (rate(model_latency_milliseconds_bucket{resource_name="tinyllama-dd"}[5m])))'
promql 'Median time to first token (s)' 'histogram_quantile(0.5, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket{resource_name="tinyllama-dd"}[5m])))'
promql 'KV cache in use (0 to 1)' 'max(vllm:kv_cache_usage_perc{resource_name="tinyllama-dd"})'
promql 'GPU utilization per node (%)' 'max by (hostname) (DCGM_FI_DEV_GPU_UTIL)'
```

Expected: each title followed by one or more indented lines. With no recent traffic:

- Requests per second shows `total: 0`.
- Latency and time to first token show `no traffic`, because there is nothing to compute a percentile from.
- GPU utilization shows one line per GPU node (`hostname=...`), near 0.
- `(no data yet)` means the workspace has no samples for that metric yet. Wait a minute and run it again.

If the first line fails with `ResourceNotFoundException`, the add-on isn't installed; skip this tab.

To see the numbers move, generate load: go back to lab 2 and run its "Generate load" command once more (it runs 8 minutes in the background; the endpoint stays at 1 replica because lab 2's clean up removed autoscaling). Wait about 2 minutes, then run the command above again. Expected: requests per second around 1, latency and time to first token with real values, and GPU utilization up on the node that runs `tinyllama-dd`. Let the load finish (or stop it with `pkill -f load.sh`) before the request limits lab.

</details>

<details>
<summary><b>Grafana (your own account)</b></summary>

1. In the SageMaker AI console, open **HyperPod clusters**, select your cluster, and install observability from the **Dashboard** tab. Grafana needs IAM Identity Center in the account.
2. Open the Grafana workspace link, then **Dashboards** → **Inference**.
3. Filter to `tinyllama-dd`. Apply the autoscaling spec from lab 2 and run its load generator. You'll see request rate and concurrency climb, then replicas follow.

You can also open the dashboards with the HyperPod CLI: `hyp observability view`.

</details>


## Lab: protect the model with request limits

An overloaded LLM server doesn't fail fast. It queues requests until every one of them times out. `worker.requestLimits` makes the reverse-proxy sidecar reject excess requests immediately instead. Clients get a fast error they can retry, and the autoscaler gets a clean signal.

The fields, for reference:

| Field | Meaning |
|---|---|
| `maxConcurrentRequests` | Requests in flight to the model, per pod |
| `maxQueueSize` | Requests allowed to wait (up to 60 s) when the concurrency limit is reached |
| `overflowStatusCode` | Returned when the queue is full (default 429) |

> [!WARNING]
> Changing the limits restarts the model with a rolling update, which starts one extra pod and so needs a free GPU. Before you patch, make sure only `tinyllama-dd` is running (lab 2's "Free the second GPU" step) and that lab 2's autoscaling spec is removed.

The command below sets the limits on `tinyllama-dd`: 4 requests in flight, 4 more queued, and HTTP 503 for anything beyond that:

```bash
kubectl patch inferenceendpointconfig $ENDPOINT_NAME -n $NAMESPACE --type merge -p '{
  "spec": {"worker": {"requestLimits": {
    "maxConcurrentRequests": 4,
    "maxQueueSize": 4,
    "overflowStatusCode": 503
  }}}
}'
```

Expected: a line ending in `tinyllama-dd patched`.

Changing `worker` fields triggers a **rolling update**: the operator starts a new pod with the limits and removes the old one once the new pod is ready. Wait for it; otherwise the old pod, without limits, answers your test. The command below waits until the rollout finishes:

```bash
kubectl rollout status deployment/$ENDPOINT_NAME -n $NAMESPACE --timeout=10m
```

Expected: after a few minutes (the new pod loads the model), `deployment "tinyllama-dd" successfully rolled out`. If it times out, run `kubectl get pods -n $NAMESPACE`: a new pod stuck in `Pending` means no GPU is free (see the alert above).

The command below sends 32 requests at the same time and counts how many succeeded (`OK`) and how many failed (`SHED`):

```bash
seq 32 | xargs -P 32 -I{} sh -c '
  aws sagemaker-runtime invoke-endpoint --endpoint-name '"$ENDPOINT_NAME"' --region '"$REGION"' \
    --content-type application/json --cli-binary-format raw-in-base64-out \
    --body "{\"model\":\"tinyllama\",\"messages\":[{\"role\":\"user\",\"content\":\"Count to 200.\"}],\"max_tokens\":512}" \
    /dev/null >/dev/null 2>&1 && echo OK || echo SHED' | sort | uniq -c
```

Expected, within about a minute: two counts, such as `8 OK` and `24 SHED`. With 4 in flight and 4 queued, at least 8 succeed and most of the rest are shed. The split changes from run to run (8/24 and 12/20 in testing), because the 32 calls don't arrive at the same instant and every finished request frees a slot.

`SHED` here means any failed call. The next step confirms that the failures came from the proxy's limit. The command below reads the sidecar's counters from the new pod:

```bash
POD=$(kubectl get pods -n $NAMESPACE -l app=$ENDPOINT_NAME -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward pod/$POD 9113:9113 -n $NAMESPACE >/dev/null & PF=$!
until curl -s -o /dev/null localhost:9113/metrics; do sleep 1; done
curl -s localhost:9113/metrics | grep -E '^model_requests_(received|shed)_total'
kill $PF
```

Expected: `model_requests_received_total` around 32 and `model_requests_shed_total` close to your `SHED` count. The proxy rejected those requests before they reached the model.

The command below removes the limits and waits for the second rolling update (a few minutes):

```bash
kubectl patch inferenceendpointconfig $ENDPOINT_NAME -n $NAMESPACE --type json \
  -p '[{"op":"remove","path":"/spec/worker/requestLimits"}]'
kubectl rollout status deployment/$ENDPOINT_NAME -n $NAMESPACE --timeout=10m
```

Expected: `tinyllama-dd patched`, then `deployment "tinyllama-dd" successfully rolled out`.

## Endpoint metrics in CloudWatch

SageMaker AI publishes metrics for the endpoint to CloudWatch in the `AWS/SageMaker` namespace, once per minute. These work without the observability add-on; lab 2 scaled on one of them.

The command below lists the metrics CloudWatch has for `tinyllama-dd`:

```bash
echo "CloudWatch metrics for $ENDPOINT_NAME:"
aws cloudwatch list-metrics --namespace AWS/SageMaker \
  --dimensions Name=EndpointName,Value=$ENDPOINT_NAME --region $REGION \
  --query 'Metrics[].MetricName' --output text | tr '\t' '\n' | sort -u | sed 's/^/  /'
```

Expected: `Invocations`, `ModelLatency`, `OverheadLatency`, `Invocation4XXErrors`, `Invocation5XXErrors`, `InvocationModelErrors`, `ConcurrentRequestsPerModel`, and a few more.

The command below reads the invocations per minute over the last hour. It prints only the minutes with traffic, each with a bar (one `#` per 5 requests), then a total:

```bash
aws cloudwatch get-metric-statistics --namespace AWS/SageMaker --metric-name Invocations \
  --dimensions Name=EndpointName,Value=$ENDPOINT_NAME Name=VariantName,Value=AllTraffic \
  --start-time $(date -u -d '-1 hour' +%FT%TZ 2>/dev/null || date -u -v-1H +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) --period 60 --statistics Sum --region $REGION --output json \
| jq -r '[.Datapoints[] | select(.Sum > 0)] | sort_by(.Timestamp)
    | if length == 0 then "No invocations in the last hour: run the load test from lab 2 first."
      else "UTC    REQUESTS",
           (.[] | "\(.Timestamp[11:16])  \(.Sum | floor | tostring | " " * (8 - length) + .)  \("#" * ((.Sum / 5) | ceil))"),
           "Total: \(map(.Sum) | add | floor) requests in \(length) minutes, peak \(map(.Sum) | max | floor) per minute"
      end'
```

Expected: a lab 2 load test from the last hour shows as a block of about 8 busy minutes, around 70 requests per minute from 8 parallel clients. The 32-request burst from the request limits lab shows as one short minute. If it prints `No invocations in the last hour` (the message says "lab 2", meaning lab 2), run lab 2's "Generate load" command, wait 2 or 3 minutes, and run this again.

## Operator logs in CloudWatch Logs

The operator's logs record each reconcile step and error, for example why an endpoint or certificate wasn't created. They normally live only in the controller pod and are lost when it restarts. In this step you turn on CloudWatch publishing in the inference operator add-on's configuration so the logs are kept.

> [!WARNING]
> `aws eks update-addon --configuration-values` **replaces** the whole configuration. The command below merges the new setting into the current configuration so that roles and buckets are preserved.

The command below reads the add-on's current configuration, adds the `logging` setting to it, and shows the difference. Nothing changes yet:

```bash
CURRENT=$(aws eks describe-addon --cluster-name $EKS_CLUSTER_NAME \
  --addon-name amazon-sagemaker-hyperpod-inference --region $REGION \
  --query addon.configurationValues --output text)

echo "$CURRENT" | jq '. * {"logging": {"cloudWatch": {"enabled": true, "logLevel": "info"}}}' > addon-config-logging.json
diff <(echo "$CURRENT" | jq -S .) <(jq -S . addon-config-logging.json) || true   # only "logging" should be added
```

Expected: the diff shows only added lines (starting with `>`) for the `logging` block. If it shows any other line removed or changed, stop: applying it would change the add-on's other settings.

Apply the new configuration and wait until the add-on is active again (a few minutes):

```bash
aws eks update-addon --cluster-name $EKS_CLUSTER_NAME \
  --addon-name amazon-sagemaker-hyperpod-inference --region $REGION \
  --configuration-values file://addon-config-logging.json --query update.status --output text \
  | sed 's/^/update: /'
aws eks wait addon-active --cluster-name $EKS_CLUSTER_NAME \
  --addon-name amazon-sagemaker-hyperpod-inference --region $REGION && echo "add-on: ACTIVE"
```

Expected, after one to a few minutes: `update: InProgress`, then `add-on: ACTIVE`.

The command below finds the operator's log group:

```bash
aws logs describe-log-groups --log-group-name-prefix /aws/hyperpod/ --region $REGION \
  --query 'logGroups[].logGroupName' --output text | tr '\t' '\n' | grep inference-operator
```

Expected: one log group name under `/aws/hyperpod/` that contains `inference-operator`. If it prints nothing, the operator hasn't written its first logs yet: wait a minute and run it again. You can open the log group in the CloudWatch console to read the logs.

`tinyllama-dd` keeps running with no limits, and operator logging stays on. Nothing to clean up before lab 4.
