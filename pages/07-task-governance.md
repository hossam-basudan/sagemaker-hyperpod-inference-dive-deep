# 7. Task governance for inference (optional)

This lab is optional: run it if your inference shares a cluster with training. On a shared HyperPod cluster, inference and training compete for the same GPUs. HyperPod **task governance** decides who gets them, and inference endpoints take part in it the same way training jobs do. In this lab you watch an inference endpoint borrow, preempt, and survive a reclaim next to training jobs.

Task governance is built on **Kueue**, a Kubernetes job-queueing system. The terms this lab uses:

- **Compute allocation** (also called compute quota): the GPUs a team is guaranteed. Each allocation gives the team a namespace, `hyperpod-ns-<team>`.
- **ClusterQueue**: Kueue's record of one team's quota and usage. **LocalQueue**: the queue in the team's namespace that workloads are submitted to; it feeds the team's ClusterQueue.
- **Cohort**: the group of ClusterQueues that can share idle quota. Here, both teams are in one cohort.
- **Lending** and **borrowing**: a team lends quota it isn't using, and another team borrows it, up to a **borrow limit**.
- **Reclaim**: when the lending team needs its quota back, Kueue evicts the borrower's work.
- **Preemption**: Kueue evicts a running workload to make room for a higher-priority one.
- **Priority class**: a named priority weight. Higher weights win. Kueue's version is a `WorkloadPriorityClass`.
- **Cluster policy**: the cluster-wide task governance setting that defines the priority classes and how idle capacity is shared.
- **Workload**: Kueue's object for something that asks for resources, such as a training job or an endpoint's pods. Kueue admits or evicts workloads, and their pods run only while the workload is admitted.

## Prerequisites

This lab needs two `ml.g5.2xlarge` GPU nodes and the following task governance setup:

- The HyperPod task governance add-on, which installs Kueue.
- A cluster policy with the priority classes `inference` (weight 90), `experimentation` (80), `training` (70), and `fine-tuning` (50).
- One compute allocation for each of two teams, `team-a` and `team-b`: **1 x `ml.g5.2xlarge`** each, with `LendAndBorrow`, `BorrowLimit=100`, and `PreemptTeamTasks=LowerPriority`. The allocations create the namespaces `hyperpod-ns-team-a` and `hyperpod-ns-team-b`.

If you did the base workshop's task governance section, your cluster may already have exactly this. Check first, then set up only what's missing.

### Check what your cluster has

The command below prints the status of the add-on, the cluster policy, the compute allocations, and the priority classes:

```bash
echo "Task governance add-on: $(aws eks describe-addon --cluster-name $EKS_CLUSTER_NAME \
  --addon-name amazon-sagemaker-hyperpod-taskgovernance --region $REGION \
  --query addon.status --output text 2>/dev/null || echo 'not installed')"
echo "Cluster policy:"
aws sagemaker list-cluster-scheduler-configs --cluster-arn "$HYPERPOD_CLUSTER_ARN" --region $REGION \
  --query 'ClusterSchedulerConfigSummaries[].[Name,Status]' --output text | sed 's/^/  /' | grep . || echo "  none"
echo "Compute allocations:"
aws sagemaker list-compute-quotas --cluster-arn "$HYPERPOD_CLUSTER_ARN" --region $REGION \
  --query 'ComputeQuotaSummaries[].[ComputeQuotaTarget.TeamName,Name,Status]' --output text | sed 's/^/  /' | grep . || echo "  none"
echo "Priority classes:"
kubectl get workloadpriorityclass --no-headers 2>/dev/null | awk '{print "  " $1 " (weight " $2 ")"}' | grep . || echo "  none"
```

You're ready when all of the following are true:

- The add-on is `ACTIVE`.
- There is a cluster policy.
- Both `team-a` and `team-b` have an allocation.
- The priority classes include `inference-priority` and `training-priority`. Task governance names each Kueue priority class after a cluster policy class, with `-priority` added.

If all of these are true, skip to "Free both GPUs" below. If anything is missing, run the three setup commands below in order, then the wait command. Each one skips what already exists, so it's safe to run all of them.

### Set up what's missing

Setup 1. The command below installs the task governance add-on if it isn't there, and waits until it's active (about 2 minutes):

```bash
if ! aws eks describe-addon --cluster-name $EKS_CLUSTER_NAME --addon-name amazon-sagemaker-hyperpod-taskgovernance \
     --region $REGION >/dev/null 2>&1; then
  aws eks create-addon --cluster-name $EKS_CLUSTER_NAME --addon-name amazon-sagemaker-hyperpod-taskgovernance \
    --region $REGION >/dev/null && echo "installing the task governance add-on"
fi
aws eks wait addon-active --cluster-name $EKS_CLUSTER_NAME --addon-name amazon-sagemaker-hyperpod-taskgovernance \
  --region $REGION && echo "task governance add-on: ACTIVE"
```

Expected: `task governance add-on: ACTIVE`.

Setup 2. The command below creates the cluster policy, which defines the priority classes, if the cluster has none:

```bash
if aws sagemaker list-cluster-scheduler-configs --cluster-arn "$HYPERPOD_CLUSTER_ARN" --region $REGION \
     --query 'ClusterSchedulerConfigSummaries[0].Name' --output text | grep -qv None; then
  echo "cluster policy: already exists"
else
  aws sagemaker create-cluster-scheduler-config --name dive-deep-policy --cluster-arn "$HYPERPOD_CLUSTER_ARN" \
    --scheduler-config "PriorityClasses=[{Name=inference,Weight=90},{Name=experimentation,Weight=80},{Name=training,Weight=70},{Name=fine-tuning,Weight=50}],FairShare=Enabled" \
    --region $REGION --query ClusterSchedulerConfigId --output text | sed 's/^/created cluster policy /'
fi
```

Expected: `cluster policy: already exists` or `created cluster policy <id>`.

> [!WARNING]
> If your cluster already had a cluster policy, this command leaves it unchanged. If the check then doesn't list `inference-priority` and `training-priority`, update the existing cluster policy to add the `inference` and `training` priority classes.

Setup 3. The command below creates the compute allocation for each team, or updates an existing one to the settings this lab needs:

```bash
CONFIG="ComputeQuotaResources=[{InstanceType=ml.g5.2xlarge,Count=1}],ResourceSharingConfig={Strategy=LendAndBorrow,BorrowLimit=100},PreemptTeamTasks=LowerPriority"
for TEAM in team-a team-b; do
  read -r ID VERSION <<<"$(aws sagemaker list-compute-quotas --cluster-arn "$HYPERPOD_CLUSTER_ARN" --region $REGION \
    --query "ComputeQuotaSummaries[?ComputeQuotaTarget.TeamName=='$TEAM'] | [0].[ComputeQuotaId,ComputeQuotaVersion]" --output text)"
  if [ -z "$ID" ] || [ "$ID" = None ]; then
    aws sagemaker create-compute-quota --name "${TEAM}-g5-2xl" --cluster-arn "$HYPERPOD_CLUSTER_ARN" --region $REGION \
      --compute-quota-config "$CONFIG" --activation-state Enabled \
      --compute-quota-target "TeamName=${TEAM},FairShareWeight=100" \
      --query ComputeQuotaId --output text | sed "s/^/${TEAM}: created allocation /"
  else
    aws sagemaker update-compute-quota --compute-quota-id "$ID" --target-version "$VERSION" --region $REGION \
      --compute-quota-config "$CONFIG" --query ComputeQuotaId --output text | sed "s/^/${TEAM}: updated allocation /"
  fi
done
```

Expected: one line per team, `team-a: created allocation <id>` or `team-a: updated allocation <id>`, and the same for `team-b`.

Why `BorrowLimit=100`: the borrow limit is a percentage of the team's own quota. With a one-node quota, `BorrowLimit=50` would allow half a GPU, which can't hold a pod.

Wait. The command below waits up to 5 minutes for both teams' LocalQueues to appear, then lists all LocalQueues:

```bash
for i in $(seq 30); do
  kubectl get localqueue -n hyperpod-ns-team-a --no-headers 2>/dev/null | grep -q . \
    && kubectl get localqueue -n hyperpod-ns-team-b --no-headers 2>/dev/null | grep -q . && break
  sleep 10
done
kubectl get localqueue -A
```

Expected: `hyperpod-ns-team-a-localqueue` in `hyperpod-ns-team-a` and `hyperpod-ns-team-b-localqueue` in `hyperpod-ns-team-b`. Then run the check under "Check what your cluster has" again and confirm every item.

### Free both GPUs

The lab needs both GPU nodes empty. The commands below delete the models earlier labs may have left, then list any model pods still running:

```bash
kubectl delete inferenceendpointconfig tinyllama-dd qwen-opt qwen-hf qwen-s3 qwen-fsx qwen-byoc -n $NAMESPACE --ignore-not-found
kubectl delete jumpstartmodel deepseek-js -n $NAMESPACE --ignore-not-found
kubectl get pods -A | grep -E 'tinyllama|qwen|deepseek' || echo "GPUs free"
```

Expected: `GPUs free`. Pods can take a minute to terminate; if some are still listed, run the command again. If something else holds a GPU (for example a training job from the base workshop), run `~/hyperpod-inference-dive-deep/scripts/reset-gpus.sh -y`.

## Opt an endpoint into governance

For reference; nothing to run here. Step 3 of the lab uses this.

An endpoint takes part in task governance when its custom resource carries two Kueue labels in `metadata`. They work on both `InferenceEndpointConfig` and `JumpStartModel`:

```yaml
metadata:
  name: <deployment-name>
  namespace: hyperpod-ns-<team>                                # the team's namespace
  labels:
    kueue.x-k8s.io/queue-name: hyperpod-ns-<team>-localqueue   # LocalQueue in the same namespace
    kueue.x-k8s.io/priority-class: inference-priority          # <cluster policy class name>-priority
```

The command below lists the LocalQueue names, the priority class names, and the ClusterQueues on your cluster, so you can fill in the labels:

```bash
kubectl get localqueue -A
kubectl get workloadpriorityclass
kubectl get clusterqueue
```

Expected: one LocalQueue and one ClusterQueue per team (`hyperpod-ns-team-a-clusterqueue`, `hyperpod-ns-team-b-clusterqueue`), and priority classes such as `inference-priority` (value 90) and `training-priority` (value 70).

## How Kueue treats an inference replica

For reference; nothing to run. The lab below shows each of these in action.

Kueue tries these options in order when a workload asks for GPUs:

1. **Team quota**: if the team has unused guaranteed GPUs, admit the workload.
2. **Self-preemption**: otherwise, preempt lower-priority workloads **of the same team**. For example, a `training-priority` job yields to `inference-priority`.
3. **Borrowing**: otherwise, borrow idle quota from other teams, up to the borrow limit. **Borrowed capacity can be reclaimed.** When the lending team submits work, Kueue evicts the borrower's lowest-priority workloads until the borrower is back within its quota.
4. If none of these works, the workload stays pending (`QuotaReserved: False`), and its pods stay `SchedulingGated` (created but held back from scheduling).

## Lab: borrowing, preemption, and reclaim

You run four steps in order:

1. Define a stand-in for a training job.
2. Team A fills both GPUs with training: one on its own quota, one borrowed from team B.
3. Team A deploys inference, which preempts one of its own training jobs.
4. Team B reclaims its node, and Kueue evicts team A's training job, not its inference.

### 1. A training stand-in

Real training jobs take minutes to start. This lab uses a one-GPU Kubernetes `Job` that only holds its GPU for an hour; Kueue treats it like any other training workload.

The Kueue labels go on both the Job and its pod template. HyperPod's `hyperpod-task-governance-admission-policy` rejects any pod in a team namespace that lacks `kueue.x-k8s.io/queue-name`.

The command below defines a shell function, `submit_training <team> <job-name>`, that the next steps use. It doesn't submit anything yet:

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

Expected: no output.

> [!WARNING]
> Every pod admitted through a queue with topology-aware scheduling must request at least one resource. A pod with no `resources.requests` fails admission with `failed to assign flavors to pod set main: no TAS flavor assigned` and stays `SchedulingGated` forever. That's why even helper pods (such as the `etcd` pod in the task governance imagenet example) need small requests, for example `cpu: 100m, memory: 128Mi`.

### 2. Team A fills the cluster

Team A submits two training jobs. The first uses team A's own node; the second borrows team B's idle node. The commands below submit both, wait 15 seconds, and show team A's workloads and its ClusterQueue's GPU usage:

```bash
submit_training team-a train-a1
submit_training team-a train-a2
sleep 15
kubectl get workloads -n hyperpod-ns-team-a
kubectl get clusterqueue hyperpod-ns-team-a-clusterqueue \
  -o jsonpath='{range .status.flavorsUsage[*].resources[*]}{.name}{"\tused="}{.total}{"\tborrowed="}{.borrowed}{"\n"}{end}'
```

Expected:

- Two workloads, one per job (named `job-train-a1-...` and `job-train-a2-...`), both `ADMITTED: True`.
- The ClusterQueue shows `nvidia.com/gpu used=2 borrowed=1`: team A uses two GPUs, one of them borrowed from team B. The `cpu` and `memory` lines show the other requested resources.

If a workload isn't admitted yet, wait a few seconds and run the two `kubectl get` commands again.

### 3. Team A deploys inference

Team A now deploys a TinyLlama endpoint at `inference-priority`. Team A has no free GPU, so Kueue has to preempt one of team A's own training jobs (self-preemption).

The command below writes the `InferenceEndpointConfig`, with the two Kueue labels in its `metadata`, to `tinyllama-team-a.yaml` and applies it:

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

Expected: `inferenceendpointconfig.inference.sagemaker.aws.amazon.com/tinyllama-team-a created`.

The command below prints team A's workloads and pods every 15 seconds. It stops when the inference pod is running, or after 10 minutes:

```bash
for i in $(seq 40); do
  echo "--- $(date +%T)"
  kubectl get workloads -n hyperpod-ns-team-a
  kubectl get pods -n hyperpod-ns-team-a --no-headers | awk '{print $1, $2, $3}'
  kubectl get pods -n hyperpod-ns-team-a --no-headers | grep tinyllama-team-a | grep -q ' Running ' && break
  sleep 15
done
```

Expected, over a few minutes:

- A new workload for `tinyllama-team-a` appears and becomes admitted.
- One training workload (usually `train-a2`, the one admitted last) loses its admission, and its pod terminates.
- The `tinyllama-team-a` pod goes from `SchedulingGated` or `Pending` to `Running`. Downloading the model from Hugging Face takes a few minutes.

The command below shows each training workload's conditions, which say why Kueue evicted it:

```bash
for WL in $(kubectl get workloads -n hyperpod-ns-team-a -o name | grep job-train); do
  echo "== $WL"
  kubectl get $WL -n hyperpod-ns-team-a \
    -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.message}{"\n"}{end}'
done
```

Expected: for the evicted job, `Preempted to accommodate a workload ... due to prioritization in the ClusterQueue`. That's self-preemption: inference outranks training within team A. The evicted job stays queued and is admitted again when capacity frees up. The other training job shows no `Preempted` condition.

> [!NOTE]
> If no workload appears for the inference pods, the labels didn't reach Kueue. Check that they're on the custom resource's `metadata.labels` (not a pod template), that the LocalQueue exists in the same namespace, and that the priority class name matches `kubectl get workloadpriorityclass`.

### 4. Team B reclaims its node

Team A still uses team B's node: one training job and the inference endpoint, two GPUs against a quota of one. Now team B submits work of its own and claims its guaranteed node back.

The command below submits `train-b1` for team B, then prints all team workloads every 15 seconds. It stops when `train-b1` is running, or after 10 minutes:

```bash
submit_training team-b train-b1
for i in $(seq 40); do
  echo "--- $(date +%T)"
  kubectl get workloads -A | grep -E 'NAMESPACE|team-'
  kubectl get pods -n hyperpod-ns-team-b --no-headers 2>/dev/null | grep train-b1 | grep -q ' Running ' && break
  sleep 15
done
```

Expected: within a minute or two, team A's remaining training workload loses its admission, and `train-b1` is admitted and starts running.

Why Kueue evicts the training job and not the endpoint:

- Kueue brings team A back within its own quota so team B gets its guaranteed node.
- Quota is accounting, not node placement. Kueue doesn't look for "the pod on the borrowed node".
- It evicts team A's **lowest-priority** workload: the remaining training job (usually `train-a1`). The inference endpoint keeps running.

To see the reason, run the eviction-reason command from step 3 again. This time the message says `due to reclamation within the cohort`, not `due to prioritization in the ClusterQueue`.

The commands below show the final state: all team workloads, the pods of both teams with their nodes, and team A's GPU usage:

```bash
kubectl get workloads -A | grep -E 'NAMESPACE|team-'
kubectl get pods -n hyperpod-ns-team-a -o wide
kubectl get pods -n hyperpod-ns-team-b -o wide
kubectl get clusterqueue hyperpod-ns-team-a-clusterqueue \
  -o jsonpath='{range .status.flavorsUsage[*].resources[?(@.name=="nvidia.com/gpu")]}{"used="}{.total}{" borrowed="}{.borrowed}{"\n"}{end}'
```

Expected:

- `train-b1` running, on the node that `train-a1` used.
- `tinyllama-team-a` still running.
- Team A at `used=1 borrowed=0`.

The takeaway: **reclaim follows priority.** Inference survived here because it outranks training. If team A had only inference replicas, the reclaim would evict one of them. So keep inference at the highest priority, and size an endpoint's minimum replicas to fit the team's guaranteed quota.

## Designing governance for inference

For reference; nothing to run.

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

The commands below delete the endpoint and the three training jobs, which frees both GPUs:

```bash
kubectl delete inferenceendpointconfig tinyllama-team-a -n hyperpod-ns-team-a --ignore-not-found
kubectl delete job train-a1 train-a2 -n hyperpod-ns-team-a --ignore-not-found
kubectl delete job train-b1 -n hyperpod-ns-team-b --ignore-not-found
```

Expected: a `deleted` line for each resource. The task governance add-on, cluster policy, and team allocations stay in place.

To run the earlier labs again, re-create `tinyllama-dd` with `kubectl apply -f tinyllama-dd.yaml`.
