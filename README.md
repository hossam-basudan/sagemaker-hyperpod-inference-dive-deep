# HyperPod inference dive deep

This lab continues the [SageMaker HyperPod EKS workshop](https://catalog.us-east-1.prod.workshops.aws/workshops/5344c881-4077-471e-aedf-2944bd6fe8eb/en-US) on the same cluster, after its inference section. Run every command in the workshop's Code Editor.

> [!TIP]
> Each module is also a notebook in [notebooks/](notebooks/), with the same text and commands. After [00-setup.md](00-setup.md), open a notebook in the Code Editor, select the **Bash** kernel, and run the cells in order instead of copying commands into the terminal.


The earlier inference labs got a model serving through the HyperPod Inference Operator. This section opens it up: what the operator creates, where model weights come from, how to run your own serving container, and how to scale, observe, and govern inference alongside training on the same cluster.

| Module | You will |
|---|---|
| [0. Set up your environment](00-setup.md) | Check the prerequisites, free the GPUs, install the inference add-on and the resources the modules use, and load the variables |
| [1. Operator internals](01-operator-internals.md) | Inspect what the add-on installs, follow one deployment from custom resource to SageMaker endpoint, and call the model three ways |
| [2. Bring your own model](02-bring-your-own-model.md) | Serve weights from Hugging Face (pinned and gated), Amazon S3, FSx for Lustre, and SageMaker JumpStart; cache weights and images on the node |
| [3. Bring your own container](03-bring-your-own-container.md) | Learn the container contract, build a custom vLLM image, push it to Amazon ECR, and deploy it with explicit probes |
| [4. Autoscaling](04-autoscaling.md) | Scale replicas with KEDA on CloudWatch and Prometheus metrics, and understand scale to zero |
| [5. Observability](05-observability.md) | Read the metrics the operator injects, apply request limits, query the metrics in Prometheus, and send operator logs to CloudWatch |
| [6. Task governance](06-task-governance.md) | Run inference under Kueue quotas and priorities next to training jobs |
| [7. Optimize](07-optimization.md) | Turn on tiered KV caching (LMCache with L1 and HyperPod tiered storage as L2), prefix-aware routing, and image and weights caching; measure the cache hits |

Each module is self-contained, but module 1 creates the `tinyllama-dd` endpoint that modules 4 and 5 reuse.

### GPU budget

With two `ml.g5.2xlarge` nodes you have two GPUs. Each module fits in that budget if you run its cleanup step before moving on:

| Module | GPUs in use |
|---|---|
| 1. Operator internals | 1 (`tinyllama-dd`) |
| 2. Bring your own model | 1 more, one model at a time |
| 3. Bring your own container | 1 more |
| 4. Autoscaling | 2 (`tinyllama-dd` scales from 1 to 2) |
| 5. Observability | 1 (`tinyllama-dd`) |
| 6. Task governance | 2 (one per team; delete `tinyllama-dd` first) |
| 7. Optimize | 2 (one replica per GPU node; delete the other deployments first) |

Pods per node are limited too. HyperPod sets each node's pod limit from one network interface's addresses: 14 on `ml.g5.2xlarge`, 29 on `ml.c5.4xlarge`. A pod that can't fit stays `Pending` with `Too many pods`. On a GPU node:

| Pods on one `ml.g5.2xlarge` | Count |
|---|---|
| System DaemonSets: HyperPod health agent, `aws-node`, `kube-proxy`, NVIDIA device plugin, Pod Identity agent, FSx and S3 CSI nodes | 7 |
| Controllers `scripts/setup.sh` can't move (inference operator, inference gateway, task governance), when the scheduler places them there | 0–3 |
| Optional observability add-on (Prometheus, modules 4 and 5): three DaemonSet pods, plus collectors the scheduler may place there | 3–6 |
| Modules 1–6: one model pod, sometimes a training pod | 1–2 |
| Module 7: model, tiered storage daemon, image cache, router | 3–4 |

`scripts/setup.sh` moves the other controllers to the CPU node and deletes the workshop's training-image pre-pull DaemonSet, so modules 1–6 fit with observability installed. Remove observability before module 7 (`scripts/observability.sh --remove`); module 7 checks the free slots first.

Start with [0. Set up your environment](00-setup.md).
