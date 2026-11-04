# 2. Autoscaling

In this lab you make the `tinyllama-dd` endpoint from lab 1 add a second replica when traffic rises, and drop back to one when traffic stops. Inference traffic is bursty, so autoscaling is how you keep latency down without paying for idle GPUs all day.

HyperPod scales inference at two levels:

| Level | Mechanism | Scales |
|---|---|---|
| Pods | `spec.autoScalingSpec` → operator-managed **KEDA** `ScaledObject` → Kubernetes HPA | Replicas of your model Deployment, on CloudWatch or Prometheus metrics |
| Nodes | HyperPod **managed Karpenter** (continuous provisioning) | Instances, when replicas are pending for lack of capacity |

Terms used on this page:

- **HPA** (Horizontal Pod Autoscaler): the built-in Kubernetes controller that changes a Deployment's replica count to keep a metric near a target.
- **KEDA** (Kubernetes Event-driven Autoscaling): an add-on that reads metrics from outside the cluster (here, CloudWatch or Prometheus) and feeds them to an HPA. The inference operator installs it.
- **`ScaledObject`**: the KEDA resource that says which Deployment to scale, on which metric, and within which bounds. KEDA creates the HPA from it.
- **Karpenter**: a node autoscaler that adds or removes instances.

This lab covers pod scaling. Each replica uses the only GPU on an `ml.g5.2xlarge` node, so with two GPU nodes the endpoint can scale from 1 to 2 replicas.

What you need:

- The `tinyllama-dd` endpoint from lab 1, running.
- The second GPU node free (next section).
- For the optional Prometheus section only: the observability add-on from [lab 0, "Optional: Prometheus metrics"](00-setup.md#optional-prometheus-metrics). The main lab uses CloudWatch and works without it.

## Free the second GPU

The second replica needs the other GPU node. Right after lab 1 that node is free. If you ran later labs first and one of their models still runs there, the HPA asks for 2 replicas but the new pod stays `Pending`, and you can't tell whether autoscaling worked.

The command below deletes the models other labs create (each delete is safe to run when the model is already gone), then lists the models still deployed:

```bash
kubectl delete inferenceendpointconfig qwen-hf qwen-s3 qwen-fsx qwen-byoc -n $NAMESPACE --ignore-not-found
kubectl delete jumpstartmodel deepseek-js -n $NAMESPACE --ignore-not-found
kubectl get inferenceendpointconfig,jumpstartmodel -A
```

Expected: the list shows only `tinyllama-dd`, with status `DeploymentComplete`. The delete lines print nothing for models that don't exist.

If `tinyllama-dd` is missing, deploy it again with `kubectl apply -f tinyllama-dd.yaml` from lab 1, and wait for `DeploymentComplete` before you continue.

## How the operator scales

You don't create KEDA objects yourself. You add an `autoScalingSpec` to the endpoint's custom resource, and the operator creates the `ScaledObject`; KEDA then creates the HPA. For reference; nothing to run:

```text
autoScalingSpec ──► KEDA ScaledObject ──► HPA ──► Deployment replicas
                         ▲
                         └── polls CloudWatch / Amazon Managed Service for Prometheus
                             every pollingInterval seconds (KEDA role, through IRSA)
```

KEDA polls the metric with its own IAM role, through IRSA (IAM roles for service accounts, which give a Kubernetes service account AWS credentials).

The `autoScalingSpec` fields:

| Field | Default | Meaning |
|---|---|---|
| `minReplicaCount` / `maxReplicaCount` | 1 / 5 | Bounds. `minReplicaCount: 0` enables scale to zero |
| `pollingInterval` | 30 | Seconds between metric polls |
| `cooldownPeriod` | 300 | Idle seconds before scaling to zero |
| `initialCooldownPeriod` | 300 | Grace period after creation before scale-down |
| `scaleUpStabilizationTime` / `scaleDownStabilizationTime` | 0 / 300 | HPA stabilization windows (seconds) |
| `cloudWatchTrigger` / `cloudWatchTriggerList` | none | CloudWatch metric(s). The list takes priority |
| `prometheusTrigger` / `prometheusTriggerList` | none | PromQL query against an Amazon Managed Service for Prometheus workspace |

A **stabilization window** is how long the HPA waits, looking at recent recommendations, before it acts. A scale-down window of 120 seconds means the metric must stay low for 2 minutes before a replica is removed, which stops replicas from flapping.

How the metric turns into a replica count:

- `metricType: Average`: desired replicas = `ceil(metricValue / targetValue)`. For example, 70 invocations per minute with a target of 20 asks for 4 replicas (capped at `maxReplicaCount`).
- `metricType: Value`: desired replicas = `currentReplicas × ceil(metricValue / targetValue)`.

## Lab: scale on SageMaker endpoint invocations

You scale on the endpoint's `Invocations` **CloudWatch metric**: the number of requests per minute that SageMaker AI publishes for the endpoint in the `AWS/SageMaker` namespace. It needs no extra add-on.

The command below adds an `autoScalingSpec` to the running endpoint: 1 to 2 replicas, a target of 20 invocations per minute per replica, and a 2-minute scale-down window so you don't wait long for the scale-in:

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

Expected: one line ending in `tinyllama-dd patched`.

Check that the operator created the KEDA `ScaledObject` and that KEDA created its HPA:

```bash
kubectl get scaledobject,hpa -n $NAMESPACE
```

Expected: one `scaledobject` and one `horizontalpodautoscaler` (its name starts with `keda-hpa-`). The HPA shows `MINPODS 1`, `MAXPODS 2`, `REPLICAS 1`. If the list is empty, wait about 10 seconds and run it again.

### Generate load

The command below writes a small script, `load.sh`, that calls the endpoint in a loop for 8 minutes, then starts 8 copies of it in the background (8 concurrent clients). It returns right away; the load keeps running while you go on to the next step.

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

Expected: a job number and process ID, such as `[1] 12345`. The clients print nothing; the requests show up in the next step.

### Watch the replicas react

Run the watch loop below right after starting the load. It prints the HPA and the model pods every 20 seconds, and stops on its own once the endpoint has scaled up, the load has ended, and the replica count is back to 1 (or after 15 minutes).

```bash
SCALED=false
for i in $(seq 45); do
  echo "--- $(date +%T)"
  kubectl get hpa -n $NAMESPACE --no-headers
  kubectl get pods -n $NAMESPACE --no-headers | grep $ENDPOINT_NAME | awk '{print $1, $2, $3}'
  R=$(kubectl get deploy $ENDPOINT_NAME -n $NAMESPACE -o jsonpath='{.status.replicas}')
  [ "${R:-0}" -gt 1 ] && SCALED=true
  $SCALED && [ "$R" = 1 ] && ! pgrep -f load.sh >/dev/null && break
  sleep 20
done
```

The loop takes about 12 to 15 minutes. How to read each block:

- The HPA line has no header. Its columns are NAME, REFERENCE, TARGETS, MINPODS, MAXPODS, REPLICAS, AGE.
- **TARGETS** is the current metric per replica over the target, for example `36/20 (avg)`. Values may be shown in thousandths, such as `23500m/20 (avg)`, which means 23.5.
- **REPLICAS** is the replica count the HPA has set on the Deployment.
- The pod lines show each model pod's name, ready containers, and status.

What you should see over time:

1. **First 1 to 3 minutes**: TARGETS shows `0/20` (or briefly `<unknown>/20`), REPLICAS is 1, one pod `Running`. CloudWatch publishes SageMaker metrics once per minute, so the metric lags the load.
2. **Scale-up**: TARGETS rises to about `35/20`, above the target of 20, so REPLICAS goes to 2 and a second pod appears, first as `Pending` or `ContainerCreating`, then `Running` after the model loads (a few minutes).
3. **While both replicas run**: TARGETS moves between about `22/20` and `38/20` (values such as `23500m` mean 23.5). It stays above 20, so the HPA keeps 2 replicas.
4. **After the load ends (about 8 minutes in)**: TARGETS falls toward `0/20`. After the 2-minute `scaleDownStabilizationTime` plus the metric lag, REPLICAS goes back to 1 and the second pod terminates. The loop then exits.

Autoscaling worked if REPLICAS reached 2 during the load and returned to 1 afterwards, even if the second pod never reached `Running` (see the first alert below).

> [!WARNING]
> If `REPLICAS` goes to 2 but the new pod stays `Pending`, autoscaling worked; the scheduler has nowhere to put the pod. Run `kubectl describe pod <pending-pod> -n $NAMESPACE` with the pending pod's name and read the Events at the end. `Insufficient nvidia.com/gpu` means another model holds the second GPU: run "Free the second GPU" above, or `scripts/reset-gpus.sh` from lab 0 and redeploy `tinyllama-dd`. `Too many pods` means the node is at its pod limit (see the note below). On a cluster with continuous provisioning, Karpenter would add a node instead.

> [!NOTE]
> If TARGETS stays at `<unknown>` for more than 2 minutes, check the KEDA operator logs with `kubectl logs -n hyperpod-inference-system deploy/keda-operator --tail=50`. The usual causes are that the KEDA role is missing `cloudwatch:GetMetricData`, or that the dimensions don't match the endpoint name.

Each node also has a pod limit, explained in the [GPU budget](../README.md#gpu-budget) section of the lab overview.

### Inspect what the operator generated

The command below prints the spec of the `ScaledObject` the operator created from your `autoScalingSpec`:

```bash
kubectl get scaledobject -n $NAMESPACE -o yaml | yq '.items[].spec' 2>/dev/null \
  || kubectl get scaledobject -n $NAMESPACE -o json | jq '.items[].spec'
```

Expected: a `scaleTargetRef` that names the `tinyllama-dd` Deployment, the replica bounds and polling interval you set, the stabilization windows under `advanced`, and one entry under `triggers` for the CloudWatch metric with its namespace, dimensions, and target.

Every `autoScalingSpec` field maps to a KEDA field. You can also skip `autoScalingSpec` and write your own `keda.sh/v1alpha1` `ScaledObject` that targets the model Deployment, for example to scale on Amazon SQS queue depth for an asynchronous pattern. This lab doesn't do that.

## Optional: scale on model-level metrics with Prometheus

This section needs the observability add-on from [lab 0, "Optional: Prometheus metrics"](00-setup.md#optional-prometheus-metrics). If you didn't install it, read this section without running anything and go on to [Scale to zero](#scale-to-zero).

Invocations per minute is a coarse signal for LLMs: one request can take 50 ms or 50 s. The number of requests in flight (concurrency) tracks load more closely. The operator's reverse-proxy sidecar exports it as `model_concurrent_requests` (lab 3 shows the raw metrics), and the observability add-on writes it to **Amazon Managed Service for Prometheus**, an AWS-managed, Prometheus-compatible metrics store. You query it with **PromQL**, the Prometheus query language.

### Find the Prometheus workspace

The command below reads the URL of the workspace your cluster's observability add-on writes to. An account often has several workspaces, so it asks the add-on instead of taking the first one `aws amp list-workspaces` returns:

```bash
# The add-on stores the URL with a trailing slash, which serverAddress doesn't accept
export AMP_ENDPOINT=$(aws eks describe-addon --cluster-name $EKS_CLUSTER_NAME \
  --addon-name amazon-sagemaker-hyperpod-observability --region $REGION \
  --query addon.configurationValues --output text | jq -r '.ampWorkspace.prometheusEndpoint | rtrimstr("/")')
echo $AMP_ENDPOINT
```

Expected: a URL like `https://aps-workspaces.<region>.amazonaws.com/workspaces/ws-...`, with no trailing slash.

If it fails with `ResourceNotFoundException`, the add-on isn't installed. Skip the rest of this section, or install the add-on from lab 0 and come back.

### Run the query before you scale on it

Always check that a query returns what you expect before you use it as a trigger. Requests to Amazon Managed Service for Prometheus must be signed with **SigV4** (AWS Signature Version 4, the way AWS APIs authenticate a request with your credentials); `awscurl` is a `curl` that signs them.

The query needs traffic. By now the 8-minute load from "Generate load" has ended, so start it again first: run the "Generate load" command block above once more, and wait about 2 minutes for new samples to reach the workspace.

Then run the query below. It installs `awscurl` and prints the in-flight requests per pod:

```bash
pip install -q awscurl
awscurl --service aps --region $REGION -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'query=sum by (pod_name) (model_concurrent_requests{resource_name="tinyllama-dd"})' \
  $AMP_ENDPOINT/api/v1/query \
| jq -r 'if (.data.result | length) == 0 then "  (no data yet)" else .data.result[]
      | "  \(.metric | del(.__name__) | to_entries | map("\(.key)=\(.value)") | join(" ") | if . == "" then "total" else . end): \(.value[1] | if test("NaN|Inf") then "no traffic" else (tonumber * 100 | round / 100 | tostring) end)" end'
```

Expected: one line per model pod, such as `  pod_name=tinyllama-dd-...: 5`. The load also scales the endpoint again, so you may see two pods.

How to read it:

- `(no data yet)`: no samples have arrived. Wait a minute and run it again.
- The value jumps between 0 and 8 from one run to the next. Each request in `load.sh` starts a new `aws` process, so the 8 clients spend part of their time between requests, not in flight.

### Example: a Prometheus trigger

For reference; nothing to run. This is how an `autoScalingSpec` with a Prometheus trigger looks. Because the instantaneous value jumps around, it scales on a 2-minute average. On the raw value, this load scales out and back in every couple of minutes.

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

In testing, this spec asked for a second replica about a minute into the load, held 2 replicas until the load stopped, and scaled back to 1 about 3 minutes later.

> [!WARNING]
> `serverAddress` must be an Amazon Managed Service for Prometheus workspace URL without a trailing slash. The CRD rejects a plain `http://prometheus:9090`. With `metricType: Average`, KEDA divides the query result by `targetValue` and rounds up, so a target at or above the peak value never adds a replica.

## Scale to zero

**Scale to zero** means removing every replica while the endpoint is idle, so it holds no GPU, and starting one again when traffic returns. For reference; nothing to run.

To enable it, set `minReplicaCount: 0` and an `activationTargetValue`. KEDA scales from 0 to 1 only when the metric rises above the activation value, then hands over to the HPA for scaling beyond 1:

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
- **The first requests after idle fail or wait** while the pod is scheduled, the image is pulled, and the weights load. Make clients retry, or put a queue in front of the endpoint. Image and weights caching (lab 6) shortens this.
- **Freed GPUs return to the cluster**, and task governance can lend them to other teams (lab 7).

## Node autoscaling

For reference; this workshop's cluster doesn't use it. Pod autoscaling stops when no GPU is free: new replicas stay `Pending`. If the cluster was created with `--node-provisioning-mode Continuous`, HyperPod's managed Karpenter adds instances for pending pods and removes idle ones. See [Autoscaling on SageMaker HyperPod EKS](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-eks-autoscaling.html).

## Clean up

The command below stops any load clients still running and removes the `autoScalingSpec`, so the endpoint goes back to a fixed single replica for lab 3:

```bash
kill %1 2>/dev/null; pkill -f load.sh
kubectl patch inferenceendpointconfig $ENDPOINT_NAME -n $NAMESPACE --type json \
  -p '[{"op":"remove","path":"/spec/autoScalingSpec"}]'
```

Expected: a line ending in `tinyllama-dd patched`. The operator deletes the `ScaledObject` and HPA. Run `kubectl get pods -n $NAMESPACE` to check that one `tinyllama-dd` pod is left; a second replica, if one was running, should terminate within a minute.
