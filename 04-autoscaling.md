# 4. Autoscaling

Inference traffic is bursty. HyperPod scales inference at two levels:

| Level | Mechanism | Scales |
|---|---|---|
| Pods | `spec.autoScalingSpec` → operator-managed **KEDA** `ScaledObject` → Kubernetes HPA | Replicas of your model Deployment, on CloudWatch or Prometheus metrics |
| Nodes | HyperPod **managed Karpenter** (continuous provisioning) | Instances, when replicas are pending for lack of capacity |

This module covers pod scaling with the `tinyllama-dd` endpoint from module 1. Each replica uses the only GPU on an `ml.g5.2xlarge` node, so with two nodes the endpoint scales from 1 to 2 replicas.

## How the operator scales

```text
autoScalingSpec ──► KEDA ScaledObject ──► HPA ──► Deployment replicas
                         ▲
                         └── polls CloudWatch / Amazon Managed Service for Prometheus
                             every pollingInterval seconds (KEDA role, through IRSA)
```

| Field | Default | Meaning |
|---|---|---|
| `minReplicaCount` / `maxReplicaCount` | 1 / 5 | Bounds. `minReplicaCount: 0` enables scale to zero |
| `pollingInterval` | 30 | Seconds between metric polls |
| `cooldownPeriod` | 300 | Idle seconds before scaling to zero |
| `initialCooldownPeriod` | 300 | Grace period after creation before scale-down |
| `scaleUpStabilizationTime` / `scaleDownStabilizationTime` | 0 / 300 | HPA stabilization windows (seconds) |
| `cloudWatchTrigger` / `cloudWatchTriggerList` | none | CloudWatch metric(s). The list takes priority |
| `prometheusTrigger` / `prometheusTriggerList` | none | PromQL query against an Amazon Managed Service for Prometheus workspace |

With `metricType: Average`, the desired replica count is `ceil(metricValue / targetValue)`. With `metricType: Value`, it's `currentReplicas × ceil(metricValue / targetValue)`.

## Lab: scale on SageMaker endpoint invocations

Add a CloudWatch trigger to the running endpoint. The target is 20 invocations per minute per replica:

```bash
export ENDPOINT_NAME=tinyllama-dd

kubectl patch inferenceendpointconfig $ENDPOINT_NAME -n $NAMESPACE --type merge -p "$(cat <<EOF
{
  "spec": {
    "autoScalingSpec": {
      "minReplicaCount": 1,
      "maxReplicaCount": 2,
      "pollingInterval": 15,
      "initialCooldownPeriod": 60,
      "cooldownPeriod": 120,
      "scaleUpStabilizationTime": 0,
      "scaleDownStabilizationTime": 120,
      "cloudWatchTrigger": {
        "name": "SageMaker-Invocations",
        "namespace": "AWS/SageMaker",
        "metricName": "Invocations",
        "dimensions": [
          {"name": "EndpointName", "value": "${ENDPOINT_NAME}"},
          {"name": "VariantName",  "value": "AllTraffic"}
        ],
        "metricStat": "Sum",
        "metricType": "Average",
        "targetValue": 20,
        "minValue": 0,
        "metricCollectionStartTime": 300,
        "metricCollectionPeriod": 60,
        "useCachedMetrics": false
      }
    }
  }
}
EOF
)"
```

The operator creates the KEDA objects:

```bash
kubectl get scaledobject,hpa -n $NAMESPACE
```

### Generate load

This runs 8 concurrent clients for 8 minutes:

```bash
cat > load.sh <<'EOF'
#!/usr/bin/env bash
END=$((SECONDS + ${DURATION:-480}))
while [ $SECONDS -lt $END ]; do
  aws sagemaker-runtime invoke-endpoint --endpoint-name "$ENDPOINT_NAME" --region "$REGION" \
    --content-type application/json --cli-binary-format raw-in-base64-out \
    --body '{"model":"tinyllama","messages":[{"role":"user","content":"Write a long story about a GPU cluster."}],"max_tokens":256}' \
    /dev/null >/dev/null 2>&1
done
EOF
chmod +x load.sh
export ENDPOINT_NAME REGION
seq 8 | xargs -P 8 -I{} ./load.sh &
```

Watch the replicas react. CloudWatch publishes SageMaker metrics at 1-minute granularity, so expect the first scale-up within 1–3 minutes of load starting:

```bash
watch -n 10 "kubectl get hpa -n $NAMESPACE; echo; kubectl get pods -n $NAMESPACE | grep $ENDPOINT_NAME"
```

When the load stops, the replica count returns to 1 after `scaleDownStabilizationTime` plus the metric lag.

> [!NOTE]
> If the HPA shows `<unknown>` for the metric, check the KEDA operator logs with `kubectl logs -n hyperpod-inference-system deploy/keda-operator --tail=50`. The usual cause is that the KEDA role is missing `cloudwatch:GetMetricData`, or that the dimensions don't match the endpoint name.

### Inspect what the operator generated

```bash
kubectl get scaledobject -n $NAMESPACE -o yaml | yq '.items[].spec' 2>/dev/null \
  || kubectl get scaledobject -n $NAMESPACE -o json | jq '.items[].spec'
```

Every `autoScalingSpec` field maps to a KEDA field. You can also skip `autoScalingSpec` and write your own `keda.sh/v1alpha1` `ScaledObject` that targets the model Deployment, for example to scale on SQS queue depth for an asynchronous pattern.

## Scale on model-level metrics with Prometheus

Invocations per minute is a coarse signal for LLMs: one request can take 50 ms or 50 s. Concurrency or queue depth tracks load more closely. The operator's reverse-proxy sidecar exports `model_concurrent_requests` (module 5), and the HyperPod observability add-on writes it to Amazon Managed Service for Prometheus.

Read the workspace your cluster's observability add-on writes to. An account often has several workspaces, so don't take the first one `aws amp list-workspaces` returns:

```bash
# The add-on stores the URL with a trailing slash, which serverAddress doesn't accept
export AMP_ENDPOINT=$(aws eks describe-addon --cluster-name $EKS_CLUSTER_NAME \
  --addon-name amazon-sagemaker-hyperpod-observability --region $REGION \
  --query addon.configurationValues --output text | jq -r '.ampWorkspace.prometheusEndpoint | rtrimstr("/")')
echo $AMP_ENDPOINT
```

If the add-on isn't installed, `describe-addon` fails with `ResourceNotFoundException` and this trigger has nothing to query.

Before you scale on a query, run it. Prometheus queries need SigV4-signed requests, which `awscurl` handles. Run this while the load generator is running:

```bash
pip install -q awscurl
awscurl --service aps --region $REGION -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'query=sum by (pod_name) (model_concurrent_requests{resource_name="tinyllama-dd"})' \
  $AMP_ENDPOINT/api/v1/query | jq -c '[.data.result[] | {pod: .metric.pod_name, value: .value[1]}]'
```

The value jumps between 0 and 8 from one query to the next: each request in `load.sh` starts a new `aws` process, so the 8 clients spend part of their time between requests. New samples reach the workspace a minute or two after the load starts.

Scale on a 2-minute average, not the instantaneous value. On the raw value, this load scales out and back in every couple of minutes:

```yaml
  autoScalingSpec:
    minReplicaCount: 1
    maxReplicaCount: 2
    pollingInterval: 15
    scaleDownStabilizationTime: 120
    prometheusTrigger:
      name: concurrent-requests
      serverAddress: https://aps-workspaces.<region>.amazonaws.com/workspaces/<ws-id>   # $AMP_ENDPOINT
      query: sum(avg_over_time(model_concurrent_requests{resource_name="tinyllama-dd"}[2m]))
      targetValue: 2          # in-flight requests per replica; the 8-client load averages about 3
      metricType: Average
```

In testing, this asked for a second replica about a minute into the load, held 2 replicas until the load stopped, and scaled back to 1 about 3 minutes later.

> [!WARNING]
> `serverAddress` must be an Amazon Managed Service for Prometheus workspace URL without a trailing slash. The CRD rejects a plain `http://prometheus:9090`. With `metricType: Average`, KEDA divides the query result by `targetValue` and rounds up, so a target at or above the peak value never adds a replica.

## Scale to zero

Set `minReplicaCount: 0` and an `activationTargetValue`. KEDA scales from 0 to 1 only when the metric rises above the activation value, then hands over to the HPA.

```yaml
  autoScalingSpec:
    minReplicaCount: 0
    maxReplicaCount: 2
    cooldownPeriod: 600
    cloudWatchTrigger:
      # same as the lab above, plus:
      activationTargetValue: 1
```

Keep in mind:

- **The activation metric must not come from the pods.** With zero pods, pod metrics such as `model_concurrent_requests`, CPU, or memory are never emitted, so the endpoint can't wake up. Use a metric produced outside the pods, such as SageMaker endpoint invocations or SQS queue depth.
- **The first requests after idle fail or wait** for scheduling, image pull, and weight load. Make clients retry, or put a queue in front of the endpoint. Image and weights caching (module 2) shortens this.
- **Freed GPUs return to the cluster**, and task governance can lend them to other teams (module 6).

## Node autoscaling

Pod autoscaling stops when no GPU is free: new replicas stay `Pending`. HyperPod's managed Karpenter can add instances for pending pods (and remove idle ones) if the cluster uses `--node-provisioning-mode Continuous`. See [Autoscaling on SageMaker HyperPod EKS](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-eks-autoscaling.html).

## Clean up

```bash
kill %1 2>/dev/null; pkill -f load.sh
kubectl patch inferenceendpointconfig $ENDPOINT_NAME -n $NAMESPACE --type json \
  -p '[{"op":"remove","path":"/spec/autoScalingSpec"}]'
```
