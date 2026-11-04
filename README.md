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


The HyperPod Inference Operator is a Kubernetes operator: a controller that runs in your cluster and acts on custom resources (Kubernetes objects whose type an add-on defines). You describe a model deployment in one custom resource, and the operator turns it into running model servers, a load balancer, and an optional SageMaker AI endpoint.

In this lab you open up that process. You'll see what the operator creates, where model weights come from, how to run your own serving container, and how to scale, observe, and govern inference alongside training on the same cluster.

Run lab 0 first. It installs what every other lab needs.

| Lab | You will |
|---|---|
| [0. Set up your environment](notebooks/00-setup.ipynb) | Check the prerequisites, free the GPUs, install the inference add-on and the AWS resources the labs use, and load the variables |
| [1. Operator internals](notebooks/01-operator-internals.ipynb) | Inspect what the add-on installs, follow one deployment from custom resource to SageMaker AI endpoint, and call the model three ways |
| [2. Autoscaling](notebooks/02-autoscaling.ipynb) | Scale replicas with KEDA (Kubernetes event-driven autoscaling) on CloudWatch and Prometheus metrics, and understand scale to zero |
| [3. Observability](notebooks/03-observability.ipynb) | Read the metrics the operator adds, apply request limits, query the metrics in Prometheus, and send operator logs to CloudWatch |
| [4. Bring your own model](notebooks/04-bring-your-own-model.ipynb) | Serve weights from Hugging Face (pinned and gated), Amazon S3, FSx for Lustre, and SageMaker JumpStart; cache weights and images on the node |
| [5. Bring your own container](notebooks/05-bring-your-own-container.ipynb) | Learn the contract a serving container must meet, build a custom vLLM image, push it to Amazon ECR, and deploy it with explicit health probes |
| [6. Optimize](notebooks/06-optimization.ipynb) | Turn on tiered KV caching (LMCache with L1 and HyperPod tiered storage as L2), prefix-aware routing, and image and weights caching; measure the cache hits |
| [7. Task governance (optional)](notebooks/07-task-governance.ipynb) | Run inference under Kueue quotas and priorities next to training jobs |

How the labs depend on each other:

- Lab 1 creates the `tinyllama-dd` endpoint. Labs 2 and 3 reuse it, so run them right after lab 1.
- Labs 4 to 7 don't need anything from earlier labs except lab 0. Each one tells you what to delete first.
- Lab 7 is optional.

### GPU budget

Your cluster has two `ml.g5.2xlarge` nodes with one GPU each, so two GPUs in total. Each model replica takes one whole GPU. Every lab fits in two GPUs if you run its cleanup step before you move on.

For reference; nothing to run. Each lab tells you what to delete before it starts.

| Lab | GPUs in use |
|---|---|
| 1. Operator internals | 1 (`tinyllama-dd`) |
| 2. Autoscaling | 2 (`tinyllama-dd` scales from 1 to 2 replicas) |
| 3. Observability | 1 (`tinyllama-dd`) |
| 4. Bring your own model | 2 (`tinyllama-dd`, plus one other model at a time) |
| 5. Bring your own container | 2 (`tinyllama-dd`, plus the custom container) |
| 6. Optimize | 2 (one replica per GPU node; delete the other deployments first) |
| 7. Task governance (optional) | 2 (one per team; delete the other deployments first) |

If a lab finds no free GPU, lab 0 shows how to free them with `scripts/reset-gpus.sh`.

### Pod budget

For reference; nothing to run. `scripts/setup.sh` and lab 6 handle this for you.

Each node can also run only a limited number of pods. HyperPod sets the limit from the IP addresses of one network interface: 14 pods on `ml.g5.2xlarge`, 29 on `ml.c5.4xlarge`. A pod that doesn't fit stays `Pending` with the message `Too many pods`.

What runs on one GPU node:

| Pods on one `ml.g5.2xlarge` | Count |
|---|---|
| System DaemonSets (one pod per node): HyperPod health agent, `aws-node`, `kube-proxy`, NVIDIA device plugin, Pod Identity agent, FSx and S3 CSI nodes | 7 |
| Controllers that `scripts/setup.sh` can't move (inference operator, inference gateway, task governance), if the scheduler places them on this node | 0–3 |
| Optional observability add-on (Prometheus, labs 2 and 3): three DaemonSet pods, plus collectors the scheduler may place here | 3–6 |
| Labs 1–5 and 7: one model pod, sometimes a training pod | 1–2 |
| Lab 6: model, tiered storage daemon, image cache, router | 3–4 |

What this means for you:

- `scripts/setup.sh` (lab 0) moves the controllers it can to the CPU node and deletes the workshop's training-image pre-pull DaemonSet. After that, labs 1–5 fit even with the observability add-on installed.
- Before lab 6, remove the observability add-on with `scripts/observability.sh --remove`. Lab 6 checks the free pod slots before it deploys.
- Lab 7 doesn't need the observability add-on.

