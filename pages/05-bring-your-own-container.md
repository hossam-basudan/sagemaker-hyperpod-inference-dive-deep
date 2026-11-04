# 5. Bring your own container

In this lab you build your own serving image, push it to Amazon ECR (Elastic Container Registry, AWS's container image registry), and deploy it with the operator. You need this when a stock image isn't enough: to pin dependencies, add a custom chat template or tokenizer patch, add your own pre- and post-processing, or standardize launch flags across teams.

`worker.image` can be any image that serves HTTP. The operator doesn't care what's inside, as long as the container follows a small contract, described first.

The page has three parts:

1. [The container contract](#the-container-contract): what any image must do. For reference.
2. [Lab: build a custom vLLM image](#lab-build-a-custom-vllm-image): the steps you run.
3. [Using other serving containers](#using-other-serving-containers) and [Pod-level customization](#pod-level-customization): for reference.

## The container contract

For reference; nothing to run. Each row is something your container must do, and the field in the `InferenceEndpointConfig` (the operator's resource for one model deployment) where you tell the operator how it does it:

| Requirement | Where you declare it | Notes |
|---|---|---|
| Listen on a port | `worker.modelInvocationPort.containerPort` (required); `name` is `http` or `grpc` | Upstream vLLM uses 8000; AWS DLCs (vLLM, LMI, TGI) use 8080 |
| Serve inference on a path | `spec.invocationEndpoint` (default `invocations`) | The path the ALB and SageMaker endpoint forward to, for example `v1/chat/completions` |
| Answer health checks | `spec.loadBalancer.healthCheckPath` (default `/ping`) | ALB target health. vLLM: `/health`. LMI: `/ping` |
| Read weights from the mount | `worker.modelVolumeMount.mountPath` (default `/opt/ml/model`) | Point your server at it, for example `--model /opt/ml/model` |
| Report readiness honestly | `worker.probes` (`startupProbe`, `readinessProbe`, `livenessProbe`) | Defaults apply when omitted; set them explicitly for slow-loading models |
| Include the Hugging Face CLI (Hugging Face sources with `prefetchEnabled: true`) | The image itself | The weight-download init container runs **your `worker.image`** and calls `hf download` (or `huggingface-cli download`). vLLM images include it |
| Expose Prometheus metrics (optional) | `spec.metrics.modelMetrics.port` / `path` (defaults 8080, `/metrics`) | vLLM serves `/metrics` on its API port |

Terms in the table:

- **DLC** (AWS Deep Learning Containers): images that AWS builds and maintains for serving and training, such as vLLM, LMI, and TGI.
- **LMI** (Large Model Inference): AWS's DLC based on DJL Serving.
- **Probes**: HTTP checks Kubernetes runs against the container. The **startup probe** gives a slow server time to load before the other probes start. The **readiness probe** decides whether the pod receives traffic. The **liveness probe** restarts the container when it fails.

You control the process with `worker.command`, `worker.args`, `worker.workingDir`, and `worker.environmentVariables`.

**If you leave `worker.args` empty, the operator passes `--model <mountPath>` as the container's arguments and sets `MODEL_ID=<mountPath>`.** Your entrypoint (the program the container runs when it starts) must accept them. The entrypoint in the lab below does.

> [!WARNING]
> `worker.environmentVariables` can't be updated in place. To change one, delete and re-create the `InferenceEndpointConfig`.

The operator also adds two sidecars (helper containers in the same pod) to every model pod: `sidecar-reverse-proxy` (nginx, which emits request metrics and enforces request limits) and `otel-collector`. Your container doesn't need to know about them.

## Lab: build a custom vLLM image

You build an image that wraps upstream vLLM with your own entrypoint, push it to ECR, and deploy Qwen 2.5 1.5B with it. Run steps 1 to 3 in order.

The entrypoint:

- sets `--tensor-parallel-size` from the number of GPUs the pod actually received. Tensor parallelism splits one model across several GPUs, so the same image serves 1-, 2-, or 4-GPU deployments without changes.
- takes its configuration from environment variables instead of long `args` lists.

> [!NOTE]
> The image is about 10 GB. The workshop's Code Editor has no Docker, so AWS CodeBuild builds and pushes the image for you (about 10 minutes). `scripts/setup.sh` already created the CodeBuild project and the ECR repository.

This lab needs the second GPU free. If you didn't run the [Clean up](04-bring-your-own-model.md#clean-up) step of lab 4, run it first.

### 1. Write the image

The command below creates a `byoc-vllm` directory, moves into it, and writes two files: `entrypoint.sh` and a `Dockerfile` that builds on `vllm/vllm-openai:v0.19.1` and makes `entrypoint.sh` the entrypoint:

```bash
mkdir -p ~/hyperpod-inference-dive-deep/byoc-vllm && cd ~/hyperpod-inference-dive-deep/byoc-vllm

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

Expected: no output. Your current directory is now `byoc-vllm`, and step 2 runs from there.

### 2. Build and push to Amazon ECR

The build command tags each image with the current date and time. Use a new tag for every build: nodes cache images by tag, so re-pushing the same tag doesn't reach nodes that already pulled it.

Run only one of the options below:

- **In the workshop Code Editor**: use AWS CodeBuild.
- **On your own machine with Docker** (about 25 GB of free disk): use the Docker option, where this page shows it, instead.

<details open>
<summary><b>AWS CodeBuild (workshop Code Editor)</b></summary>

AWS CodeBuild is AWS's managed build service. The command below zips the two files, uploads them to the model bucket, and starts the build. CodeBuild runs `docker build` and `docker push` in a managed build container inside your cluster's VPC. The command waits for the build, then returns to the parent directory:

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
cd ~/hyperpod-inference-dive-deep
```

Expected: an `upload:` line, `Build ... started; it takes about 10 minutes`, and, about 10 minutes later, `Build SUCCEEDED: <your image URI>`.

If it prints `Build FAILED`, read the build log with `aws logs tail /aws/codebuild/$BUILD_PROJECT --region $REGION`.

</details>

<details>
<summary><b>Docker (your own machine)</b></summary>

The command below creates an ECR repository if needed, logs Docker in to ECR, builds the image for `linux/amd64` (the GPU nodes' architecture), pushes it, and returns to the parent directory:

```bash
export REPO=hyperpod-byoc-vllm
export IMAGE_URI=${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO}:v0.19.1-tp-auto-$(date +%Y%m%d%H%M)

aws ecr describe-repositories --repository-names $REPO --region $REGION >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name $REPO --region $REGION

aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com

docker build --platform linux/amd64 -t $IMAGE_URI .
docker push $IMAGE_URI
cd ~/hyperpod-inference-dive-deep
```

Expected: `Login Succeeded`, the build output, and a push that ends with a `digest: sha256:...` line. The first build and push of the 10 GB image can take 15 minutes or more, depending on your network.

</details>


The HyperPod nodes pull the image with the instance group's execution role. That role needs `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, and `ecr:GetDownloadUrlForLayer` on the repository. If pods later show `ErrImagePull` with `403 Forbidden`, check that role first.

### 3. Deploy it

The command below writes `qwen-byoc.yaml` with your image, applies it, and waits for the deployment. Before you run it, note what the YAML sets:

- **`image: ${IMAGE_URI}`**: the image you built in step 2.
- **No `worker.args`**: the operator passes `--model /opt/ml/model`, and the entrypoint picks it up.
- **`environmentVariables`**: the entrypoint reads `SERVED_MODEL_NAME` and `MAX_MODEL_LEN` instead of command-line flags.
- **`nvidia.com/gpu: "1"`**: one GPU, the single A10G on an `ml.g5.2xlarge`. The entrypoint counts the GPUs it receives and sets tensor parallelism to match, so here it selects 1. On a multi-GPU instance you would change only this number, not the image. The workshop nodes have one GPU each, so you'll see tensor parallelism 1.
- **The probes**: the `startupProbe` allows up to 10 minutes (60 checks, 10 seconds apart) for the weights to load before Kubernetes restarts the container. After that, the `readinessProbe` and `livenessProbe` check `/health`.
- **`endpointName: qwen-byoc`**: the operator also creates a SageMaker AI endpoint, so you can invoke the model with the SageMaker API.

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
LAST=
for i in $(seq 120); do
  NOW=$(kubectl get inferenceendpointconfig qwen-byoc -n $NAMESPACE --no-headers \
    -o custom-columns='STATE:.status.state,SAGEMAKER:.status.endpoints.sagemaker.state')
  [ "$NOW" != "$LAST" ] && echo "$(date +%T)  $NOW" && LAST=$NOW
  case "$NOW" in *Failed*|*DeploymentComplete*CreationCompleted*) break ;; esac
  sleep 10
done
```

Expected: `qwen-byoc created`, then timestamped lines with two columns, the deployment state and the SageMaker endpoint state. The loop stops when they read `DeploymentComplete` and `CreationCompleted`, on a failure, or after 20 minutes. The node pulls your 10 GB image first, so allow several minutes.

The command below prints the line the entrypoint logged at startup, to confirm what it detected:

```bash
POD=$(kubectl get pods -n $NAMESPACE -l app=qwen-byoc -o jsonpath='{.items[0].metadata.name}')
kubectl logs $POD -n $NAMESPACE --all-containers | grep '\[entrypoint\]'
```

Expected: `[entrypoint] model=/opt/ml/model gpus=1 tp=1 port=8000 name=qwen`

The command below sends one chat request through the SageMaker endpoint and prints the answer. `model` matches `SERVED_MODEL_NAME`:

```bash
aws sagemaker-runtime invoke-endpoint --endpoint-name qwen-byoc \
  --content-type application/json --cli-binary-format raw-in-base64-out --region $REGION \
  --body '{"model":"qwen","messages":[{"role":"user","content":"Write a haiku about Kubernetes."}],"max_tokens":64}' \
  response.json >/dev/null && jq -r '.choices[0].message.content' response.json
```

Expected: a short haiku about Kubernetes. The wording varies from run to run.

## Using other serving containers

For reference; nothing to run. The same contract applies to any runtime. To use another image, set four values to match it: the port, the invocation path, the health check path, and the mount path. The tabs below show these values for three common choices.

<details open>
<summary><b>AWS vLLM DLC</b></summary>

The AWS-built vLLM image listens on 8080. Replace `<region>` and `<tag>` with your Region and an image tag.

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

LMI serves on `invocations` with `/ping` health checks, and reads its configuration from environment variables.

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

For reference; nothing to run. `spec.kubernetes` passes standard Kubernetes settings through to the pods the operator generates:

| Field | Use it for |
|---|---|
| `tolerations` | Schedule onto tainted GPU nodes |
| `initContainers`, `volumes` | Extra setup, such as downloading LoRA adapters or mounting a config map |
| `serviceAccountName` | AWS credentials for your container through IRSA (IAM roles for service accounts). Requires `enableCustomServiceAccounts: true` in the add-on configuration |
| `podTemplateAnnotations` | Your own annotations. Keys under `inference.sagemaker.aws.amazon.com` are reserved |
| `schedulerName` | A custom scheduler |

## Clean up

The command below deletes the deployment and frees the GPU for the next lab:

```bash
kubectl delete inferenceendpointconfig qwen-byoc -n $NAMESPACE
```

Expected: `inferenceendpointconfig.inference.sagemaker.aws.amazon.com "qwen-byoc" deleted`. Your image stays in ECR.
