# 3. Bring your own container

`worker.image` can be any image that serves HTTP. The operator doesn't care what's inside, as long as the container honors a small contract.

## The container contract

| Requirement | Where you declare it | Notes |
|---|---|---|
| Listen on a port | `worker.modelInvocationPort.containerPort` (required); `name` is `http` or `grpc` | Upstream vLLM uses 8000; AWS DLCs (vLLM, LMI, TGI) use 8080 |
| Serve inference on a path | `spec.invocationEndpoint` (default `invocations`) | The path the ALB and SageMaker endpoint forward to, for example `v1/chat/completions` |
| Answer health checks | `spec.loadBalancer.healthCheckPath` (default `/ping`) | ALB target health. vLLM: `/health`. LMI: `/ping` |
| Read weights from the mount | `worker.modelVolumeMount.mountPath` (default `/opt/ml/model`) | Point your server at it, for example `--model /opt/ml/model` |
| Report readiness honestly | `worker.probes` (`startupProbe`, `readinessProbe`, `livenessProbe`) | Defaults apply when omitted; set them explicitly for slow-loading models |
| Include the Hugging Face CLI (Hugging Face sources with `prefetchEnabled: true`) | The image itself | The weight-download init container runs **your `worker.image`** and calls `hf download` (or `huggingface-cli download`). vLLM images include it |
| Expose Prometheus metrics (optional) | `spec.metrics.modelMetrics.port` / `path` (defaults 8080, `/metrics`) | vLLM serves `/metrics` on its API port |

You control the process with `worker.command`, `worker.args`, `worker.workingDir`, and `worker.environmentVariables`. **If you leave `worker.args` empty, the operator passes `--model <mountPath>` as the container's arguments and sets `MODEL_ID=<mountPath>`**, so your entrypoint must accept them (the lab below does).

> [!WARNING]
> `worker.environmentVariables` can't be updated in place. To change one, delete and re-create the `InferenceEndpointConfig`.

The operator adds two sidecars to every model pod: `sidecar-reverse-proxy` (nginx, which emits request metrics and enforces request limits) and `otel-collector`. Your container doesn't need to know about them.

## Lab: build a custom vLLM image

Why build your own image? Pin dependencies, bake in a custom chat template or tokenizer patch, add your own pre/post-processing, or standardize launch flags across teams. This image wraps upstream vLLM with an entrypoint that:

- sizes `--tensor-parallel-size` from the GPUs the pod actually received, so the same image serves 1-, 2-, or 4-GPU deployments
- takes its configuration from environment variables instead of long `args` lists

> [!NOTE]
> The image is about 10 GB. In the workshop's Code Editor, which has no Docker, AWS CodeBuild builds and pushes it (about 10 minutes); `scripts/setup.sh` created the project. On your own machine you can use Docker instead, with about 25 GB of free disk.

### 1. Write the image

```bash
mkdir -p byoc-vllm && cd byoc-vllm

cat > entrypoint.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# When worker.args is empty, the operator sets MODEL_ID and passes "--model <mountPath>"
MODEL_DIR="${MODEL_DIR:-${MODEL_ID:-/opt/ml/model}}"
PORT="${PORT:-8000}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-model}"

# Use every GPU this pod was allocated unless TP_SIZE is set explicitly
GPUS=$( (nvidia-smi -L 2>/dev/null || true) | wc -l)
TP_SIZE="${TP_SIZE:-$(( GPUS > 0 ? GPUS : 1 ))}"

ARGS=(--host 0.0.0.0 --port "$PORT"
      --served-model-name "$SERVED_MODEL_NAME"
      --tensor-parallel-size "$TP_SIZE")
[[ -n "${MAX_MODEL_LEN:-}" ]] && ARGS+=(--max-model-len "$MAX_MODEL_LEN")

# Take the model path from an injected --model flag; pass every other argument through
PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL_DIR="$2"; shift 2 ;;
    --model=*) MODEL_DIR="${1#*=}"; shift ;;
    *) PASSTHROUGH+=("$1"); shift ;;
  esac
done

echo "[entrypoint] model=$MODEL_DIR gpus=$GPUS tp=$TP_SIZE port=$PORT name=$SERVED_MODEL_NAME"
# EXTRA_ARGS is split on whitespace on purpose
exec vllm serve "$MODEL_DIR" "${ARGS[@]}" ${EXTRA_ARGS:-} "${PASSTHROUGH[@]}"
EOF

cat > Dockerfile <<'EOF'
FROM vllm/vllm-openai:v0.19.1

# --chmod sets the mode without a RUN step, so building on an arm64 laptop needs no emulation
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENV MODEL_DIR=/opt/ml/model \
    PORT=8000
EXPOSE 8000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
EOF
```

### 2. Build and push to Amazon ECR

Use a new tag for every build: nodes cache images by tag, so re-pushing a tag doesn't reach nodes that already pulled it.

<details open>
<summary><b>AWS CodeBuild (workshop Code Editor)</b></summary>

CodeBuild reads the two files from the model bucket, runs `docker build` and `docker push` in a managed build container, and runs inside your cluster's VPC:

```bash
export IMAGE_URI=${ECR_REPOSITORY_URL}:v0.19.1-tp-auto-$(date +%Y%m%d%H%M)

python3 -m zipfile -c ../byoc-vllm.zip Dockerfile entrypoint.sh
aws s3 cp ../byoc-vllm.zip s3://$MODEL_BUCKET/codebuild/$BUILD_PROJECT.zip
BUILD_ID=$(aws codebuild start-build --project-name $BUILD_PROJECT --region $REGION \
  --environment-variables-override name=IMAGE_URI,value=$IMAGE_URI --query build.id --output text)
echo "Build $BUILD_ID started; it takes about 10 minutes"
while STATUS=$(aws codebuild batch-get-builds --ids $BUILD_ID --region $REGION --query 'builds[0].buildStatus' --output text) \
      && [ "$STATUS" = IN_PROGRESS ]; do sleep 30; done
echo "Build $STATUS: $IMAGE_URI"
cd ..
```

If the build fails, read its log with `aws logs tail /aws/codebuild/$BUILD_PROJECT --region $REGION`.

</details>

<details>
<summary><b>Docker</b></summary>

```bash
export REPO=hyperpod-byoc-vllm
export IMAGE_URI=${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO}:v0.19.1-tp-auto-$(date +%Y%m%d%H%M)

aws ecr describe-repositories --repository-names $REPO --region $REGION >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name $REPO --region $REGION

aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com

docker build --platform linux/amd64 -t $IMAGE_URI .
docker push $IMAGE_URI
cd ..
```

</details>


The HyperPod nodes pull the image with the instance group's execution role. That role needs `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, and `ecr:GetDownloadUrlForLayer` on the repository. If pods show `ErrImagePull` with `403 Forbidden`, check that role first.

### 3. Deploy it

This deployment gets the single A10G on an `ml.g5.2xlarge`, so the entrypoint selects tensor parallel 1. Deploy the same image unchanged on a 4-GPU `ml.g5.12xlarge` with `nvidia.com/gpu: "4"` and it selects tensor parallel 4. It also sets explicit probes: a `startupProbe` that allows up to 10 minutes for weights to load before Kubernetes starts restarting the container.

```bash
cat > qwen-byoc.yaml <<EOF
apiVersion: inference.sagemaker.aws.amazon.com/v1
kind: InferenceEndpointConfig
metadata:
  name: qwen-byoc
  namespace: ${NAMESPACE}
spec:
  modelName: qwen-byoc
  endpointName: qwen-byoc
  instanceType: ${INSTANCE_TYPE}
  invocationEndpoint: v1/chat/completions
  modelSourceConfig:
    modelSourceType: huggingface
    prefetchEnabled: true
    huggingFaceModel:
      modelId: Qwen/Qwen2.5-1.5B-Instruct
  loadBalancer:
    healthCheckPath: /health
    idleTimeoutSeconds: 300
  metrics:
    enabled: true
    modelMetrics:
      port: 8000
      path: /metrics
  worker:
    image: ${IMAGE_URI}
    modelInvocationPort:
      containerPort: 8000
      name: http
    modelVolumeMount:
      name: model-weights
      mountPath: /opt/ml/model
    resources:
      requests: {nvidia.com/gpu: "1", cpu: "4", memory: 16Gi}
      limits:   {nvidia.com/gpu: "1", cpu: "4", memory: 16Gi}
    environmentVariables:
      - name: SERVED_MODEL_NAME
        value: qwen
      - name: MAX_MODEL_LEN
        value: "8192"
    probes:
      startupProbe:
        httpGet: {path: /health, port: 8000}
        periodSeconds: 10
        failureThreshold: 60
      readinessProbe:
        httpGet: {path: /health, port: 8000}
        periodSeconds: 10
        failureThreshold: 3
      livenessProbe:
        httpGet: {path: /health, port: 8000}
        periodSeconds: 30
        failureThreshold: 3
EOF
kubectl apply -f qwen-byoc.yaml
```

Confirm what the entrypoint detected:

```bash
POD=$(kubectl get pods -n $NAMESPACE -l app=qwen-byoc -o jsonpath='{.items[0].metadata.name}')
kubectl logs $POD -n $NAMESPACE --all-containers | grep '\[entrypoint\]'
```

Expected: `[entrypoint] model=/opt/ml/model gpus=1 tp=1 port=8000 name=qwen`

Invoke it through SageMaker once `kubectl get inferenceendpointconfig qwen-byoc -n $NAMESPACE` shows `DeploymentComplete`:

```bash
aws sagemaker-runtime invoke-endpoint --endpoint-name qwen-byoc \
  --content-type application/json --cli-binary-format raw-in-base64-out --region $REGION \
  --body '{"model":"qwen","messages":[{"role":"user","content":"Write a haiku about Kubernetes."}],"max_tokens":64}' \
  response.json >/dev/null && jq -r '.choices[0].message.content' response.json
```

## Using other serving containers

The same contract applies to any runtime. Match the four values (port, invocation path, health path, and mount path) to the image:

<details open>
<summary><b>AWS vLLM DLC</b></summary>

```yaml
  invocationEndpoint: v1/chat/completions
  loadBalancer:
    healthCheckPath: /health
  worker:
    image: 763104351884.dkr.ecr.<region>.amazonaws.com/vllm:<tag>
    modelInvocationPort:
      containerPort: 8080
      name: http
```

</details>

<details>
<summary><b>LMI (DJL Serving)</b></summary>

```yaml
  invocationEndpoint: invocations
  loadBalancer:
    healthCheckPath: /ping
  metrics:
    modelMetrics:
      port: 8080
      path: /server/metrics
  worker:
    image: 763104351884.dkr.ecr.us-west-2.amazonaws.com/djl-inference:0.32.0-lmi14.0.0-cu124
    modelInvocationPort:
      containerPort: 8080
      name: http
    environmentVariables:
      - name: HF_MODEL_ID
        value: /opt/ml/model
      - name: OPTION_ROLLING_BATCH
        value: vllm
```

</details>

<details>
<summary><b>Your own server</b></summary>

Any HTTP server works, for example FastAPI with your own pre- and post-processing. Make sure it:

1. binds `0.0.0.0` on the declared `containerPort`
2. answers `GET <healthCheckPath>` with `200` only once the model is loaded
3. serves `POST /<invocationEndpoint>`
4. loads weights from `/opt/ml/model`

</details>


## Pod-level customization

`spec.kubernetes` passes standard Kubernetes settings through to the generated pods:

| Field | Use it for |
|---|---|
| `tolerations` | Schedule onto tainted GPU nodes |
| `initContainers`, `volumes` | Extra setup, such as downloading LoRA adapters or mounting a config map |
| `serviceAccountName` | AWS credentials for your container through IRSA. Requires `enableCustomServiceAccounts: true` in the add-on configuration |
| `podTemplateAnnotations` | Your own annotations. Keys under `inference.sagemaker.aws.amazon.com` are reserved |
| `schedulerName` | A custom scheduler |

## Clean up

```bash
kubectl delete inferenceendpointconfig qwen-byoc -n $NAMESPACE
```
