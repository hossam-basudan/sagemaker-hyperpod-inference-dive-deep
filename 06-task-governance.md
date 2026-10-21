# 6. Task governance for inference

On a shared HyperPod cluster, inference and training compete for the same GPUs. HyperPod task governance (Kueue) decides who gets them: each team has a guaranteed quota, can borrow idle capacity, and higher-priority work can preempt lower-priority work. Inference endpoints take part in this just like training jobs do.

## Prerequisites

This module uses the setup from the workshop's task governance section, sized for two `ml.g5.2xlarge` nodes:

- the HyperPod task governance add-on, with namespaces `hyperpod-ns-team-a` and `hyperpod-ns-team-b`
- a cluster policy with priority classes `inference` (weight 90), `experimentation` (80), `training` (70), and `fine-tuning` (50)
- one compute allocation per team: **1 x `ml.g5.2xlarge`**, `LendAndBorrow` with `BorrowLimit=100`, and `PreemptTeamTasks=LowerPriority`

Check what your cluster has:

```bash
aws sagemaker list-compute-quotas --region $REGION --cluster-arn "$HYPERPOD_CLUSTER_ARN" \
  --query 'ComputeQuotaSummaries[].[Name,ComputeQuotaTarget.TeamName,Status]' --output table
kubectl get workloadpriorityclass
```

> [!NOTE]
> If you completed the workshop's task governance section, the cluster policy and both allocations already match this list. Skip to "Free both GPUs".

<details open>
<summary><b>Create the allocations</b></summary>

Install the add-on and create the cluster policy as in the task governance section first. Then:

```bash
for TEAM in team-a team-b; do
  aws sagemaker create-compute-quota --region $REGION \
    --name "${TEAM}-g5-2xl" \
    --cluster-arn "$HYPERPOD_CLUSTER_ARN" \
    --compute-quota-config "ComputeQuotaResources=[{InstanceType=ml.g5.2xlarge,Count=1}],ResourceSharingConfig={Strategy=LendAndBorrow,BorrowLimit=100},PreemptTeamTasks=LowerPriority" \
    --activation-state Enabled \
    --compute-quota-target "TeamName=${TEAM},FairShareWeight=100"
done
```

`ComputeQuota record already exists` means the team already has an allocation.

</details>

<details>
<summary><b>Update existing allocations</b></summary>

If your allocations use a different instance type or a lower `BorrowLimit`, update them:

```bash
aws sagemaker list-compute-quotas --region $REGION --cluster-arn "$HYPERPOD_CLUSTER_ARN" \
  --query 'ComputeQuotaSummaries[].[ComputeQuotaId,Name,ComputeQuotaVersion,ComputeQuotaTarget.TeamName]' --output table

aws sagemaker update-compute-quota --region $REGION \
  --compute-quota-id <id> --target-version <version> \
  --compute-quota-config "ComputeQuotaResources=[{InstanceType=ml.g5.2xlarge,Count=1}],ResourceSharingConfig={Strategy=LendAndBorrow,BorrowLimit=100},PreemptTeamTasks=LowerPriority"
```

</details>


`BorrowLimit` is a percentage of the team's own quota. With a one-node quota, `BorrowLimit=50` would allow half a GPU, which can't hold a pod, so this module needs 100.

Free both GPUs before you start:

```bash
kubectl delete inferenceendpointconfig tinyllama-dd -n $NAMESPACE --ignore-not-found
kubectl get pods -A | grep -E 'tinyllama|qwen|deepseek' || echo "GPUs free"
```

## Opt an endpoint into governance

Put two labels on the custom resource's `metadata`. They work on both `InferenceEndpointConfig` and `JumpStartModel`:

```yaml
metadata:
  name: <deployment-name>
  namespace: hyperpod-ns-<team>                                # the team's namespace
  labels:
    kueue.x-k8s.io/queue-name: hyperpod-ns-<team>-localqueue   # LocalQueue in the same namespace
    kueue.x-k8s.io/priority-class: inference-priority          # <cluster policy class name>-priority
```

Check the names on your cluster:

```bash
kubectl get localqueue -A
kubectl get workloadpriorityclass
kubectl get clusterqueue
```

## How Kueue treats an inference replica

Kueue admits each workload in this order:

1. **Team quota**: if the team has unused guaranteed GPUs, admit.
2. **Self-preemption**: otherwise, preempt lower-priority workloads **of the same team**. A `training-priority` job yields to `inference-priority`.
3. **Borrowing**: otherwise, borrow idle quota from other teams, up to the borrow limit. **Borrowed capacity can be reclaimed.** When the lending team submits work, Kueue evicts the borrower's lowest-priority workloads until the borrower is back within its quota.
4. If none of these work, the workload stays pending (`QuotaReserved: False`), and its pods stay `SchedulingGated`.

The lab walks through all three: team A borrows, inference preempts training within team A, and team B reclaims its node.

## Lab: borrowing, preemption, and reclaim

### 1. A training stand-in

Real training jobs take minutes to start. This lab uses a one-GPU Kubernetes `Job` that just holds its GPU, which Kueue treats like any other training workload. The Kueue labels go on both the Job and its pod template: HyperPod's `hyperpod-task-governance-admission-policy` rejects any pod in a team namespace that lacks `kueue.x-k8s.io/queue-name`.

```bash
submit_training() {  # usage: submit_training <team> <job-name>
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: $2
  namespace: hyperpod-ns-$1
  labels:
    kueue.x-k8s.io/queue-name: hyperpod-ns-$1-localqueue
    kueue.x-k8s.io/priority-class: training-priority
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:   # task governance rejects pods without the queue label, so repeat it here
        kueue.x-k8s.io/queue-name: hyperpod-ns-$1-localqueue
        kueue.x-k8s.io/priority-class: training-priority
    spec:
      restartPolicy: Never
      nodeSelector:
        node.kubernetes.io/instance-type: ml.g5.2xlarge
      containers:
        - name: train
          image: public.ecr.aws/docker/library/busybox:stable
          command: ["sh", "-c", "echo 'pretending to train'; sleep 3600"]
          resources:
            requests: {nvidia.com/gpu: "1", cpu: "1", memory: 1Gi}
            limits:   {nvidia.com/gpu: "1", cpu: "1", memory: 1Gi}
EOF
}
```

> [!WARNING]
> Every pod admitted through a queue with topology-aware scheduling must request at least one resource. A pod with no `resources.requests` fails admission with `failed to assign flavors to pod set main: no TAS flavor assigned` and stays `SchedulingGated` forever. That's why even helper pods (such as the `etcd` pod in the task governance imagenet example) need small requests, for example `cpu: 100m, memory: 128Mi`.

### 2. Team A fills the cluster

Team A submits two training jobs. The first uses team A's own node; the second borrows team B's idle node:

```bash
submit_training team-a train-a1
submit_training team-a train-a2
sleep 15
kubectl get workloads -n hyperpod-ns-team-a
kubectl get clusterqueue hyperpod-ns-team-a-clusterqueue \
  -o jsonpath='{range .status.flavorsUsage[*].resources[*]}{.name}{"\tused="}{.total}{"\tborrowed="}{.borrowed}{"\n"}{end}'
```

Both workloads are `ADMITTED: True`, and the ClusterQueue shows `nvidia.com/gpu used=2 borrowed=1`.

### 3. Team A deploys inference

```bash
cat > tinyllama-team-a.yaml <<EOF
apiVersion: inference.sagemaker.aws.amazon.com/v1
kind: InferenceEndpointConfig
metadata:
  name: tinyllama-team-a
  namespace: hyperpod-ns-team-a
  labels:
    kueue.x-k8s.io/queue-name: hyperpod-ns-team-a-localqueue
    kueue.x-k8s.io/priority-class: inference-priority
spec:
  modelName: tinyllama-team-a
  instanceType: ${INSTANCE_TYPE}
  invocationEndpoint: v1/chat/completions
  replicas: 1
  modelSourceConfig:
    modelSourceType: huggingface
    prefetchEnabled: true
    huggingFaceModel:
      modelId: TinyLlama/TinyLlama-1.1B-Chat-v1.0
  loadBalancer:
    healthCheckPath: /health
  metrics:
    enabled: true
    modelMetrics:
      port: 8000      # vLLM serves /metrics on its API port (default 8080)
      path: /metrics
  worker:
    image: vllm/vllm-openai:v0.19.1
    modelInvocationPort:
      containerPort: 8000
      name: http
    modelVolumeMount:
      name: model-weights
      mountPath: /opt/ml/model
    resources:
      requests: {nvidia.com/gpu: "1", cpu: "4", memory: 16Gi}
      limits:   {nvidia.com/gpu: "1", cpu: "4", memory: 16Gi}
    args: ["--model", "/opt/ml/model", "--port", "8000", "--served-model-name", "tinyllama"]
EOF
kubectl apply -f tinyllama-team-a.yaml
```

Watch one of team A's training workloads lose its admission so that inference can run:

```bash
watch -n 5 "kubectl get workloads -n hyperpod-ns-team-a; echo; kubectl get pods -n hyperpod-ns-team-a"
```

Ask Kueue why the training job was evicted:

```bash
for WL in $(kubectl get workloads -n hyperpod-ns-team-a -o name | grep job-train); do
  echo "== $WL"
  kubectl get $WL -n hyperpod-ns-team-a \
    -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.message}{"\n"}{end}'
done
```

Look for `Preempted to accommodate a workload ... due to prioritization in the ClusterQueue`. The evicted job stays queued and is re-admitted when capacity frees up.

> [!NOTE]
> If no workload appears for the inference pods, the labels didn't reach Kueue. Check that they're on the custom resource's `metadata.labels` (not a pod template), that the LocalQueue exists in the same namespace, and that the priority class name matches `kubectl get workloadpriorityclass`.

### 4. Team B reclaims its node

Team A is still using team B's node. Team B now submits work of its own:

```bash
submit_training team-b train-b1
watch -n 5 "kubectl get workloads -A | grep -E 'NAMESPACE|team-'"
```

Kueue brings team A back within its own quota so team B gets its guaranteed node. Quota is accounting, not node placement, so Kueue doesn't look for "the pod on the borrowed node". It evicts team A's **lowest-priority** workload: `train-a1` goes, and the inference endpoint keeps running. Rerun the condition loop from step 3. This eviction says `due to reclamation within the cohort`, not `due to prioritization in the ClusterQueue`:

```bash
kubectl get workloads -A | grep -E 'NAMESPACE|team-'
kubectl get pods -n hyperpod-ns-team-a -o wide
kubectl get pods -n hyperpod-ns-team-b -o wide
kubectl get clusterqueue hyperpod-ns-team-a-clusterqueue \
  -o jsonpath='{range .status.flavorsUsage[*].resources[?(@.name=="nvidia.com/gpu")]}{"used="}{.total}{" borrowed="}{.borrowed}{"\n"}{end}'
```

Expected: `train-b1` running on the node `train-a1` used, `tinyllama-team-a` still running, and team A at `used=1 borrowed=0`.

The takeaway: **reclaim follows priority.** Inference survived here because it outranks training. If team A had only inference replicas, the reclaim would evict one of them. So keep inference at the highest priority, and size an endpoint's minimum replicas to fit the team's guaranteed quota.

## Designing governance for inference

| Decision | Recommendation |
|---|---|
| Priority | Give inference the highest weight, so latency-sensitive traffic preempts batch work within the team |
| `minReplicaCount` | Keep it within the team's **guaranteed** quota. When a lender reclaims, Kueue evicts the borrowing team's lowest-priority workloads first; inference replicas are evicted once nothing lower-priority is left |
| `maxReplicaCount` | At most guaranteed quota + borrow limit. Beyond that, extra replicas sit `SchedulingGated` |
| Borrow limit | It's a percentage of the team's quota. Make sure it adds up to whole nodes (for a 1-node quota, use 100) |
| Requests | Set CPU and memory requests on every container, including helpers, so Kueue can assign a flavor |
| Scale to zero | Idle endpoints return GPUs to the pool, where training or other teams can borrow them |
| Separate team or not | A dedicated inference team (namespace and allocation) with `LendAndBorrow` lends idle GPUs to training off-peak and reclaims them on demand |

## Clean up

```bash
kubectl delete inferenceendpointconfig tinyllama-team-a -n hyperpod-ns-team-a --ignore-not-found
kubectl delete job train-a1 train-a2 -n hyperpod-ns-team-a --ignore-not-found
kubectl delete job train-b1 -n hyperpod-ns-team-b --ignore-not-found
```

To run the earlier modules again, re-create `tinyllama-dd` with `kubectl apply -f tinyllama-dd.yaml`.
