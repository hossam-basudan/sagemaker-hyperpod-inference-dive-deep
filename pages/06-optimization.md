# 6. Optimize: tiered KV cache, routing, and model caching

In this lab you deploy one endpoint with three inference operator features turned on, then measure what each one does. They matter because a plain deployment wastes work in three places:

- It recomputes every prompt from scratch unless the exact prefix is still in GPU memory.
- It sends each request to whichever replica the load balancer picks, so a replica that already processed a prompt may never see its follow-up.
- Every new pod reads the weights from S3 and pulls a 9 GB image before it can serve.

The three features are all set on the same `InferenceEndpointConfig`:

- **Tiered KV cache** (`kvCacheSpec`). When vLLM processes a prompt, it computes key and value tensors for every token. These are the **KV cache**. vLLM reuses them for a later prompt that starts with the same tokens (**prefix caching**), but only while they stay in GPU memory. The operator adds [LMCache](https://docs.lmcache.ai/), a KV cache library, behind vLLM so that KV blocks are also kept outside the GPU, in two tiers:
  - **L1** is the model server's own CPU memory. It's fast, but it's gone when the pod restarts.
  - **L2** is a cache service that runs on every node, outside the pod: either SageMaker HyperPod **managed tiered storage** or a Redis cluster you provide.

  A request whose prefix is in L1 or L2 copies the tensors back instead of recomputing them.
- **Intelligent routing** (`intelligentRoutingSpec`). The operator puts a router in front of the replicas. With the `prefixaware` strategy (**prefix-aware routing**), requests that share a prompt prefix go to the replica that already holds that prefix in its cache.
- **Model caching** (`modelCacheConfig`). Before the pods start, the operator pre-pulls the serving image onto the GPU nodes (the **image cache**, `imageCache`) and copies the model weights to each node's local NVMe disk (the **weights cache**, `weightsCache`). New replicas skip the image pull and the S3 read.

What you'll do:

1. Check that the cluster has room (Step 1).
2. Turn on the cluster's tiered storage (Step 2).
3. Deploy the optimized endpoint and watch the caches warm (Steps 3 and 4).
4. Follow a request through the router (Step 5).
5. Measure the L1 cache with a workload that revisits long prompts (Step 6).
6. See how the router keeps each prefix on one replica (Step 7).
7. Show that a prefix in L2 survives a restart of the model server (Step 8).

Run the steps in order: each one builds on the previous one.

> [!NOTE]
> Budget about 40 minutes, most of it waiting for the caches and the endpoint. This lab needs both GPUs, the model weights you staged in S3 in lab 4, and free pod slots: up to four more pods on each GPU node (the model, the tiered storage daemon, the image cache, and the router) and three on the CPU node. Step 1 checks all of this.

## Step 1: Set your environment

First, set the variables the rest of the lab uses and confirm the prerequisites.

The commands below set the endpoint name, the model location, the serving image, and the CPU and memory for your instance type. They count the GPU nodes, check that the weights from lab 4 are in S3, and list any models still deployed:

```bash
export ENDPOINT_NAME=qwen-opt
export MODEL_PREFIX=qwen2.5-1.5b
export VLLM_IMAGE=763104351884.dkr.ecr.${REGION}.amazonaws.com/vllm:0.31.0-gpu-py312-cu130-ubuntu24.04-sagemaker
case "$INSTANCE_TYPE" in
  ml.g5.xlarge)  export MODEL_CPU=2 MODEL_MEMORY=8Gi ;;
  ml.g5.2xlarge) export MODEL_CPU=4 MODEL_MEMORY=16Gi ;;
  *)             export MODEL_CPU=8 MODEL_MEMORY=32Gi ;;
esac
export REPLICAS=$(kubectl get nodes -l node.kubernetes.io/instance-type="$INSTANCE_TYPE" --no-headers | wc -l | tr -d ' ')
echo "$INSTANCE_TYPE cpu=$MODEL_CPU memory=$MODEL_MEMORY replicas=$REPLICAS"

aws s3 ls s3://$MODEL_BUCKET/$MODEL_PREFIX/config.json --region $REGION >/dev/null \
  && echo "weights staged" || echo "Stage the weights first: lab 4, Amazon S3 lab"
kubectl get inferenceendpointconfig,jumpstartmodel -A
```

Expected:

- `ml.g5.2xlarge cpu=4 memory=16Gi replicas=2`. `REPLICAS` is the number of GPU nodes: the lab runs one replica per GPU. With one GPU node the lab still works, but in Step 7 the router has only one replica to choose from.
- `weights staged`. If you see `Stage the weights first`, run the Amazon S3 part of [lab 4](04-bring-your-own-model.md) first.
- `No resources found` from the last command. If it lists deployments left by earlier labs, delete them with the first command under "If a node shows NOT ENOUGH" below, even if every node shows `OK`. Both GPUs must be free.

### Check the pod slots

HyperPod limits how many pods each node can run: 14 on an `ml.g5.2xlarge`, 29 on an `ml.c5.4xlarge`. The command below counts the pods on each node and compares the free slots with what this lab needs (4 on a GPU node, 3 on the CPU node):

```bash
for n in $(kubectl get nodes -o name | cut -d/ -f2); do
  cap=$(kubectl get node $n -o jsonpath='{.status.allocatable.pods}')
  pods=$(kubectl get pods -A --field-selector spec.nodeName=$n,status.phase!=Succeeded,status.phase!=Failed --no-headers)
  used=$(echo "$pods" | grep -c .)
  gpu=$(kubectl get node $n -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
  need=$([ -n "$gpu" ] && echo 4 || echo 3)
  echo "$n $([ -n "$gpu" ] && echo GPU || echo CPU): $used of $cap pods, $((cap - used)) free, needs $need: $([ $((cap - used)) -ge $need ] && echo OK || echo 'NOT ENOUGH')"
  if [ $((cap - used)) -lt $need ]; then   # show what fills the node, by namespace
    echo "$pods" | awk '{print $1}' | sort | uniq -c | sort -rn | sed 's/^/    /'
  fi
done
```

Expected: one line per node, each ending in `OK`, for example `hyperpod-i-0abc... GPU: 9 of 14 pods, 5 free, needs 4: OK`. If every node shows `OK`, go to Step 2.

### If a node shows NOT ENOUGH

Under a `NOT ENOUGH` line, the check lists the namespaces of the pods on that node, with the number of pods in each. About 7 pods per node in `kube-system` are system DaemonSets (one pod per node, always present); leave them. Find the other namespaces in the table and run the matching fix:

| Namespace in the list | What it is | Fix |
|---|---|---|
| `default` | Models left by earlier labs, including `tinyllama-dd` | Delete them (first command below) |
| `hyperpod-observability` | The optional observability add-on: 3 to 6 pods per node. Only labs 2 and 3 use it | Remove it (second command below). This also deletes the Prometheus workspace and its metrics |
| `hyperpod-inference-system`, other controllers | Controllers that can run on the CPU node | Rerun setup (third command below), which moves them there |

Run only the fixes you need. Each command is safe to run when there's nothing to remove.

Fix 1. Delete the models left by earlier labs:

```bash
kubectl delete inferenceendpointconfig tinyllama-dd qwen-hf qwen-s3 qwen-fsx qwen-byoc qwen-opt -n $NAMESPACE --ignore-not-found
kubectl delete jumpstartmodel deepseek-js -n $NAMESPACE --ignore-not-found
```

Expected: a `deleted` line for each model that existed, nothing for the others.

Fix 2. Remove the observability add-on (takes a few minutes):

```bash
~/hyperpod-inference-dive-deep/scripts/observability.sh --remove -y
```

Fix 3. Rerun setup to move the controllers to the CPU node (takes a few minutes):

```bash
~/hyperpod-inference-dive-deep/scripts/setup.sh -y
```

Then run the pod slot check again. Repeat until every node shows `OK`. If GPU nodes still show other models or training jobs (for example from lab 7 or the base workshop), run `~/hyperpod-inference-dive-deep/scripts/reset-gpus.sh -y`, which frees both GPU nodes.

## Step 2: Turn on the cluster's tiered storage

The L2 tier needs a cache service on each node. HyperPod provides one: **managed tiered storage**, a memory-management daemon that HyperPod also uses for in-memory training checkpoints. It's a cluster setting, off by default, and you set what share of each node's memory it reserves.

The command below turns it on with 20% of each node's memory (the minimum), then shows the cluster's setting:

```bash
aws sagemaker update-cluster --cluster-name "$HYPERPOD_CLUSTER_NAME" --region $REGION \
  --tiered-storage-config Mode=Enable,InstanceMemoryAllocationPercentage=20 >/dev/null && echo "update requested"
aws sagemaker describe-cluster --cluster-name "$HYPERPOD_CLUSTER_NAME" --region $REGION \
  --query TieredStorageConfig --output table
```

Expected: `update requested`, then a table with `Mode` set to `Enable` and `InstanceMemoryAllocationPercentage` set to `20`. The update completes in seconds.

Within about a minute, HyperPod starts the daemon, called `ai-toolkit`, on every node. The command below lists the daemon pods:

```bash
kubectl get pods -n aws-hyperpod -o wide | grep -E 'NAME|ai-toolkit'
```

Expected: one `ai-toolkit` pod per node, `1/1 Running`. If some are missing or not yet running, wait a minute and run the command again. A restart or two in the first minute is normal while the daemons find each other.

How the model pods use the daemon (for reference; nothing to run):

- Each `ai-toolkit` pod uses the host network and listens on port 9200 of its node.
- A model pod reaches the daemon on its own node at that port and shares a memory segment with it.
- The daemon reserves the 20% (about 6.4 GiB on an `ml.g5.2xlarge`). In this configuration, 1 GiB of it holds KV cache.

## Step 3: Apply the optimized InferenceEndpointConfig

Now deploy the endpoint with all three features. Intelligent routing, KV caching, and model caching apply only when a deployment is created; you can't add them to a running one.

The command below prints the time (you use it to measure how long the deployment takes) and applies the `InferenceEndpointConfig`. It starts at zero replicas so the caches can warm first; you scale up in Step 4:

```bash
date
kubectl apply -f - <<EOF
apiVersion: inference.sagemaker.aws.amazon.com/v1
kind: InferenceEndpointConfig
metadata:
  name: ${ENDPOINT_NAME}
  namespace: ${NAMESPACE}
spec:
  modelName: ${ENDPOINT_NAME}
  endpointName: ${ENDPOINT_NAME}
  instanceType: ${INSTANCE_TYPE}
  invocationEndpoint: v1/chat/completions   # the router needs one of vLLM's own routes
  replicas: 0                               # warm the caches first; you scale up in Step 4
  modelSourceConfig:
    modelSourceType: s3
    s3Storage:
      bucketName: ${MODEL_BUCKET}
      region: ${REGION}
    modelLocation: ${MODEL_PREFIX}          # no prefetchEnabled: see the table below
  modelCacheConfig:
    imageCache:
      enabled: true                         # pre-pull the vLLM image onto the GPU nodes
    weightsCache:
      enabled: true                         # copy the weights to local NVMe
      hostPath: /opt/dlami/nvme
  kvCacheSpec:
    enableL1Cache: true                     # LMCache keeps KV blocks in the pod's CPU memory
    enableL2Cache: true                     # ...and in the node's tiered storage
    l2CacheSpec:
      l2CacheBackend: tieredstorage
  intelligentRoutingSpec:
    enabled: true
    routingStrategy: prefixaware            # same prompt prefix, same replica
  metrics:
    enabled: true
    modelMetrics:
      port: 8080                            # must match modelInvocationPort.containerPort
  worker:
    image: ${VLLM_IMAGE}
    modelInvocationPort:
      containerPort: 8080
      name: http
    modelVolumeMount:
      name: model-weights
      mountPath: /opt/ml/model
    resources:
      requests:
        nvidia.com/gpu: 1
        cpu: "${MODEL_CPU}"
        memory: ${MODEL_MEMORY}
      limits:
        nvidia.com/gpu: 1
    environmentVariables:
      - name: SM_VLLM_MODEL
        value: /opt/ml/model
      - name: SM_VLLM_SERVED_MODEL_NAME
        value: ${ENDPOINT_NAME}
      - name: SM_VLLM_TENSOR_PARALLEL_SIZE
        value: "1"
      - name: SM_VLLM_MAX_MODEL_LEN
        value: "8192"
      - name: SM_VLLM_KV_CACHE_MEMORY_BYTES   # lab only: shrink the GPU KV cache to 1 GiB
        value: "1073741824"
      - name: SM_VLLM_KV_TRANSFER_CONFIG      # connect vLLM to LMCache (see below)
        value: '{"kv_connector":"LMCacheConnectorV1","kv_role":"kv_both"}'
      - name: PYTHONHASHSEED                  # same cache keys in every process (see below)
        value: "0"
      - name: HF_HUB_OFFLINE
        value: "1"
EOF
```

Expected: the current time, then `inferenceendpointconfig.inference.sagemaker.aws.amazon.com/qwen-opt created`.

### What the manifest sets

For reference; nothing to run.

The serving image is the AWS vLLM Deep Learning Container, SageMaker variant. It includes LMCache and builds vLLM's command-line flags from `SM_VLLM_*` environment variables, so this manifest has no `args`.

| Field | Value here | Why |
|---|---|---|
| `invocationEndpoint` | `v1/chat/completions` | With routing enabled, SageMaker requests go to the router, which proxies vLLM's OpenAI routes. The operator rejects `invocations` here. |
| `replicas` | `0` | The operator adds the cache-ready node labels to the pod template only once each cache is warm. Pods that already run when that happens get a rolling update, which needs a free GPU that doesn't exist. Starting at zero lets both caches warm first. |
| `prefetchEnabled` | not set | With the L2 tier enabled, this operator version generates an invalid Deployment when `prefetchEnabled` is set. The weights cache makes it unnecessary: the pods read the weights from local NVMe, not from the S3 mount. |
| `modelCacheConfig.imageCache` | `enabled: true` | A DaemonSet pre-pulls the vLLM image onto every node of `instanceType`. |
| `modelCacheConfig.weightsCache` | `hostPath: /opt/dlami/nvme` | A download pod per GPU node copies the S3 prefix to the node's local NVMe disk; model pods read it from there. HyperPod mounts the instance store at `/opt/dlami/nvme`: about 400 GB on an `ml.g5.2xlarge`. |
| `kvCacheSpec.enableL1Cache` | `true` | The operator configures LMCache in the model container with a CPU tier: `LMCACHE_LOCAL_CPU=true` and `LMCACHE_MAX_LOCAL_CPU_SIZE=7` (GB). |
| `kvCacheSpec.enableL2Cache`, `l2CacheBackend` | `true`, `tieredstorage` | The operator points LMCache at the tiered storage daemon on the pod's node (`LMCACHE_REMOTE_URL=sagemaker-hyperpod://<node IP>:9200`) and mounts the daemon's shared memory segment into the pod. |
| `intelligentRoutingSpec` | `prefixaware` | The operator deploys a router for this endpoint in `hyperpod-inference-system` and points the load balancer at it. |
| `metrics.modelMetrics.port` | `8080` | The router and the cache metrics read vLLM's `/metrics` on the model port. |
| `SM_VLLM_KV_TRANSFER_CONFIG` | LMCache connector | The operator connects vLLM to LMCache with a `--kv-transfer-config` container argument. The SageMaker image builds vLLM's command line from the `SM_VLLM_*` variables only and drops that argument, so you pass the same value as a variable. |
| `PYTHONHASHSEED` | `0` | LMCache names each block of KV cache by a hash of its tokens, computed with Python's built-in hash, which is randomized per process unless this variable is set. Without it, a restarted model server computes different names for the same tokens and never finds its blocks in L2. |
| `SM_VLLM_KV_CACHE_MEMORY_BYTES` | 1 GiB | Lab only. A 1.5B model on a 24 GB A10G leaves roughly 16 GB for the KV cache, which a short benchmark never fills, so nothing would ever need to come back from L1. Capping it at 1 GiB (about 37,000 tokens) makes this small model behave like a large one under memory pressure. Leave it out in production. |

## Step 4: Watch the caches warm, then scale up

The operator creates the Deployment with no pods and starts filling the image and weights caches. You wait until both caches are ready on every GPU node, then scale up. Scaling up earlier leaves a pod stuck `Pending` (see Troubleshooting).

The commands below show the Deployment, the weights cache, the image cache, and the cache-ready labels on the nodes:

```bash
kubectl get deploy "$ENDPOINT_NAME" -n $NAMESPACE
kubectl get modelweightscacheconfig -n $NAMESPACE
kubectl get modelimagecache -n hyperpod-inference-system
kubectl get nodes --show-labels | tr ',' '\n' | grep cache-ready
```

Run them again every minute or so. What you see, in order:

1. The Deployment shows `0/0` the whole time.
2. The weights cache appears first. A `cache-dl-...` download pod runs on each GPU node, and the `ModelWeightsCacheConfig` reaches `Ready`, with `READY` equal to `TARGET` (the number of GPU nodes).
3. The image cache follows: a `ModelImageCache` for the vLLM image on your instance type, which pulls the 9 GB image onto each GPU node.
4. The node labels appear. You're ready when the last command prints, for each GPU node, one `image-cache-ready.<id>=true` and one `weights-cache-ready.<id>=true` line (two of each with two GPU nodes).

This takes about nine minutes after the apply, most of it the image pull. In your own clusters, `imageCache` gives every node this head start: the pull happens when a node joins, before any pod waits for it.

When both labels are on every GPU node, the commands below scale the Deployment to one replica per GPU node, wait for the rollout, and list the pods:

```bash
kubectl scale deploy/"$ENDPOINT_NAME" -n $NAMESPACE --replicas="$REPLICAS"
kubectl rollout status deploy/"$ENDPOINT_NAME" -n $NAMESPACE --timeout=10m
kubectl get pods -n $NAMESPACE -l app="$ENDPOINT_NAME" -o wide
```

Expected, within about two minutes: `successfully rolled out`, and one pod per GPU node, each `3/3 Running`.

The command below filters the model container's log for the lines that show what it started with:

```bash
POD=$(kubectl get pods -n $NAMESPACE -l app="$ENDPOINT_NAME" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n $NAMESPACE "$POD" -c "$ENDPOINT_NAME" \
  | grep -E 'server arguments|Loading weights took|GPU KV cache size|Creating LMCacheEngine|Connector initialized|startup complete' | cut -c1-200
```

Expected: these five things in the output.

- The `vLLM server arguments` line contains `--kv-cache-memory-bytes 1073741824` and `--kv-transfer-config {"kv_connector":"LMCacheConnectorV1",...}`.
- `Loading weights took` a few seconds: the weights come from the local NVMe copy, not from S3. The pod's `cache-resolver` init container linked the cached files into `/opt/ml/model`.
- `GPU KV cache size: 37,440 tokens`: the 1 GiB cap.
- `Creating LMCacheEngine with config: {'chunk_size': 256, 'local_cpu': True, 'max_local_cpu_size': 7.0, ...`: the L1 tier, 7 GB of the pod's memory, stored in chunks of 256 tokens.
- `SageMaker HyperPod Connector initialized: url=http://<node IP>:9200, bucket=lmcache, shared_memory=ai_toolkit_cache`: the L2 tier, the daemon from Step 2.

If a line is missing, see Troubleshooting at the end of this page.

The commands below wait for the SageMaker endpoint to exist and then to reach `InService`, and print the time:

```bash
until aws sagemaker describe-endpoint --endpoint-name "$ENDPOINT_NAME" --region $REGION >/dev/null 2>&1; do sleep 15; done
aws sagemaker wait endpoint-in-service --endpoint-name "$ENDPOINT_NAME" --region $REGION && date
```

Expected: the command returns with the time, a few minutes after the pods are running. Compare it with the time Step 3 printed: about 12 minutes from the apply to `InService`.

On this small model, the caches mainly change where the time goes: the image pull and the weight download happen before the pods are scheduled, not while a pod waits. Their effect grows with the size of the model and with the number of fresh nodes a deployment scales onto.

## Step 5: Follow a request through the router

With routing enabled, the request path has one more hop: load balancer, then router, then model pod. In this step you find the router and confirm it forwards your request to a model pod.

The commands below list what the operator created for the endpoint in its own namespace, and where the load balancer's route points:

```bash
kubectl get deploy,svc,ingress -n hyperpod-inference-system | grep "$ENDPOINT_NAME"
kubectl get ingress -n hyperpod-inference-system -o jsonpath='{range .items[*].spec.rules[*].http.paths[*]}{.path} -> {.backend.service.name}{"\n"}{end}'
```

Expected: a router Deployment, its Service, and an Ingress for `qwen-opt`. The last line shows the load balancer's single route, `/v1/chat/completions -> qwen-opt-<namespace>-routing-service`. That's the router's Service, not the model pods. The router finds the model pods by their `app=qwen-opt` label and forwards each request to one of them.

The command below sends one chat request through SageMaker. The body needs a `model` field: the router uses it to find the model's replicas and rejects requests without it.

```bash
time aws sagemaker-runtime invoke-endpoint --region $REGION \
  --endpoint-name "$ENDPOINT_NAME" \
  --content-type application/json \
  --body '{"model":"qwen-opt","messages":[{"role":"user","content":"In one sentence, what is Amazon SageMaker HyperPod?"}],"max_tokens":80}' \
  --cli-binary-format raw-in-base64-out /dev/stdout
```

Expected: a JSON chat completion with a one-sentence answer, then the elapsed time, usually under a few seconds.

The commands below find your request in the router's log and list the model pods with their IPs:

```bash
ROUTER=$(kubectl get pods -n hyperpod-inference-system -o name | grep "${ENDPOINT_NAME}-${NAMESPACE}-router")
kubectl logs -n hyperpod-inference-system "$ROUTER" -c router-container --tail=50 | grep 'Routing request'
kubectl get pods -n $NAMESPACE -l app="$ENDPOINT_NAME" -o wide
```

Expected:

- Each router line reads `Routing request <id> with session id None to http://<pod IP>:8081`.
- The IP matches one of the model pods in the list. Port 8081 is the pod's reverse-proxy sidecar, which sits in front of vLLM on 8080.

The router also logs `No cache hit, forwarding request to backend` for every request. That refers to the router's own response cache, which isn't enabled here, not to the KV cache. You can ignore it.

## Step 6: Measure the L1 cache

Now measure what LMCache saves when prompts come back after the GPU has evicted them.

How the benchmark works (the script below runs it):

- It builds 14 synthetic documents of about 3,800 tokens each, about 53,000 tokens in total. That's more than the GPU KV cache holds (about 37,000 tokens).
- Pass 1 sends each document once, with a question. Every prefix is new.
- Pass 2 sends each document again, with a different question. The two requests for a document share their whole prefix: the system message that holds the document.
- By the time pass 2 comes back to a document, the GPU has evicted it to make room for the others, so a hit has to come from LMCache.
- Each request asks for at most four tokens, so its latency is mostly the time to process the prompt, close to the **time to first token (TTFT)**.

The script also takes options that Step 8 uses: `NUM_DOCS` and `DOC_OFFSET` choose other documents, and the argument `revisit` runs pass 2 only.

The command below writes the benchmark to `kvbench.py` and runs it:

```bash
cat > kvbench.py <<'EOF'
import json, os, random, statistics, sys, time, boto3

endpoint = os.environ["ENDPOINT_NAME"]
rt = boto3.client("sagemaker-runtime", region_name=os.environ.get("REGION") or os.environ.get("AWS_REGION"))
WORDS = ("cloud model token cache memory node replica router prefix latency engine weight tensor "
         "batch request stream kernel driver socket region subnet cluster health metric policy "
         "budget signal vector layer shard queue worker client server packet storage volume").split()

def document(i, words=3500):
    rng = random.Random(i)
    body = " ".join(rng.choice(WORDS) + ("." if rng.random() < 0.08 else "") for _ in range(words))
    return f"Document {i}. {body}"

OFFSET = int(os.environ.get("DOC_OFFSET", "0"))
DOCS = [document(OFFSET + i) for i in range(int(os.environ.get("NUM_DOCS", "14")))]

def ask(doc, question):
    body = json.dumps({"model": endpoint, "max_tokens": 4, "temperature": 0,
                       "messages": [{"role": "system", "content": doc}, {"role": "user", "content": question}]})
    start = time.time()
    out = json.loads(rt.invoke_endpoint(EndpointName=endpoint, ContentType="application/json", Body=body)["Body"].read())
    return time.time() - start, out["usage"]["prompt_tokens"]

def run(label, question):
    times, tokens = [], 0
    for doc in DOCS:
        t, n = ask(doc, question)
        times.append(t); tokens += n
    print(f"{label:<32} median {statistics.median(times)*1000:6.0f} ms   "
          f"min {min(times)*1000:5.0f}  max {max(times)*1000:5.0f}   prompt tokens {tokens:,}", flush=True)

if sys.argv[1:] != ["revisit"]:
    run("pass 1: every prefix new", "Reply with the first word of the document.")
run("pass 2: same prefixes, revisited", "Reply with the last word of the document.")
EOF
python3 kvbench.py
```

It takes about 30 seconds. Expected output, similar to this:

```text
pass 1: every prefix new         median    687 ms   min   678  max  2507   prompt tokens 53,276
pass 2: same prefixes, revisited median    451 ms   min   444  max   508   prompt tokens 53,276
```

How to read it:

- Each line shows the median, fastest, and slowest request latency of the pass, in milliseconds, measured end to end through SageMaker, the load balancer, and the router. `prompt tokens` is the total over the 14 requests; it's the same in both passes.
- Compare the two medians. Good looks like pass 2 about a third faster than pass 1: the prefixes came from a cache instead of being recomputed. Your absolute numbers will differ.
- The high `max` of pass 1 is the first request after the deployment, which also warms vLLM up. Ignore it.

### Where the saving comes from

vLLM counts cache hits on each replica. The command below forwards a local port to each model pod in turn (18080, because Code Editor already uses 8080) and prints three counters from its `/metrics` page:

```bash
for p in $(kubectl get pods -n $NAMESPACE -l app="$ENDPOINT_NAME" -o jsonpath='{.items[*].metadata.name}'); do
  kubectl port-forward -n $NAMESPACE "$p" 18080:8080 >/tmp/pf.log 2>&1 &
  PF_PID=$!
  until grep -q Forwarding /tmp/pf.log; do sleep 1; done
  echo "== $p"
  curl -s http://localhost:18080/metrics \
    | grep -E '^(vllm:prefix_cache_hits_total|vllm:external_prefix_cache_hits_total|lmcache:local_cache_usage)' \
    | sed -E 's/\{[^}]*\}//'
  kill "$PF_PID"; sleep 1
done
```

What the counters mean:

- `vllm:prefix_cache_hits_total`: prompt tokens found in the GPU KV cache.
- `vllm:external_prefix_cache_hits_total`: tokens vLLM didn't compute because LMCache supplied them.
- `lmcache:local_cache_usage`: what pass 1 left in L1, out of 7 GB. LMCache looks in L1 first.

Expected, depending on how many replicas you have:

- **Two replicas** (the usual case, with two GPU nodes): `vllm:prefix_cache_hits_total` is high, about 53,000 tokens across the two pods, and `external_prefix_cache_hits_total` is close to 0. Each replica's share of the documents fits in its GPU cache, so pass 2 hits in GPU memory. Step 7 explains why.
- **One replica**: `prefix_cache_hits_total` is 0 and `external_prefix_cache_hits_total` is about 50,000. Revisiting the documents in order evicted each one from the GPU shortly before it was needed again, so in pass 2 every complete 256-token chunk of each document came back from L1.

The command below shows the same thing request by request, from the log of the pod Step 4 inspected:

```bash
kubectl logs -n $NAMESPACE "$POD" -c "$ENDPOINT_NAME" | grep -E 'LMCache hit tokens: [1-9]|Retrieved' | head -2 | cut -c1-200
```

Expected:

- **Two replicas**: `LMCache hit tokens: 3584, need to load: 0`. LMCache has the prefix, but the GPU still holds it, so nothing needs copying (Step 7).
- **One replica**: `LMCache hit tokens: 3584, need to load: 3584`, followed by `Retrieved 3584 out of 3584 required tokens`, which takes a few milliseconds. Copying 3,584 tokens of KV back from CPU memory replaced recomputing them on the GPU.

## Step 7: Routing with two replicas

This step shows why prefix-aware routing matters once you have more than one replica. If you have one GPU node, read it and go to Step 8.

Each replica has its own GPU cache and its own L1. A document's KV blocks are in the caches of the replica that processed it in pass 1. Pass 2 finds them only if the router sends the document back to that same replica, which is what `prefixaware` does. With `roundrobin` (take turns), about half of the pass 2 requests would land on the other replica and compute their prefix again.

The commands below count, from the router's log, how many requests went to each replica in the last 10 minutes, and, from each model pod's log, how many requests found their prefix in LMCache:

```bash
ROUTER=$(kubectl get pods -n hyperpod-inference-system -o name | grep "${ENDPOINT_NAME}-${NAMESPACE}-router")
kubectl logs -n hyperpod-inference-system "$ROUTER" -c router-container --since=10m \
  | grep -o 'Routing request .* to http://[0-9.]*' | awk '{print $NF}' | sort | uniq -c
for p in $(kubectl get pods -n $NAMESPACE -l app="$ENDPOINT_NAME" -o jsonpath='{.items[*].metadata.name}'); do
  echo "$p: $(kubectl logs -n $NAMESPACE "$p" -c "$ENDPOINT_NAME" | grep -c 'LMCache hit tokens: [1-9]') requests found their prefix in LMCache"
done
```

Expected, similar to this (in testing):

- The router's counts: two pod IPs with roughly even counts, for example 16 and 14. That's the 28 benchmark requests plus Step 5's requests. The router spread the 14 new documents of pass 1 over the two replicas.
- The per-pod hit counts: for example 7 and 7, which add up to 14. Every pass 2 request went back to the replica that had its document.

What this means:

- Each replica only holds its half of the documents, about 26,000 tokens, which fits in its GPU cache.
- That's why Step 6's `vllm:prefix_cache_hits_total` was about 53,000 across the two replicas: the whole of pass 2 came straight from GPU memory, and `external_prefix_cache_hits_total` hardly moved.
- Prefix-aware routing turned two GPU caches into one cache twice the size.

## Step 8: L2 survives a restart

L1 belongs to the model server process: when the pod restarts, it's empty. L2 lives in the node's tiered storage daemon, outside the pod. In this step you prove that L2 keeps a prefix across a restart.

The test uses one new document (about 100 MB of KV; the end of this step explains why the test stays this small). The commands below:

1. send the document once (pass 1),
2. delete the model pods, so their L1 is lost,
3. wait for the replacement pods and for the endpoint to answer again,
4. ask about the document again (pass 2 only).

```bash
NUM_DOCS=1 DOC_OFFSET=500 python3 kvbench.py
kubectl delete pod -n $NAMESPACE -l app="$ENDPOINT_NAME"
sleep 15
kubectl wait -n $NAMESPACE --for=condition=Ready pod -l app="$ENDPOINT_NAME" --timeout=10m
until aws sagemaker-runtime invoke-endpoint --region $REGION --endpoint-name "$ENDPOINT_NAME" --content-type application/json \
    --body '{"model":"qwen-opt","messages":[{"role":"user","content":"Reply with OK."}],"max_tokens":2}' \
    --cli-binary-format raw-in-base64-out /dev/null >/dev/null 2>&1; do sleep 5; done
NUM_DOCS=1 DOC_OFFSET=500 python3 kvbench.py revisit
```

It takes about three minutes; the replacement pods serve about two minutes after the delete. Expected: a `pass 1` line, `pod ... deleted` lines, `condition met` lines, and a `pass 2` line. Ignore the latency the benchmark prints here: the first requests on a freshly started pod are slower anyway.

The command below reads the cache counters and LMCache log lines of the new pods:

```bash
for p in $(kubectl get pods -n $NAMESPACE -l app="$ENDPOINT_NAME" -o jsonpath='{.items[*].metadata.name}'); do
  kubectl port-forward -n $NAMESPACE "$p" 18080:8080 >/tmp/pf.log 2>&1 &
  PF_PID=$!
  until grep -q Forwarding /tmp/pf.log; do sleep 1; done
  echo "== $p"
  curl -s http://localhost:18080/metrics \
    | grep -E '^(vllm:external_prefix_cache_hits_total|lmcache:num_remote_read_bytes_total)' \
    | sed -E 's/\{[^}]*\}//'
  kill "$PF_PID"; sleep 1
  kubectl logs -n $NAMESPACE "$p" -c "$ENDPOINT_NAME" | grep -E 'LMCache hit tokens: [1-9]|Retrieved' | cut -c1-200
done
```

Expected, on the pod that served the request (the other pod shows zeros):

- `vllm:external_prefix_cache_hits_total 3584`
- `lmcache:num_remote_read_bytes_total` about 205 MB
- `Retrieved 3584 out of 3584 required tokens ... cost 121 ms`

How to read it:

- The new pod had never seen the document, and its L1 was empty. Still, 3,584 tokens came from LMCache, read from the tiered storage daemon (L2).
- The daemons also exchange data between nodes, so the request may land on a different node than the one that computed the document and still hit. In that case `num_remote_read_bytes_total` stays at 0, and the `Retrieved` line and `external_prefix_cache_hits_total` show the hit.
- A read from L2 costs tens of milliseconds, against a few milliseconds from L1. Both are far cheaper than recomputing the prefix of a large model.

This is also where `PYTHONHASHSEED` matters. Without it, the replacement pod names the same tokens differently and finds nothing in L2.

### Comparing the tiers

For reference; nothing to run.

| Tier | Where | Size here | Survives a pod restart | Shared with other replicas | Copy cost for one document |
|---|---|---|---|---|---|
| GPU KV cache | GPU memory | about 37,000 tokens (capped) | no | no | none |
| L1 | model server's CPU memory | 7 GB, about 250,000 tokens | no | no | a few ms |
| L2 | tiered storage daemons on the nodes | 1 GiB per node, about 37,000 tokens | yes | yes, also across nodes | tens of ms |

Why the test uses one document: L2 evicts a block that was written once and not read again soon, to protect blocks that are read repeatedly. If you ran Step 6's 14-document benchmark against freshly restarted pods, almost nothing would come back from L2. A prefix that many requests share, such as a long system prompt, a retrieved document, or a tool catalog, is what L2 keeps. Size L2 for hot prefixes, and keep L1 for the working set of each replica.

## What to take away

- **Tiered KV caching** turns repeated prompt processing into a memory copy. It pays off when requests share long prefixes (system prompts, retrieved documents, multi-turn conversations, agent loops) and when the GPU KV cache is under pressure, which is the normal state for a large model with many concurrent users.
- **Routing** decides whether a cache hit is possible at all once there is more than one replica.
- **Model caching** moves the image pull and the weight download out of the pod's critical path and onto the moment a node joins. On a 3 GB model it barely shows; on a model of tens or hundreds of gigabytes, and when scaling onto fresh nodes, it's the difference between seconds and many minutes.

## Clean up

Delete the endpoint and turn tiered storage off, so the GPUs and the node memory are free for the next lab.

The commands below delete the `InferenceEndpointConfig`, wait until its SageMaker endpoint is gone, and disable tiered storage:

```bash
kubectl delete inferenceendpointconfig "$ENDPOINT_NAME" -n $NAMESPACE
until ! aws sagemaker describe-endpoint --endpoint-name "$ENDPOINT_NAME" --region $REGION >/dev/null 2>&1; do sleep 10; done
aws sagemaker update-cluster --cluster-name "$HYPERPOD_CLUSTER_NAME" --region $REGION \
  --tiered-storage-config Mode=Disable >/dev/null && echo "tiered storage: disable requested"
```

Expected: `inferenceendpointconfig... "qwen-opt" deleted`, then, after a minute or two, `tiered storage: disable requested`. Disabling tiered storage removes the `ai-toolkit` daemons and returns the 20% of node memory.

If a later lab finds the GPUs taken, `~/hyperpod-inference-dive-deep/scripts/reset-gpus.sh -y` also removes this lab's image and weights caches and tiered storage.

## Troubleshooting

- **The endpoint never appears; `kubectl describe inferenceendpointconfig` shows `IntelligentRoutingValidationFailed`.** `invocationEndpoint` isn't one of vLLM's routes. The operator doesn't retry a deployment that failed validation: delete the `InferenceEndpointConfig` and apply it again with `v1/chat/completions`.
- **The Deployment never appears; `kubectl get events -n $NAMESPACE | grep DeploymentCreateFailed` shows `volumeMounts[...].name: Not found: "lmcache-config"`.** The manifest sets `prefetchEnabled` together with the L2 tier. Delete the `InferenceEndpointConfig` and apply it again without `prefetchEnabled`.
- **`invoke-endpoint` returns `ModelError` with `missing 'model' in request body`.** The router needs the `model` field: add `"model":"qwen-opt"` to the body.
- **A model pod stays `Pending` with `Insufficient nvidia.com/gpu`, from a newer ReplicaSet.** The Deployment was scaled up before both caches were warm, and the operator's template update is waiting for a free GPU. Scale to zero with `kubectl scale deploy/"$ENDPOINT_NAME" -n $NAMESPACE --replicas=0`, wait until the pods are gone, then scale to `$REPLICAS` again. If the pending pod is waiting for a GPU that another lab's model holds, run `~/hyperpod-inference-dive-deep/scripts/reset-gpus.sh -y` instead and start this lab again from Step 2.
- **A pod stays `Pending` with `Too many pods`.** The node is at its pod limit. Run Step 1's pod slot check and its fixes. The overview page explains the pod budget per node.
- **No `LMCache` lines in the model log and `vllm:external_prefix_cache_hits_total` stays at 0.** Check the `vLLM server arguments` line for `--kv-transfer-config`. If it's missing, `SM_VLLM_KV_TRANSFER_CONFIG` is missing or misspelled.
- **Step 8 shows no hit.** Either `PYTHONHASHSEED` isn't set in the model container (the log warns `PYTHONHASHSEED not set`), or the document was evicted from L2 before you came back to it, for example because other runs wrote to L2 in between. Run Step 8 again with another `DOC_OFFSET`. Also check that the `ai-toolkit` pod on each GPU node is running (Step 2).
- **`Loading weights took` several seconds and the pod has no `cache-resolver` init container.** The pod started before the weights cache was warm and read the weights from S3. It still serves; scale to zero and back to pick up the cache.

## Going further

For reference; nothing to run.

- **Redis as L2.** `l2CacheBackend: redis` with `l2CacheLocalUrl` uses a Redis cluster you run, for example Amazon ElastiCache, instead of the nodes' memory. You size and secure it yourself; keep it in the cluster's VPC. Neither backend encrypts KV data at rest, and managed tiered storage doesn't isolate the deployments of a cluster from each other. See [KV caching and intelligent routing](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-model-deployment-caching-routing.html).
- **Other routing strategies.** `session` keeps a user session on one replica, `roundrobin` ignores the cache, and `kvaware` routes to the replica with the highest measured cache hit rate; `kvaware` needs `invocationEndpoint: v1/completions`. You can change the strategy on a running deployment with `kubectl patch`, but you can't turn routing on for a running deployment.
- **Disaggregated prefill and decode** (`pdSpec`) runs prompt processing and token generation on separate pods, and combines with these features for large models.
