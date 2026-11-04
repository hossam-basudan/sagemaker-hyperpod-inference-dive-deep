# 4. Bring your own model

`spec.modelSourceConfig` tells the operator where the weights live. The model server always sees them at `worker.modelVolumeMount.mountPath` (default `/opt/ml/model`). Only how they get there changes.

| `modelSourceType` | Weights come from | Good for | Cold-start cost |
|---|---|---|---|
| `huggingface` | Hugging Face Hub, downloaded by an init container (`prefetchEnabled: true`) or by the runtime itself | Fast experiments, public and gated models | Download on every new pod; needs internet egress |
| `s3` | Your S3 bucket, through the Mountpoint for S3 CSI driver | Fine-tuned checkpoints, air-gapped clusters | Streamed from S3; `prefetchEnabled` copies first |
| `fsx` | FSx for Lustre, through the FSx CSI driver | Large models, many replicas, checkpoints already on FSx from training | Lowest; shared file system |
| `kubernetesVolume` | Any Kubernetes volume you define | Custom storage | Depends on the volume |
| `JumpStartModel` (separate kind) | SageMaker JumpStart public hub | Curated models with tested images | Managed by the operator |

> [!NOTE]
> With two `ml.g5.2xlarge` nodes, `tinyllama-dd` from module 1 holds one GPU and each lab below deploys one model onto the other. Each lab starts by deleting the previous lab's model.

Explore the fields on your cluster:

```bash
kubectl explain inferenceendpointconfig.spec.modelSourceConfig --recursive
```

## Hugging Face: pin the revision

`modelId` alone serves whatever is on `main` today, so a redeploy next week can pull different weights. Pin `commitSHA` (40-character hex) for reproducible deployments:

```bash
export HF_MODEL=Qwen/Qwen2.5-1.5B-Instruct
export HF_SHA=$(curl -s https://huggingface.co/api/models/$HF_MODEL | jq -r .sha)
echo $HF_SHA
```

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

There is no `endpointName`, so this deployment gets an ALB but no SageMaker AI endpoint. That's fine for internal callers.

Watch the init container download the weights. The loop prints the pod's status each time it changes and stops when the deployment is complete (or after 20 minutes):

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

Test the model. Without a SageMaker endpoint, call the pod directly: forward its port to the Code Editor and send an OpenAI-style request. `model` is the `--served-model-name` from the deployment:

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

**`prefetchEnabled: true` vs `false`**: with `true`, an init container downloads the weights before the server starts, so a failed download fails fast and visibly (`Init:CrashLoopBackOff`). With `false`, the runtime (vLLM, TGI, SGLang) downloads the model itself at startup.

### Hugging Face download errors

| Init container error | Fix |
|---|---|
| Connection timeout | No egress to `*.huggingface.co` and `*.hf.co`. Add a NAT gateway, or use S3/FSx instead |
| `Repository Not Found` | `modelId` must be `org/model` |
| `401 Unauthorized` | The model is gated (see below) |

After you fix the cause, recreate the pod with `kubectl delete pod -l app=<name> -n $NAMESPACE`.

### Gated models (reference only)

Every lab in this section uses **ungated** models (TinyLlama, Qwen 2.5, and a JumpStart DeepSeek distill), so you don't need a Hugging Face account or token. To serve a gated repository (for example Llama), accept its license on huggingface.co, store a token as a Kubernetes secret in the endpoint's namespace, and reference it:

```bash
kubectl create secret generic hf-token-secret \
  --from-literal=token=<your-hf-token> -n $NAMESPACE
```

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
> The operator injects the token as `HF_TOKEN` into the **init container only**. Keep `prefetchEnabled: true` for gated models, because the model server never sees the token and can't download them itself.

## Amazon S3: serve your own checkpoint

This is the usual path for a model you fine-tuned on HyperPod. The weights go to S3 in Hugging Face layout (`config.json`, `*.safetensors`, tokenizer files), and `modelLocation` is the prefix inside the bucket.

Stage a model in S3. Here we copy the Qwen model to stand in for your checkpoint:

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

The **Mountpoint for S3 CSI driver's IAM role** reads the bucket. The operator's execution role does not. Find that role and make sure it allows `s3:ListBucket` on the bucket and `s3:GetObject` on its objects:

```bash
aws eks describe-addon --cluster-name $EKS_CLUSTER_NAME \
  --addon-name aws-mountpoint-s3-csi-driver --region $REGION \
  --query addon.serviceAccountRoleArn --output text
```

Free the GPU used by the Hugging Face lab, then deploy from S3:

```bash
kubectl delete inferenceendpointconfig qwen-hf -n $NAMESPACE --ignore-not-found
```

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

`bucketName` is the bare bucket name, without `s3://`.

Wait for the deployment. The init container copies the weights from S3 first, so this takes a few minutes:

```bash
LAST=
for i in $(seq 120); do
  NOW=$(kubectl get inferenceendpointconfig qwen-s3 -n $NAMESPACE -o jsonpath='{.status.state}')
  [ "$NOW" != "$LAST" ] && echo "$(date +%T)  $NOW" && LAST=$NOW
  case "$NOW" in DeploymentComplete|DeploymentFailed) break ;; esac
  sleep 10
done
```

Test the model the same way:

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

With `prefetchEnabled: true`, the operator mounts the bucket through the S3 CSI driver as a PersistentVolumeClaim (`inference-s3-pvc-<name>-inf`), and an init container (`prefetch-<name>-inf`) copies the weights to the pod's local disk before vLLM starts. Unlike the Hugging Face downloader, this init container uses its own Amazon Linux image, not your `worker.image`.

## FSx for Lustre

If your training jobs already write checkpoints to FSx for Lustre, serve them in place. The workshop cluster mounts its file system through the `fsx-pv` volume and the `fsx-claim` claim in the `default` namespace, the same ones the training labs use. Check that your cluster has them:

```bash
if kubectl get pv fsx-pv >/dev/null 2>&1 && kubectl get pvc fsx-claim -n $NAMESPACE >/dev/null 2>&1; then
  echo "FSx volume found: run this lab"
else
  echo "No FSx volume (fsx-pv, fsx-claim) on this cluster: skip to SageMaker JumpStart below"
fi
```

If the check says to skip, go to "SageMaker JumpStart". It frees the GPU from the S3 lab itself.

Free the GPU used by the S3 lab first:

```bash
kubectl delete inferenceendpointconfig qwen-s3 -n $NAMESPACE --ignore-not-found
```

Put a model on the file system. Here a short-lived pod downloads Qwen into `models/qwen2.5-1.5b` to stand in for your checkpoint (under a minute: the download stays inside AWS):

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

On another cluster, find the file system ID with:

```bash
aws fsx describe-file-systems --region $REGION \
  --query 'FileSystems[?FileSystemType==`LUSTRE`].[FileSystemId,DNSName,LustreConfiguration.MountName]' --output table
```

Deploy from FSx. Only the source block differs from the S3 lab, and `modelLocation` is the path inside the file system:

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

It reaches `DeploymentComplete` in about 2 minutes, faster than the other sources. There's no init container: the operator mounts the file system as a volume (`inference-fsx-pvc-qwen-fsx`), and vLLM reads the weights in place. Every replica reads the same shared copy, which is why FSx is the fastest way to scale out a large model.

Test the model:

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

## SageMaker JumpStart

`JumpStartModel` is a separate kind. You name a model from the JumpStart hub, and the operator picks the tested image, weights, and server settings. There's no `worker` block.

```bash
aws sagemaker list-hub-contents --hub-name SageMakerPublicHub --hub-content-type Model \
  --name-contains deepseek --region $REGION \
  --query 'HubContentSummaries[].[HubContentName,HubContentVersion]' --output table
```

Free the GPU used by the FSx lab (or the S3 lab, if you skipped FSx) first:

```bash
kubectl delete inferenceendpointconfig qwen-s3 qwen-fsx -n $NAMESPACE --ignore-not-found
```

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

The loop prints each state change and stops at `DeploymentComplete` / `CreationCompleted` (or a failure, or after 30 minutes). Then invoke it. JumpStart picked the serving image for you (here LMI on port 8080, with `/ping` health checks), and LMI expects the `inputs`/`parameters` payload:

```bash
aws sagemaker-runtime invoke-endpoint --endpoint-name deepseek-js \
  --content-type application/json --cli-binary-format raw-in-base64-out --region $REGION \
  --body '{"inputs":"What is 7 times 8?","parameters":{"max_new_tokens":64}}' \
  js-response.json >/dev/null && jq -r .generated_text js-response.json

kubectl get pods -n $NAMESPACE -l app=deepseek-js \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
```

Differences from `InferenceEndpointConfig`:

| | `JumpStartModel` | `InferenceEndpointConfig` |
|---|---|---|
| SageMaker endpoint name | `spec.sageMakerEndpoint.name` | `spec.endpointName` |
| Instance type | `spec.server.instanceType` (one) | `spec.instanceType` or `spec.instanceTypes` (preference list) |
| Tolerations | `spec.tolerations` | `spec.kubernetes.tolerations` |
| Gated models | `model.acceptEula: true` plus the add-on's gated-model role (or `model.gatedModelDownloadRole`) | `tokenSecretRef` |
| GPU partitions (MIG) | `server.acceleratorPartitionType`, for example `mig-1g.10gb` | Through `worker.resources` |

## Cache weights and images on the node

Scale-out is usually limited by two downloads: the multi-GB serving image and the weights. `modelCacheConfig` keeps both on node-local NVMe so new replicas on that node start in seconds:

```yaml
spec:
  modelCacheConfig:
    weightsCache:
      enabled: true
      hostPath: /opt/dlami/nvme   # default; must be an NVMe-backed path on the node
    imageCache:
      enabled: true
```

Check the cache status:

```bash
kubectl get modelimagecache -A        # Image, State, Ready/Target nodes
kubectl get modelweightscacheconfig -A
```

> [!NOTE]
> Weights caching does nothing on instances without local NVMe at `hostPath`. `ml.g5.2xlarge` has a 450 GB local NVMe SSD; check yours with `kubectl debug node/<node> -it --image=public.ecr.aws/docker/library/busybox:stable -- df -h /host/opt/dlami/nvme`, then delete the `node-debugger-*` pod it leaves behind.

## Clean up

```bash
kubectl delete inferenceendpointconfig qwen-hf qwen-s3 qwen-fsx -n $NAMESPACE --ignore-not-found
kubectl delete jumpstartmodel deepseek-js -n $NAMESPACE --ignore-not-found
```
