# HyperPod inference dive deep

Hands-on labs that go deeper into inference on SageMaker HyperPod EKS. They run on the cluster and in the Code Editor of the [SageMaker HyperPod EKS workshop](https://catalog.us-east-1.prod.workshops.aws/workshops/5344c881-4077-471e-aedf-2944bd6fe8eb/en-US). You don't need to run that workshop's labs first: lab 0 prepares the cluster. Its inference section is a gentler introduction if you're new to the HyperPod Inference Operator.

## Quick start

1. In the Code Editor, open a terminal (**Terminal** > **New Terminal**), then clone this repository and install the Bash kernel for the notebooks (a few seconds):

   ```bash
   cd ~
   git clone https://github.com/hossam-basudan/sagemaker-hyperpod-inference-dive-deep.git hyperpod-inference-dive-deep
   cd ~/hyperpod-inference-dive-deep
   scripts/install-kernel.sh
   ```

2. In the Explorer, open **hyperpod-inference-dive-deep/notebooks/00-setup.ipynb**.
3. Select the Bash kernel: **Select Kernel** (top right) > **Select Another Kernel...** > **Jupyter Kernel...** > **Bash**. If **Bash** isn't listed, reload the window (Command Palette > **Developer: Reload Window**).
4. Run the cells in order. Lab 0 prepares the cluster (about 15 minutes); then continue with lab 1.

## Labs


The HyperPod Inference Operator turns one Kubernetes custom resource into a serving model. This section opens it up: what the operator creates, where model weights come from, how to run your own serving container, and how to scale, observe, and govern inference alongside training on the same cluster.

| Module | You will |
|---|---|
| [0. Set up your environment](notebooks/00-setup.ipynb) | Check the prerequisites, free the GPUs, install the inference add-on and the resources the modules use, and load the variables |
| [1. Operator internals](notebooks/01-operator-internals.ipynb) | Inspect what the add-on installs, follow one deployment from custom resource to SageMaker endpoint, and call the model three ways |
| [2. Autoscaling](notebooks/02-autoscaling.ipynb) | Scale replicas with KEDA on CloudWatch and Prometheus metrics, and understand scale to zero |
| [3. Observability](notebooks/03-observability.ipynb) | Read the metrics the operator injects, apply request limits, query the metrics in Prometheus, and send operator logs to CloudWatch |
| [4. Bring your own model](notebooks/04-bring-your-own-model.ipynb) | Serve weights from Hugging Face (pinned and gated), Amazon S3, FSx for Lustre, and SageMaker JumpStart; cache weights and images on the node |
| [5. Bring your own container](notebooks/05-bring-your-own-container.ipynb) | Learn the container contract, build a custom vLLM image, push it to Amazon ECR, and deploy it with explicit probes |
| [6. Optimize](notebooks/06-optimization.ipynb) | Turn on tiered KV caching (LMCache with L1 and HyperPod tiered storage as L2), prefix-aware routing, and image and weights caching; measure the cache hits |
| [7. Task governance (optional)](notebooks/07-task-governance.ipynb) | Run inference under Kueue quotas and priorities next to training jobs |

Each module is self-contained, but module 1 creates the `tinyllama-dd` endpoint that modules 2 and 3 reuse, so run those right after it. Module 7 is optional.

### GPU budget

With two `ml.g5.2xlarge` nodes you have two GPUs. Each module fits in that budget if you run its cleanup step before moving on:

| Module | GPUs in use |
|---|---|
| 1. Operator internals | 1 (`tinyllama-dd`) |
| 2. Autoscaling | 2 (`tinyllama-dd` scales from 1 to 2) |
| 3. Observability | 1 (`tinyllama-dd`) |
| 4. Bring your own model | 1 more, one model at a time |
| 5. Bring your own container | 1 more |
| 6. Optimize | 2 (one replica per GPU node; delete the other deployments first) |
| 7. Task governance (optional) | 2 (one per team; delete the other deployments first) |

Pods per node are limited too. HyperPod sets each node's pod limit from one network interface's addresses: 14 on `ml.g5.2xlarge`, 29 on `ml.c5.4xlarge`. A pod that can't fit stays `Pending` with `Too many pods`. On a GPU node:

| Pods on one `ml.g5.2xlarge` | Count |
|---|---|
| System DaemonSets: HyperPod health agent, `aws-node`, `kube-proxy`, NVIDIA device plugin, Pod Identity agent, FSx and S3 CSI nodes | 7 |
| Controllers `scripts/setup.sh` can't move (inference operator, inference gateway, task governance), when the scheduler places them there | 0–3 |
| Optional observability add-on (Prometheus, modules 2 and 3): three DaemonSet pods, plus collectors the scheduler may place there | 3–6 |
| Modules 1–5 and 7: one model pod, sometimes a training pod | 1–2 |
| Module 6: model, tiered storage daemon, image cache, router | 3–4 |

`scripts/setup.sh` moves the other controllers to the CPU node and deletes the workshop's training-image pre-pull DaemonSet, so modules 1–5 fit with observability installed. Remove observability before module 6 (`scripts/observability.sh --remove`); module 6 checks the free slots first. Module 7 doesn't need observability.

