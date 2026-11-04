# 4. Bring your own model

In this lab you deploy the same small model, Qwen 2.5 1.5B Instruct, from four sources: Hugging Face, Amazon S3, FSx for Lustre, and SageMaker JumpStart. Where the weights live decides how fast a new pod starts, whether the cluster needs internet access, and how you serve a model you trained yourself.

You describe each deployment with an `InferenceEndpointConfig`: the operator's Kubernetes resource for one model deployment (image, weights, instance type, scaling). Its `spec.modelSourceConfig` block tells the operator where the weights live. Whatever the source, the model server finds the weights at the same path, `worker.modelVolumeMount.mountPath` (default `/opt/ml/model`). Only the way they get there changes.

**Which source to choose:**

| `modelSourceType` | Weights come from | Choose it for | Cold-start cost |
|---|---|---|---|
| `huggingface` | Hugging Face Hub, downloaded by an init container (`prefetchEnabled: true`) or by the model server itself | Fast experiments with public or gated models | Download on every new pod; needs internet egress |
| `s3` | Your S3 bucket, through the Mountpoint for Amazon S3 CSI driver | Fine-tuned checkpoints, clusters without internet access | Streamed from S3; `prefetchEnabled` copies the weights first |
| `fsx` | FSx for Lustre, through the FSx CSI driver | Large models, many replicas, checkpoints already on FSx from training | Lowest; every pod reads one shared copy |
| `kubernetesVolume` | Any Kubernetes volume you define | Custom storage (not covered in this lab) | Depends on the volume |
| `JumpStartModel` (separate resource kind) | SageMaker JumpStart public hub | Curated models with a tested image and settings | Managed by the operator |

Terms used on this page:

- **Init container**: a container Kubernetes runs to completion before the main container starts.
- **Prefetch** (`prefetchEnabled: true`): an init container copies the weights to the pod's local disk before the model server starts.
- **CSI driver** (Container Storage Interface): a Kubernetes plugin that mounts external storage, such as an S3 bucket or an FSx file system, into pods.
- **PVC** (PersistentVolumeClaim): a pod's request for a storage volume.

> [!NOTE]
> Run the sections in order. Your two `ml.g5.2xlarge` nodes have one GPU each: `tinyllama-dd` from lab 1 holds one, and each section below deploys one model on the other. Each section starts by deleting the previous section's model to free that GPU.

To see every field `modelSourceConfig` accepts on your cluster, run:

```bash
kubectl explain inferenceendpointconfig.spec.modelSourceConfig --recursive
```

Expected: a tree of field names, including `huggingFaceModel`, `s3Storage`, `fsxStorage`, `modelLocation`, and `prefetchEnabled`.

## Hugging Face: pin the revision

Use Hugging Face when the model is public on the Hub and the cluster can reach the internet. Nothing to stage: the pod downloads the weights when it starts.

`modelId` alone serves whatever is on the repository's `main` branch today, so a redeploy next week can pull different weights. To make the deployment reproducible, pin `commitSHA`: the 40-character Git commit ID of the exact revision you tested.

The command below looks up the current commit SHA of the model on the Hugging Face API and saves it in `HF_SHA`:

```bash
export HF_MODEL=Qwen/Qwen2.5-1.5B-Instruct
export HF_SHA=$(curl -s https://huggingface.co/api/models/$HF_MODEL | jq -r .sha)
echo $HF_SHA
```

Expected: a 40-character hex string. If it prints `null` or nothing, the Code Editor couldn't reach huggingface.co; run it again.

The command below writes `qwen-hf-pinned.yaml` and applies it:

```bash
cat > qwen-hf-pinned.yaml <<EOF
apiVersion: inference.sagemaker.aws.amazon.com/v1
kind: InferenceEndpointConfig
metadata:
  name: qwen-hf
  namespace: ${NAMESPACE}
spec:
  modelName: qwen2-5-1-5b-instruct
  instanceType: ${INSTANCE_TYPE}
  invocationEndpoint: v1/chat/completions
  modelSourceConfig:
    modelSourceType: huggingface
    prefetchEnabled: true
    huggingFaceModel:
      modelId: ${HF_MODEL}
      commitSHA: ${HF_SHA}
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
    args: ["--model", "/opt/ml/model", "--port", "8000", "--served-model-name", "qwen"]
EOF
kubectl apply -f qwen-hf-pinned.yaml
```

Expected: `inferenceendpointconfig.inference.sagemaker.aws.amazon.com/qwen-hf created`.

What the YAML sets:

- **`commitSHA`** pins the revision you looked up.
- **`prefetchEnabled: true`** makes an init container download the weights before vLLM starts. A failed download then fails fast and visibly, as `Init:CrashLoopBackOff`. With `false`, the model server (vLLM, TGI, SGLang) downloads the model itself at startup.
- **No `endpointName`**: this deployment gets an Application Load Balancer (ALB) but no SageMaker AI endpoint. That's enough for callers inside your network.

The loop below waits for the deployment. It prints the pod's status each time it changes and stops when the deployment completes or fails (or after 20 minutes):

```bash
LAST=
for i in $(seq 120); do
  NOW=$(kubectl get pods -n $NAMESPACE --no-headers 2>/dev/null | grep qwen-hf | awk '{print $1, $2, $3}')
  [ "$NOW" != "$LAST" ] && echo "$(date +%T)  $NOW" && LAST=$NOW
  STATE=$(kubectl get inferenceendpointconfig qwen-hf -n $NAMESPACE -o jsonpath='{.status.state}')
  case "$STATE" in DeploymentComplete|DeploymentFailed) echo "$STATE"; break ;; esac
  sleep 10
done
```

Expected: the pod shows an `Init:` status while the init container downloads, then `PodInitializing`, then `Running`, and the last line is `DeploymentComplete`. This takes a few minutes, longer if the node first has to pull the vLLM image. If it ends with `DeploymentFailed` or the pod shows `Init:CrashLoopBackOff`, see [Hugging Face download errors](#hugging-face-download-errors) below.

Test the model. Without a SageMaker endpoint, you call the pod directly. The command below:

1. Finds the pod and forwards its port 8000 to port 8000 on the Code Editor (`kubectl port-forward`, in the background).
2. Waits until `/health` answers.
3. Sends one OpenAI-style chat request. `model` must match the `--served-model-name` in the YAML, here `qwen`.
4. Stops the port forward.

```bash
POD=$(kubectl get pods -n $NAMESPACE -l app=qwen-hf -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward pod/$POD 8000:8000 -n $NAMESPACE >/dev/null & PF=$!
for i in $(seq 30); do curl -s -o /dev/null localhost:8000/health && break; sleep 1; done
curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "qwen",
  "messages": [{"role": "user", "content": "What is Amazon SageMaker HyperPod? Answer in two sentences."}],
  "max_tokens": 64
}' | jq -r '.choices[0].message.content'
kill $PF
```

Expected: a two-sentence answer about SageMaker HyperPod. The wording varies from run to run.

### Hugging Face download errors

Use this table only if the deployment fails. To see the init container's error, run `kubectl logs <pod> -c <init container> -n $NAMESPACE`; `kubectl describe pod <pod> -n $NAMESPACE` lists the container names.

| Init container error | Fix |
|---|---|
| Connection timeout | No egress to `*.huggingface.co` and `*.hf.co`. Add a NAT gateway, or use S3 or FSx instead |
| `Repository Not Found` | `modelId` must be `org/model` |
| `401 Unauthorized` | The model is gated (see below) |

After you fix the cause, recreate the pod with `kubectl delete pod -l app=<name> -n $NAMESPACE`.

### Gated models (reference only)

For reference; nothing to run. Every model in this workshop (TinyLlama, Qwen 2.5, and a JumpStart DeepSeek distill) is **ungated**, so you don't need a Hugging Face account or token.

A gated repository (for example Llama) requires you to accept its license and authenticate. To serve one:

1. Accept the model's license on huggingface.co.
2. Store your Hugging Face token as a Kubernetes secret in the endpoint's namespace. Replace `<your-hf-token>` with your token:

```bash
kubectl create secret generic hf-token-secret \
  --from-literal=token=<your-hf-token> -n $NAMESPACE
```

3. Reference the secret in `modelSourceConfig`:

```yaml
  modelSourceConfig:
    modelSourceType: huggingface
    prefetchEnabled: true
    huggingFaceModel:
      modelId: <org>/<gated-model>
      tokenSecretRef:
        name: hf-token-secret
        key: token
```

> [!WARNING]
> The operator passes the token as `HF_TOKEN` to the **init container only**. Keep `prefetchEnabled: true` for gated models: the model server never sees the token, so it can't download them itself.

## Amazon S3: serve your own checkpoint

Use S3 for a model you fine-tuned yourself, for example on HyperPod, or when the cluster has no internet access. You upload the weights to S3 once, and every pod reads them from your account.

The weights must be in Hugging Face layout (`config.json`, `*.safetensors`, tokenizer files). `modelLocation` is the prefix (folder) inside the bucket.

The command below stands in for your own checkpoint. It creates the model bucket if it doesn't exist, downloads Qwen to the Code Editor, and uploads it to `s3://$MODEL_BUCKET/qwen2.5-1.5b/`:

```bash
export MODEL_BUCKET=hyperpod-models-${ACCOUNT_ID}-${REGION}
aws s3 mb s3://$MODEL_BUCKET --region $REGION 2>/dev/null || true

pip install -q -U huggingface_hub   # includes the `hf` CLI
HF_HUB_DISABLE_PROGRESS_BARS=1 hf download Qwen/Qwen2.5-1.5B-Instruct --local-dir ./qwen2.5-1.5b >/dev/null \
  && echo "downloaded to ./qwen2.5-1.5b"
aws s3 sync ./qwen2.5-1.5b s3://$MODEL_BUCKET/qwen2.5-1.5b/ --exclude ".cache/*" --only-show-errors \
  && echo "uploaded to s3://$MODEL_BUCKET/qwen2.5-1.5b/"
aws s3 ls s3://$MODEL_BUCKET/qwen2.5-1.5b/ --human-readable --summarize
```

Expected: `downloaded to ./qwen2.5-1.5b`, `uploaded to s3://...`, then a file listing that ends with `Total Objects` and a `Total Size` of about 3 GiB. It takes a minute or two.

> [!NOTE]
> Keep these weights in S3. Lab 6 (Optimize) deploys from the same prefix.

The pods read the bucket with the IAM role of the **Mountpoint for Amazon S3 CSI driver** add-on, not with the operator's execution role. The command below prints that role's ARN:

```bash
aws eks describe-addon --cluster-name $EKS_CLUSTER_NAME \
  --addon-name aws-mountpoint-s3-csi-driver --region $REGION \
  --query addon.serviceAccountRoleArn --output text
```

Expected: an IAM role ARN. Nothing to change now. If the deployment later fails with `AccessDenied`, make sure this role allows `s3:ListBucket` on the bucket and `s3:GetObject` on its objects.

Free the GPU used by the Hugging Face model:

```bash
kubectl delete inferenceendpointconfig qwen-hf -n $NAMESPACE --ignore-not-found
```

Expected: `inferenceendpointconfig.inference.sagemaker.aws.amazon.com "qwen-hf" deleted`.

The command below writes `qwen-s3.yaml` and applies it. Compared with the Hugging Face YAML, only `modelSourceConfig`, the names, and `--served-model-name` change. `bucketName` is the bare bucket name, without `s3://`.

```bash
cat > qwen-s3.yaml <<EOF
apiVersion: inference.sagemaker.aws.amazon.com/v1
kind: InferenceEndpointConfig
metadata:
  name: qwen-s3
  namespace: ${NAMESPACE}
spec:
  modelName: qwen2-5-1-5b-s3
  instanceType: ${INSTANCE_TYPE}
  invocationEndpoint: v1/chat/completions
  modelSourceConfig:
    modelSourceType: s3
    s3Storage:
      bucketName: ${MODEL_BUCKET}
      region: ${REGION}
    modelLocation: qwen2.5-1.5b
    prefetchEnabled: true
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
    args: ["--model", "/opt/ml/model", "--port", "8000", "--served-model-name", "qwen-s3"]
EOF
kubectl apply -f qwen-s3.yaml
```

Expected: `inferenceendpointconfig.inference.sagemaker.aws.amazon.com/qwen-s3 created`.

The loop below waits for the deployment and prints each state change. The init container copies the weights from S3 first, so this takes a few minutes:

```bash
LAST=
for i in $(seq 120); do
  NOW=$(kubectl get inferenceendpointconfig qwen-s3 -n $NAMESPACE -o jsonpath='{.status.state}')
  [ "$NOW" != "$LAST" ] && echo "$(date +%T)  $NOW" && LAST=$NOW
  case "$NOW" in DeploymentComplete|DeploymentFailed) break ;; esac
  sleep 10
done
```

Expected: timestamped states, ending with `DeploymentComplete`.

Test the model the same way as the Hugging Face one, with `model` set to `qwen-s3`:

```bash
POD=$(kubectl get pods -n $NAMESPACE -l app=qwen-s3 -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward pod/$POD 8000:8000 -n $NAMESPACE >/dev/null & PF=$!
for i in $(seq 30); do curl -s -o /dev/null localhost:8000/health && break; sleep 1; done
curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "qwen-s3",
  "messages": [{"role": "user", "content": "Explain in two sentences why you would serve model weights from Amazon S3."}],
  "max_tokens": 64
}' | jq -r '.choices[0].message.content'
kill $PF
```

Expected: a two-sentence answer about serving weights from S3.

What the operator did with `prefetchEnabled: true`:

- It mounted the bucket through the S3 CSI driver as a PVC named `inference-s3-pvc-<name>-inf`.
- An init container named `prefetch-<name>-inf` copied the weights to the pod's local disk before vLLM started.
- That init container uses its own Amazon Linux image, not your `worker.image` (unlike the Hugging Face downloader).

## FSx for Lustre

Use FSx for Lustre when your training jobs already write checkpoints to it. You serve them in place, with no copy step, and every replica reads the same shared copy.

The workshop cluster mounts its file system through the `fsx-pv` volume and the `fsx-claim` claim in the `default` namespace, the same ones the training labs use. Not every cluster has them. The command below checks:

```bash
if kubectl get pv fsx-pv >/dev/null 2>&1 && kubectl get pvc fsx-claim -n $NAMESPACE >/dev/null 2>&1; then
  echo "FSx volume found: run this lab"
else
  echo "No FSx volume (fsx-pv, fsx-claim) on this cluster: skip to SageMaker JumpStart below"
fi
```

Expected: one of the two lines.

- `FSx volume found`: continue with the commands in this section.
- `No FSx volume`: skip the rest of this section and go to [SageMaker JumpStart](#sagemaker-jumpstart). Its first command also deletes the S3 model, so you don't lose anything.

Free the GPU used by the S3 model:

```bash
kubectl delete inferenceendpointconfig qwen-s3 -n $NAMESPACE --ignore-not-found
```

Expected: `inferenceendpointconfig.inference.sagemaker.aws.amazon.com "qwen-s3" deleted`.

Put a model on the file system to stand in for your checkpoint. The command below reads the file system ID into `FSX_ID`, then runs a short-lived pod that mounts `fsx-claim`, downloads Qwen into `models/qwen2.5-1.5b`, lists the files, and is deleted:

```bash
export FSX_ID=$(kubectl get pv fsx-pv -o jsonpath='{.spec.csi.volumeHandle}')
echo $FSX_ID
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: fsx-model-copy
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: copy
      image: public.ecr.aws/docker/library/python:3.12-slim
      command: ["bash", "-c", "pip install -q -U huggingface_hub && hf download Qwen/Qwen2.5-1.5B-Instruct --local-dir /fsx/models/qwen2.5-1.5b && ls -l /fsx/models/qwen2.5-1.5b"]
      volumeMounts:
        - {name: fsx, mountPath: /fsx}
  volumes:
    - name: fsx
      persistentVolumeClaim: {claimName: fsx-claim}
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/fsx-model-copy -n $NAMESPACE --timeout=15m
kubectl logs fsx-model-copy -n $NAMESPACE --tail=12
kubectl delete pod fsx-model-copy -n $NAMESPACE
```

Expected: a file system ID (`fs-...`), `pod/fsx-model-copy created`, `condition met`, a listing of the model files (`config.json`, `model.safetensors`, tokenizer files), and `pod "fsx-model-copy" deleted`. It usually takes about a minute, because the download stays inside AWS.

Optional; the workshop doesn't need it. On a cluster without `fsx-pv`, the command below lists your Lustre file systems so you can find the ID, DNS name, and mount name:

```bash
aws fsx describe-file-systems --region $REGION \
  --query 'FileSystems[?FileSystemType==`LUSTRE`].[FileSystemId,DNSName,LustreConfiguration.MountName]' --output table
```

Expected: a table with one row per Lustre file system.

The command below deploys from FSx and waits for it. Compared with the S3 YAML, only the source block changes: `fsxStorage` names the file system, and `modelLocation` is the path inside it.

```bash
cat > qwen-fsx.yaml <<EOF
apiVersion: inference.sagemaker.aws.amazon.com/v1
kind: InferenceEndpointConfig
metadata:
  name: qwen-fsx
  namespace: ${NAMESPACE}
spec:
  modelName: qwen2-5-1-5b-fsx
  instanceType: ${INSTANCE_TYPE}
  invocationEndpoint: v1/chat/completions
  modelSourceConfig:
    modelSourceType: fsx
    fsxStorage:
      fileSystemId: ${FSX_ID}   # dnsName and mountName are discovered when omitted
    modelLocation: models/qwen2.5-1.5b
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
    args: ["--model", "/opt/ml/model", "--port", "8000", "--served-model-name", "qwen-fsx"]
EOF
kubectl apply -f qwen-fsx.yaml
LAST=
for i in $(seq 120); do
  NOW=$(kubectl get inferenceendpointconfig qwen-fsx -n $NAMESPACE -o jsonpath='{.status.state}')
  [ "$NOW" != "$LAST" ] && echo "$(date +%T)  $NOW" && LAST=$NOW
  case "$NOW" in DeploymentComplete|DeploymentFailed) break ;; esac
  sleep 10
done
```

Expected: `qwen-fsx created`, then timestamped states ending with `DeploymentComplete`, in about 2 minutes. That's faster than the other sources because there's no init container: the operator mounts the file system as a volume (PVC `inference-fsx-pvc-qwen-fsx`), and vLLM reads the weights in place. Because every replica reads the same shared copy, FSx is the fastest way to scale out a large model.

Test the model, with `model` set to `qwen-fsx`:

```bash
POD=$(kubectl get pods -n $NAMESPACE -l app=qwen-fsx -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward pod/$POD 8000:8000 -n $NAMESPACE >/dev/null & PF=$!
for i in $(seq 30); do curl -s -o /dev/null localhost:8000/health && break; sleep 1; done
curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "qwen-fsx",
  "messages": [{"role": "user", "content": "Explain in two sentences what FSx for Lustre is."}],
  "max_tokens": 64
}' | jq -r '.choices[0].message.content'
kill $PF
```

Expected: a two-sentence answer about FSx for Lustre.

## SageMaker JumpStart

Use JumpStart when you want a curated model that AWS has already tested with a serving image and settings, and you don't want to pick them yourself. SageMaker JumpStart is SageMaker AI's catalog of pretrained models.

You deploy it with a `JumpStartModel`, a separate resource kind from `InferenceEndpointConfig`. You name a model from the JumpStart hub, and the operator chooses the image, weights, and server settings. There's no `worker` block.

The command below lists the DeepSeek models in the JumpStart public hub:

```bash
aws sagemaker list-hub-contents --hub-name SageMakerPublicHub --hub-content-type Model \
  --name-contains deepseek --region $REGION \
  --query 'HubContentSummaries[].[HubContentName,HubContentVersion]' --output table
```

Expected: a table of model IDs and versions. The deployment below uses `deepseek-llm-r1-distill-qwen-1-5b`, version `2.0.4`.

Free the GPU. The command below deletes the FSx model, or the S3 model if you skipped FSx:

```bash
kubectl delete inferenceendpointconfig qwen-s3 qwen-fsx -n $NAMESPACE --ignore-not-found
```

Expected: one `... deleted` line for the model that existed.

The command below writes `deepseek-js.yaml`, applies it, and waits. `spec.sageMakerEndpoint.name` makes the operator also create a SageMaker AI endpoint named `deepseek-js`, so you can invoke it with the SageMaker API.

```bash
cat > deepseek-js.yaml <<EOF
apiVersion: inference.sagemaker.aws.amazon.com/v1
kind: JumpStartModel
metadata:
  name: deepseek-js
  namespace: ${NAMESPACE}
spec:
  sageMakerEndpoint:
    name: deepseek-js
  model:
    modelHubName: SageMakerPublicHub
    modelId: deepseek-llm-r1-distill-qwen-1-5b
    modelVersion: 2.0.4
  server:
    instanceType: ${INSTANCE_TYPE}
  metrics:
    enabled: true
  maxDeployTimeInSeconds: 1800
EOF
kubectl apply -f deepseek-js.yaml
LAST=
for i in $(seq 180); do
  NOW=$(kubectl get jumpstartmodel deepseek-js -n $NAMESPACE --no-headers \
    -o custom-columns='STATE:.status.state,SAGEMAKER:.status.endpoints.sagemaker.state')
  [ "$NOW" != "$LAST" ] && echo "$(date +%T)  $NOW" && LAST=$NOW
  case "$NOW" in *Failed*|*DeploymentComplete*CreationCompleted*) break ;; esac
  sleep 10
done
```

Expected: timestamped lines with two columns, the deployment state and the SageMaker endpoint state. The loop stops when they read `DeploymentComplete` and `CreationCompleted`, on a failure, or after 30 minutes. This source takes the longest, because the operator also creates the SageMaker endpoint: allow 10 minutes or more.

JumpStart picked the serving image for you: here LMI (Large Model Inference, AWS's DJL Serving container) on port 8080, with `/ping` health checks. LMI expects an `inputs`/`parameters` payload instead of the OpenAI format.

The command below sends one request through the SageMaker endpoint and prints the answer, then prints the image JumpStart chose:

```bash
aws sagemaker-runtime invoke-endpoint --endpoint-name deepseek-js \
  --content-type application/json --cli-binary-format raw-in-base64-out --region $REGION \
  --body '{"inputs":"What is 7 times 8?","parameters":{"max_new_tokens":64}}' \
  js-response.json >/dev/null && jq -r .generated_text js-response.json

kubectl get pods -n $NAMESPACE -l app=deepseek-js \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
```

Expected: generated text (the model reasons out loud, so the 64 tokens may end mid-sentence), then an ECR image URI for the LMI container (`djl-inference`).

For reference, how `JumpStartModel` fields map to `InferenceEndpointConfig` fields:

| | `JumpStartModel` | `InferenceEndpointConfig` |
|---|---|---|
| SageMaker endpoint name | `spec.sageMakerEndpoint.name` | `spec.endpointName` |
| Instance type | `spec.server.instanceType` (one) | `spec.instanceType` or `spec.instanceTypes` (preference list) |
| Tolerations | `spec.tolerations` | `spec.kubernetes.tolerations` |
| Gated models | `model.acceptEula: true` plus the add-on's gated-model role (or `model.gatedModelDownloadRole`) | `tokenSecretRef` |
| GPU partitions (MIG) | `server.acceleratorPartitionType`, for example `mig-1g.10gb` | Through `worker.resources` |

## Cache weights and images on the node

When you scale out, a new replica usually waits on two downloads: the multi-GB serving image and the weights. `modelCacheConfig` keeps both on the node's local NVMe disk, so new replicas on that node start in seconds. You turn it on in [lab 6](06-optimization.md).

For reference; nothing to apply here. The block looks like this:

```yaml
spec:
  modelCacheConfig:
    weightsCache:
      enabled: true
      hostPath: /opt/dlami/nvme   # default; must be an NVMe-backed path on the node
    imageCache:
      enabled: true
```

The commands below list the cache resources the operator creates when caching is on:

```bash
kubectl get modelimagecache -A        # Image, State, Ready/Target nodes
kubectl get modelweightscacheconfig -A
```

Expected: `No resources found` for both, because no deployment in this lab enables caching.

> [!NOTE]
> Weights caching does nothing on instances without local NVMe at `hostPath`. `ml.g5.2xlarge` has a 450 GB local NVMe SSD. To check another instance type, run `kubectl debug node/<node> -it --image=public.ecr.aws/docker/library/busybox:stable -- df -h /host/opt/dlami/nvme`, then delete the `node-debugger-*` pod it leaves behind.

## Clean up

The commands below delete the models from this lab and free the GPU for lab 5. `tinyllama-dd` from lab 1 stays. The weights in S3 stay too, for lab 6.

```bash
kubectl delete inferenceendpointconfig qwen-hf qwen-s3 qwen-fsx -n $NAMESPACE --ignore-not-found
kubectl delete jumpstartmodel deepseek-js -n $NAMESPACE --ignore-not-found
```

Expected: `jumpstartmodel.inference.sagemaker.aws.amazon.com "deepseek-js" deleted`. The other models were already deleted, so they print nothing.
