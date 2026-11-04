# 0. Set up your environment

Run this page once, in the Code Editor terminal, before the modules.

## Prerequisites

- A HyperPod EKS cluster with a GPU instance group of **2 x `ml.g5.2xlarge`** (1 x NVIDIA A10G 24 GB, 8 vCPU, 32 GiB each) and a CPU instance group (`ml.c5.4xlarge` or larger). Every model in this section fits on one A10G, and each replica takes a whole node. The cluster from the SageMaker HyperPod EKS workshop matches
- The **`amazon-sagemaker-hyperpod-inference`** EKS add-on. `scripts/setup.sh` installs it (see below)
- `kubectl`, `aws` CLI v2, `jq`, and `helm` in your terminal. The workshop's Code Editor has all four
- No Hugging Face account or token: every lab uses ungated models
- Module 6 only: the HyperPod task governance add-on, with the cluster policy and compute allocations from the workshop's task governance section

## Free the GPUs

Free the GPUs that the earlier inference labs and the training job may still hold. Each command is safe to run when the resource is already gone:

```bash
kubectl delete jumpstartmodel --all -n default
kubectl delete inferenceendpointconfig --all -n default
kubectl delete hyperpodpytorchjob --all -n default
kubectl get pods -n default
```

## Prepare the cluster

When no model or training pods are left, prepare the cluster. In the Code Editor terminal, clone this lab's repository and run its setup script:

```bash
cd ~
git clone https://github.com/hossam-basudan/sagemaker-hyperpod-inference-dive-deep.git hyperpod-inference-dive-deep
cd ~/hyperpod-inference-dive-deep
scripts/setup.sh
```

The script shows what it will create and asks before it changes anything. It takes about 12 minutes and is safe to rerun:

| Step | Why |
|---|---|
| Replaces a Helm-installed inference operator with the `amazon-sagemaker-hyperpod-inference` EKS add-on (operator v3.7) | The workshop cluster runs operator v2.2, which can't load models from Hugging Face and has no request limits or caching. The Helm release owns the operator's CRDs, so the script stops if any inference deployment still exists |
| Creates the add-on's IAM roles and an S3 bucket for TLS certificates | The add-on requires them. The operator only uses buckets whose names start with `hyperpod-tls` |
| Runs the add-on's controllers and `metrics-server` on the CPU instance group | Leaves the GPU nodes' few pod slots for models |
| Creates an S3 bucket for model weights (module 2), an ECR repository, and an AWS CodeBuild project (module 3) | The Code Editor can't run Docker, so module 3 builds its image in CodeBuild |
| Writes `env.sh` | The variables every module uses |

Load the variables. Run this again in every new terminal:

```bash
source ~/hyperpod-inference-dive-deep/env.sh
env | grep -E 'REGION|CLUSTER|ACCOUNT_ID|INSTANCE_TYPE|NAMESPACE|TLS_BUCKET|EXECUTION_ROLE|MODEL_BUCKET|ECR_REPOSITORY|BUILD_PROJECT'
```

<details>
<summary><b>Using a cluster that already runs the add-on?</b></summary>

You can set the variables by hand instead of running `scripts/setup.sh`. Replace the two placeholders. Modules 2 and 3 also need the model bucket, the ECR repository, and (without Docker) the CodeBuild project the script creates.

```bash
export REGION=us-west-2
export EKS_CLUSTER_NAME=<your-eks-cluster-name>
export HYPERPOD_CLUSTER_NAME=<your-hyperpod-cluster-name>

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

</details>


Confirm that the add-on is healthy and that your GPU nodes are visible:

```bash
aws eks describe-addon --cluster-name $EKS_CLUSTER_NAME \
  --addon-name amazon-sagemaker-hyperpod-inference --region $REGION \
  --query "addon.{Version:addonVersion,Status:status,Health:health.issues}" --output table

kubectl get nodes -L node.kubernetes.io/instance-type
```

## Optional: Prometheus metrics

Module 4's Prometheus trigger and module 5's metrics queries need the HyperPod observability add-on and an Amazon Managed Service for Prometheus workspace. To set them up (about 3 minutes):

```bash
~/hyperpod-inference-dive-deep/scripts/observability.sh
```

> [!WARNING]
> The observability add-on runs three DaemonSet pods on every node, at a priority that preempts anything else on a full node. Run `scripts/setup.sh` first, and install observability when no model is running. Amazon Managed Grafana isn't set up: it needs IAM Identity Center for sign-in, which workshop accounts don't have.

> [!NOTE]
> `kubectl explain` is the source of truth for every field in this section. If a field here differs from your operator version, run `kubectl explain inferenceendpointconfig.spec --recursive` (or `jumpstartmodel.spec`) and trust what your cluster reports.

## Next: run the modules as notebooks

`scripts/setup.sh` installed a Bash kernel for Jupyter. Instead of copying commands from the module pages, open [notebooks/01-operator-internals.ipynb](notebooks/01-operator-internals.ipynb) in the Code Editor, select the **Bash** kernel at the top right, and run the cells in order. Each notebook starts by loading `env.sh`.
