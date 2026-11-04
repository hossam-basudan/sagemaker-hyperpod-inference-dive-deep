# 0. Set up your environment

Run this page once, before any other lab. It frees the GPUs, installs the HyperPod inference add-on and the AWS resources the labs use, and writes `env.sh`, the file of variables every lab loads. Plan for about 15 minutes, most of it waiting for step 3.

## Prerequisites

What you need before you start:

- **A HyperPod EKS cluster** with two instance groups:
  - GPU: **2 x `ml.g5.2xlarge`**. Each node has one NVIDIA A10G GPU (24 GB), 8 vCPUs, and 32 GiB of memory. Every model in this lab fits on one A10G, and each model replica takes a whole node.
  - CPU: one `ml.c5.4xlarge` or larger.

  The cluster from the SageMaker HyperPod EKS workshop has exactly this layout.
- **Tools:** `kubectl`, AWS CLI v2, `jq`, and `helm`. The workshop's Code Editor already has all four.

What you don't need:

- **The inference add-on.** The `amazon-sagemaker-hyperpod-inference` EKS add-on (the packaged HyperPod Inference Operator) is installed by `scripts/setup.sh` in step 3.
- **A Hugging Face account or token.** Every lab uses ungated models (models anyone can download).
- **Task governance.** Only lab 7 (optional) uses it: HyperPod task governance with two team allocations. If you skipped the workshop's task governance section, lab 7 sets it up for you.

## 1. Get the lab files

Do this step in the Code Editor terminal (**Terminal > New Terminal**), not in a notebook: it downloads the notebooks themselves.

The commands below clone this lab's repository into your home directory and install the Bash kernel for Jupyter. They take a few seconds.

```bash
cd ~
git clone https://github.com/hossam-basudan/sagemaker-hyperpod-inference-dive-deep.git hyperpod-inference-dive-deep
cd ~/hyperpod-inference-dive-deep
scripts/install-kernel.sh
```

Expected: `git` reports the clone, and `install-kernel.sh` finishes without an error.

From here on, choose where to run the commands. You can switch for each lab.

- **In the terminal:** keep going on this page and run each command block below in the same terminal.
- **In a notebook:** open `notebooks/00-setup.ipynb` from the Explorer and select the **Bash** kernel. Click **Select Kernel** at the top right (or the kernel name shown there, such as `base (Python 3.x)`), then **Select Another Kernel...** > **Jupyter Kernel...** > **Bash**. If **Bash** isn't listed, reload the window (Command Palette > **Developer: Reload Window**). Then run the cells in order. The kernel is one shell, so variables and functions carry over from one cell to the next, as in a terminal.

## 2. Free the GPUs

The workshop's earlier inference labs and training job may still hold the two GPUs. The setup in step 3 stops if any inference deployment still exists, so remove them first.

The commands below delete every JumpStart model, inference deployment (`InferenceEndpointConfig`), and HyperPod training job (`HyperPodPyTorchJob`) in every namespace, then list the pods left in `default`. Each delete is safe to run when there is nothing to delete.

```bash
kubectl delete jumpstartmodel --all -A
kubectl delete inferenceendpointconfig --all -A
kubectl delete hyperpodpytorchjob --all -A
kubectl get pods -n default
```

Expected:

- Each delete prints the names of what it deleted, or `No resources found`. A delete can take up to a minute while the operator removes the endpoint's load balancer.
- If a delete prints `error: the server doesn't have a resource type ...`, that type isn't installed on your cluster. That's fine.
- The last command lists no model or training pods, or prints `No resources found in default namespace`. Pods in `Terminating` state go away on their own: wait a minute and run `kubectl get pods -n default` again until they're gone.

## 3. Prepare the cluster

This step runs `scripts/setup.sh`, which installs everything the labs need. It takes about 12 minutes, prints its progress, and is safe to rerun if it stops partway.

For reference, what the script does and why:

| Step | Why |
|---|---|
| Replaces the Helm-installed inference operator with the `amazon-sagemaker-hyperpod-inference` EKS add-on (add-on v2.1.0, operator v3.7) | The workshop cluster runs operator v2.2, which can't load models from Hugging Face and has no request limits or caching. The Helm release owns the operator's CRDs (custom resource definitions, the schemas of the custom resources), so removing it deletes every inference deployment. The script stops if any still exists |
| Creates the add-on's IAM roles and an S3 bucket for TLS certificates | The add-on requires them. The operator only uses buckets whose names start with `hyperpod-tls` |
| Runs the add-on's controllers and `metrics-server` on the CPU instance group | Leaves the GPU nodes' few pod slots for models |
| Creates an S3 bucket for model weights (lab 4), and an Amazon ECR repository and an AWS CodeBuild project (lab 5) | The Code Editor can't run Docker, so lab 5 builds its container image in CodeBuild |
| Writes `env.sh` | The variables every lab uses |
| Installs the Bash kernel for Jupyter (again; quick if step 1 already did) | The notebooks run in it |

Run the setup script. The `-y` flag skips its confirmation prompt. Without `-y`, the script first lists the account, cluster, and resource names it will use, and asks before it changes anything.

```bash
cd ~/hyperpod-inference-dive-deep
scripts/setup.sh -y
```

Expected (about 12 minutes): a summary of the account, Region, and cluster, then one `==>` line per stage. Installing the add-on takes about 5 minutes of that. At the end, the `Status` stage prints the add-on as `ACTIVE`, a `model sources:` line that includes `huggingface`, and your nodes, followed by `Done.`

If the script stops with `ERROR: delete these inference deployments first, then rerun`, delete the deployments it lists, then run it again.

## 4. Load the variables

The command below loads the variables from `env.sh` and prints them. Run `source ~/hyperpod-inference-dive-deep/env.sh` again whenever you open a new terminal. Each lab's notebook already does this at the top.

```bash
source ~/hyperpod-inference-dive-deep/env.sh
env | grep -E 'REGION|CLUSTER|ACCOUNT_ID|INSTANCE_TYPE|NAMESPACE|TLS_BUCKET|EXECUTION_ROLE|MODEL_BUCKET|ECR_REPOSITORY|BUILD_PROJECT'
```

Expected: a line for each variable, including `REGION`, `EKS_CLUSTER_NAME`, `HYPERPOD_CLUSTER_NAME`, `INSTANCE_TYPE=ml.g5.2xlarge`, `NAMESPACE=default`, `TLS_BUCKET=hyperpod-tls-...`, `EXECUTION_ROLE_ARN`, `MODEL_BUCKET`, `ECR_REPOSITORY_URL`, and `BUILD_PROJECT`. None of them should be empty.

<details>
<summary><b>Using a cluster that already runs the add-on?</b></summary>

Only if you didn't run `scripts/setup.sh`: you can set the core variables by hand instead. Replace the two `<...>` placeholders with your cluster names. This doesn't create the model bucket, the ECR repository, or the CodeBuild project, so labs 4 and 5 still need those.

```bash
export REGION=us-west-2
export EKS_CLUSTER_NAME="<your-eks-cluster-name>"
export HYPERPOD_CLUSTER_NAME="<your-hyperpod-cluster-name>"

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export HYPERPOD_CLUSTER_ARN=$(aws sagemaker describe-cluster \
  --cluster-name $HYPERPOD_CLUSTER_NAME --region $REGION \
  --query ClusterArn --output text)
export INSTANCE_TYPE=ml.g5.2xlarge
export NAMESPACE=default

# Values the add-on was installed with
export ADDON_CONFIG=$(aws eks describe-addon \
  --cluster-name $EKS_CLUSTER_NAME \
  --addon-name amazon-sagemaker-hyperpod-inference \
  --region $REGION \
  --query addon.configurationValues --output text)
export TLS_BUCKET=$(echo "$ADDON_CONFIG" | jq -r .tlsCertificateS3Bucket)
export EXECUTION_ROLE_ARN=$(echo "$ADDON_CONFIG" | jq -r .executionRoleArn)
```

Expected: no output. Check that `echo $TLS_BUCKET $EXECUTION_ROLE_ARN` prints two values, not `null`.

</details>


## 5. Check the add-on and the nodes

The commands below show the add-on's version and health, and list the cluster's nodes with their instance types.

```bash
aws eks describe-addon --cluster-name $EKS_CLUSTER_NAME \
  --addon-name amazon-sagemaker-hyperpod-inference --region $REGION \
  --query "addon.{Version:addonVersion,Status:status,Health:health.issues}" --output table

kubectl get nodes -L node.kubernetes.io/instance-type
```

Expected:

- The table shows `Status` as `ACTIVE`, and no health issues (an empty or `None` value).
- The node list shows two `ml.g5.2xlarge` nodes and at least one CPU node (such as `ml.c5.4xlarge`), all `Ready`.

You're ready for the labs once both checks pass.

> [!NOTE]
> If a later lab finds the GPUs taken (a pod stays `Pending` with `Insufficient nvidia.com/gpu`), run `~/hyperpod-inference-dive-deep/scripts/reset-gpus.sh` (add `-y` to skip its confirmation prompt). It lists every model, training job, and cache the labs leave behind, asks before it deletes them, and shows what's left on each GPU node. Afterward, redeploy `tinyllama-dd` from lab 1 if the lab needs it.

> [!NOTE]
> To see how full each node is at any time, run `~/hyperpod-inference-dive-deep/scripts/node-pods.sh`. It prints each node's pods against its pod limit, its free slots, and the GPUs requested, then lists the pods by namespace and says which are DaemonSet pods (one on every node) and which could run on another node. Add `-s` for one line per node. It changes nothing.

## Optional: Prometheus metrics

Two parts of later labs read metrics from Prometheus: lab 2's Prometheus trigger and lab 3's metrics queries. They need the HyperPod observability add-on and an Amazon Managed Service for Prometheus workspace. If you skip this step, skip those two parts; the rest of labs 2 and 3 still works.

> [!WARNING]
> The observability add-on runs three DaemonSet pods on every node, at a priority that evicts other pods when a node is full. Install it only after `scripts/setup.sh` has finished and while no model is running. Remove it before lab 6. Amazon Managed Grafana isn't set up: it needs IAM Identity Center for sign-in, which workshop accounts don't have.

The command below creates the Prometheus workspace and installs the observability add-on. The `-y` flag skips its confirmation prompt.

```bash
~/hyperpod-inference-dive-deep/scripts/observability.sh -y
```

Expected (about 3 minutes): the script prints the add-on as `ACTIVE`, then `Done.` and the Prometheus query URL. If it prints a `WARNING` that a node is nearly full of pods, see the alert above. Metrics reach the workspace a few minutes after the add-on is `ACTIVE`.

> [!NOTE]
> For reference: `kubectl explain` is the source of truth for every custom resource field in these labs. If a field in a lab differs from your operator version, run `kubectl explain inferenceendpointconfig.spec --recursive` (or `jumpstartmodel.spec`) and trust what your cluster reports.

## Next

Continue with [1. Inference Operator internals](01-operator-internals.md).
