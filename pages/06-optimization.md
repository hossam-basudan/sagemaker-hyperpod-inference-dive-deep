# 6. Optimize: tiered KV cache, routing, and model caching

A plain deployment recomputes every prompt from scratch unless the exact prefix is still in GPU memory, sends each request to whichever replica the load balancer picks, and starts every new pod by reading the weights from S3 and pulling a 9 GB image. The inference operator has three features that address each of these, all set on the same `InferenceEndpointConfig`:

- **Tiered KV cache** (`kvCacheSpec`). When vLLM processes a prompt it computes key and value tensors for every token: the KV cache. vLLM reuses them while they stay in GPU memory. The operator adds [LMCache](https://docs.lmcache.ai/) behind vLLM so that KV blocks are also kept outside the GPU, in two tiers. **L1** lives in the model server's own CPU memory: fast, but gone when the pod restarts. **L2** lives in a cache service that runs on every node, outside the pod: SageMaker HyperPod managed tiered storage, or a Redis cluster you provide. A request whose prefix is in L1 or L2 copies the tensors back instead of recomputing them.
- **Intelligent routing** (`intelligentRoutingSpec`). The operator puts a router in front of the replicas. With the `prefixaware` strategy, requests that share a prompt prefix go to the replica that already holds that prefix in its cache.
- **Model caching** (`modelCacheConfig`). The operator pre-pulls the serving image onto the GPU nodes (`imageCache`) and copies the model weights to the node's local NVMe disk (`weightsCache`) before the pods start, so new replicas skip the image pull and the S3 read.

In this module you turn on the cluster's tiered storage, deploy an optimized endpoint, measure the L1 cache with a workload that revisits long prompts, look at how the router keeps prefixes on one replica, and show that a prefix in L2 survives a restart of the model server.

> [!NOTE]
> Budget about 40 minutes, most of it waiting for the caches and the endpoint. The module uses both GPUs and the model weights you staged in S3 in module 4. It also needs pod slots: up to four more pods on each GPU node (the model, the tiered storage daemon, the image cache, and the router) and three on the CPU node. Step 1 checks them.

## Step 1: Set your environment

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
  && echo "weights staged" || echo "Stage the weights first: module 4, Amazon S3 lab"
kubectl get inferenceendpointconfig,jumpstartmodel -A
```

`REPLICAS` is the number of GPU nodes: one replica per GPU. The last command should list nothing: delete any deployment the earlier modules left, so both GPUs are free. With one GPU node the module still works; routing just has no choice to make.

Check that every node has room for this module's pods. HyperPod limits pods per node (14 on an `ml.g5.2xlarge`, 29 on an `ml.c5.4xlarge`):

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

If a node shows `NOT ENOUGH`, the list under it shows what fills it. About 7 pods per node in `kube-system` are system DaemonSets that always stay. Free the rest:

| Namespace in the list | What it is | Fix |
|---|---|---|
| `default` | Models left by earlier modules, including `tinyllama-dd` | Delete them (first command below) |
| `hyperpod-observability` | The optional observability add-on: 3 to 6 pods per node. Only modules 2 and 3 use it | Remove it (second command below). This also deletes the Prometheus workspace and its metrics |
| `hyperpod-inference-system`, other controllers | Controllers that can run on the CPU node | Rerun setup (third command below) |

Each command is safe to run when there's nothing to remove:

```bash
kubectl delete inferenceendpointconfig tinyllama-dd qwen-hf qwen-s3 qwen-fsx qwen-byoc -n $NAMESPACE --ignore-not-found
kubectl delete jumpstartmodel deepseek-js -n $NAMESPACE --ignore-not-found
```

```bash
~/hyperpod-inference-dive-deep/scripts/observability.sh --remove -y
```

```bash
~/hyperpod-inference-dive-deep/scripts/setup.sh -y
```

Then run the check again until every node shows `OK`.

## Step 2: Turn on the cluster's tiered storage

The L2 tier needs a cache service on the nodes, and HyperPod provides one: **managed tiered storage**, a memory-management daemon that HyperPod also uses for in-memory training checkpoints. It's a cluster setting, off by default. Turn it on with 20% of each node's memory, the minimum:

```bash
aws sagemaker update-cluster --cluster-name "$HYPERPOD_CLUSTER_NAME" --region $REGION \
  --tiered-storage-config Mode=Enable,InstanceMemoryAllocationPercentage=20 >/dev/null && echo "update requested"
aws sagemaker describe-cluster --cluster-name "$HYPERPOD_CLUSTER_NAME" --region $REGION \
  --query TieredStorageConfig --output table
```

The update completes in seconds. Within about a minute, HyperPod starts the daemon, `ai-toolkit`, on every node:

```bash
kubectl get pods -n aws-hyperpod -o wide | grep -E 'NAME|ai-toolkit'
```

Run it again until there is one `ai-toolkit` pod per node, `1/1 Running`. A restart or two in the first minute is normal while the daemons find each other. Each pod uses the host network and listens on port 9200 of its node. The model pods reach the daemon on their own node there and share a memory segment with it. The daemon reserves the 20% (about 6.4 GiB on an `ml.g5.2xlarge`), of which 1 GiB holds KV cache in this configuration.

## Step 3: Apply the optimized InferenceEndpointConfig

Intelligent routing, KV caching, and model caching are applied only when a deployment is created; you can't add them to a running one. Note the time before you apply:

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

The serving image is the AWS vLLM Deep Learning Container, SageMaker variant. It includes LMCache and takes its vLLM flags from `SM_VLLM_*` variables, so this manifest has no `args`.

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

The operator creates the Deployment with no pods and starts on the caches:

```bash
kubectl get deploy "$ENDPOINT_NAME" -n $NAMESPACE
kubectl get modelweightscacheconfig -n $NAMESPACE
kubectl get modelimagecache -n hyperpod-inference-system
kubectl get nodes --show-labels | tr ',' '\n' | grep cache-ready
```

Run the commands again every minute or so. The Deployment shows `0/0`. The weights cache appears first: a `cache-dl-...` pod runs on each GPU node, and the `ModelWeightsCacheConfig` reaches `Ready` with `READY` equal to `TARGET`, the number of GPU nodes. The image cache follows: a `ModelImageCache` for the vLLM image on your instance type, which pulls the 9 GB image onto each GPU node. Both labels appear about nine minutes after the apply, most of it the image pull. In your own clusters, `imageCache` is how you get this effect for every node: the pull happens when a node joins, before any pod waits for it. When each GPU node carries both an `image-cache-ready.<id>=true` and a `weights-cache-ready.<id>=true` label, scale up:

```bash
kubectl scale deploy/"$ENDPOINT_NAME" -n $NAMESPACE --replicas="$REPLICAS"
kubectl rollout status deploy/"$ENDPOINT_NAME" -n $NAMESPACE --timeout=10m
kubectl get pods -n $NAMESPACE -l app="$ENDPOINT_NAME" -o wide
```

Each pod is `3/3 Running` within about two minutes. Confirm what the model container started with:

```bash
POD=$(kubectl get pods -n $NAMESPACE -l app="$ENDPOINT_NAME" -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n $NAMESPACE "$POD" -c "$ENDPOINT_NAME" \
  | grep -E 'server arguments|Loading weights took|GPU KV cache size|Creating LMCacheEngine|Connector initialized|startup complete' | cut -c1-200
```

Five things to find in the output:

- The `vLLM server arguments` line contains `--kv-cache-memory-bytes 1073741824` and `--kv-transfer-config {"kv_connector":"LMCacheConnectorV1",...}`.
- `Loading weights took` a few seconds: the weights come from the local NVMe copy, not from S3. The pod's `cache-resolver` init container linked the cached files into `/opt/ml/model`.
- `GPU KV cache size: 37,440 tokens`: the 1 GiB cap.
- `Creating LMCacheEngine with config: {'chunk_size': 256, 'local_cpu': True, 'max_local_cpu_size': 7.0, ...`: the L1 tier, 7 GB of the pod's memory, stored in chunks of 256 tokens.
- `SageMaker HyperPod Connector initialized: url=http://<node IP>:9200, bucket=lmcache, shared_memory=ai_toolkit_cache`: the L2 tier, the daemon from Step 2.

Then wait for the SageMaker endpoint:

```bash
until aws sagemaker describe-endpoint --endpoint-name "$ENDPOINT_NAME" --region $REGION >/dev/null 2>&1; do sleep 15; done
aws sagemaker wait endpoint-in-service --endpoint-name "$ENDPOINT_NAME" --region $REGION && date
```

Expect about 12 minutes from the `kubectl apply` to `InService`. On this small model the caches mainly change where the time goes: the image pull and the weight download happen before the pods are scheduled. Their effect grows with the size of the model and the number of fresh nodes a deployment scales onto.

## Step 5: Follow a request through the router

The request path now has one more hop. Look at what the operator created for the endpoint in its own namespace:

```bash
kubectl get deploy,svc,ingress -n hyperpod-inference-system | grep "$ENDPOINT_NAME"
kubectl get ingress -n hyperpod-inference-system -o jsonpath='{range .items[*].spec.rules[*].http.paths[*]}{.path} -> {.backend.service.name}{"\n"}{end}'
```

The load balancer's single route is `/v1/chat/completions`, and it forwards to `qwen-opt-<namespace>-routing-service`, the router's Service, not to the model pods. The router discovers the model pods by their `app=qwen-opt` label and forwards each request to one of them.

Invoke the endpoint. The body needs a `model` field: the router uses it to find the model's replicas and rejects requests without it.

```bash
time aws sagemaker-runtime invoke-endpoint --region $REGION \
  --endpoint-name "$ENDPOINT_NAME" \
  --content-type application/json \
  --body '{"model":"qwen-opt","messages":[{"role":"user","content":"In one sentence, what is Amazon SageMaker HyperPod?"}],"max_tokens":80}' \
  --cli-binary-format raw-in-base64-out /dev/stdout
```

Find your request in the router's log:

```bash
ROUTER=$(kubectl get pods -n hyperpod-inference-system -o name | grep "${ENDPOINT_NAME}-${NAMESPACE}-router")
kubectl logs -n hyperpod-inference-system "$ROUTER" -c router-container --tail=50 | grep 'Routing request'
kubectl get pods -n $NAMESPACE -l app="$ENDPOINT_NAME" -o wide
```

Each line reads `Routing request <id> with session id None to http://<pod IP>:8081`, and the IP is one of your model pods (port 8081 is the pod's reverse-proxy sidecar, in front of vLLM on 8080). The router also logs `No cache hit, forwarding request to backend` for every request; that refers to the router's own response cache, which isn't enabled, not to the KV cache.

## Step 6: Measure the L1 cache

The benchmark below builds 14 synthetic documents of about 3,800 tokens each, about 53,000 tokens in total: more than the GPU KV cache holds. It sends each document once with a question (pass 1), then each document again with a different question (pass 2). The two requests for a document share their whole prefix: the system message with the document. By the time pass 2 comes back to a document, the GPU has evicted it to make room for the others, so its prefix has to come from LMCache. Each request asks for at most four tokens, so its latency is mostly the time to process the prompt. `NUM_DOCS` and `DOC_OFFSET` choose other documents, and `revisit` runs pass 2 only; Step 8 uses both.

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

It takes about 30 seconds. The output looks similar to this:

```text
pass 1: every prefix new         median    687 ms   min   678  max  2507   prompt tokens 53,276
pass 2: same prefixes, revisited median    451 ms   min   444  max   508   prompt tokens 53,276
```

Pass 2 is about a third faster, measured end to end through SageMaker, the load balancer, and the router. The `max` of pass 1 is the first request after the deployment, which also warms vLLM up. To see where the saving comes from, read vLLM's own counters on each replica. Forward a local port (18080, because Code Editor already uses 8080) and filter `/metrics`:

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

- `vllm:prefix_cache_hits_total`: prompt tokens found in the GPU KV cache.
- `vllm:external_prefix_cache_hits_total`: tokens vLLM didn't compute because LMCache supplied them.
- `lmcache:local_cache_usage`: what pass 1 left in L1, out of 7 GB. LMCache looks in L1 first.

With **one replica**, `prefix_cache_hits_total` is 0 and `external_prefix_cache_hits_total` is about 50,000: revisiting the documents in order evicted each one from the GPU shortly before it was needed again, and every complete 256-token chunk of each document came back from L1 in pass 2. With **two replicas**, read Step 7 first.

The model container's log shows the same thing request by request:

```bash
kubectl logs -n $NAMESPACE "$POD" -c "$ENDPOINT_NAME" | grep -E 'LMCache hit tokens: [1-9]|Retrieved' | head -2 | cut -c1-200
```

With one replica, a cache hit logs `LMCache hit tokens: 3584, need to load: 3584`, followed by `Retrieved 3584 out of 3584 required tokens`, which takes a few milliseconds: copying 3,584 tokens of KV back from CPU memory replaced recomputing them on the GPU. With two replicas it logs `need to load: 0`: LMCache has the prefix, but the GPU still holds it, so nothing needs copying (Step 7).

## Step 7: Routing with two replicas

With two GPU nodes you have two replicas, and each has its own GPU cache and its own L1. A document's KV blocks are in the caches of the replica that processed it in pass 1. Pass 2 only finds them if the router sends the document back to that replica, which is what `prefixaware` does. With `roundrobin`, about half of the pass 2 requests would land on the other replica and compute their prefix again.

Count which replica the router chose for each request, and on each replica how many requests found their prefix already cached:

```bash
ROUTER=$(kubectl get pods -n hyperpod-inference-system -o name | grep "${ENDPOINT_NAME}-${NAMESPACE}-router")
kubectl logs -n hyperpod-inference-system "$ROUTER" -c router-container --since=10m \
  | grep -o 'Routing request .* to http://[0-9.]*' | awk '{print $NF}' | sort | uniq -c
for p in $(kubectl get pods -n $NAMESPACE -l app="$ENDPOINT_NAME" -o jsonpath='{.items[*].metadata.name}'); do
  echo "$p: $(kubectl logs -n $NAMESPACE "$p" -c "$ENDPOINT_NAME" | grep -c 'LMCache hit tokens: [1-9]') requests found their prefix in LMCache"
done
```

The router spreads the 14 new documents of pass 1 over the two replicas, in testing 16 and 14 requests including Step 5's, and sends every document back to the same replica in pass 2: the per-pod counts (7 and 7) add up to 14. Each replica only has to hold its half of the documents, about 26,000 tokens, which fits into its GPU cache. So in Step 6's counters, `vllm:prefix_cache_hits_total` is no longer 0: the two replicas together report about 53,000 hit tokens, the whole of pass 2, straight from GPU memory, and `external_prefix_cache_hits_total` hardly moves. Prefix-aware routing turned two GPU caches into one cache twice the size.

## Step 8: L2 survives a restart

L1 belongs to the model server process: when the pod restarts, it's empty. L2 lives in the node's tiered storage daemon, outside the pod. Prove it with one new document: send it once, delete the model pods, and ask about it again on the replacements. One document is about 100 MB of KV; the end of this step explains why the test stays this small.

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

The replacement pods serve about two minutes after the delete, and the last command sends pass 2 for the document. Read the counters of the new pods:

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

The pod that served the request shows `vllm:external_prefix_cache_hits_total 3584`, `lmcache:num_remote_read_bytes_total` about 205 MB, and `Retrieved 3584 out of 3584 required tokens ... cost 121 ms` (the other pod shows zeros). The new pod had never seen the document and its L1 was empty, and still 3,584 tokens came from LMCache, read from the tiered storage daemon. The daemons also exchange data between nodes: the request may land on another node than the one that computed the document, and it still hits. In that case `num_remote_read_bytes_total` stays at 0, and the `Retrieved` line and `external_prefix_cache_hits_total` show the hit. A read from L2 costs tens of milliseconds, against a few milliseconds from L1, both far cheaper than recomputing the prefix of a large model. Ignore the latency the benchmark prints here: the first requests on a freshly started pod are slower anyway.

This is also where `PYTHONHASHSEED` matters. Without it, the replacement pod names the same tokens differently and finds nothing in L2.

| Tier | Where | Size here | Survives a pod restart | Shared with other replicas | Copy cost for one document |
|---|---|---|---|---|---|
| GPU KV cache | GPU memory | about 37,000 tokens (capped) | no | no | none |
| L1 | model server's CPU memory | 7 GB, about 250,000 tokens | no | no | a few ms |
| L2 | tiered storage daemons on the nodes | 1 GiB per node, about 37,000 tokens | yes | yes, also across nodes | tens of ms |

L2 admits data the way a modern cache does: a block written once and not read again soon is evicted early, to protect blocks that are read repeatedly. Run Step 6's benchmark against freshly restarted pods and almost nothing comes back from L2. A prefix that many requests share, such as a long system prompt, a retrieved document, or a tool catalog, is exactly what it keeps. Size L2 for hot prefixes, and keep L1 for the working set of each replica.

## What to take away

- **Tiered KV caching** turns repeated prompt processing into a memory copy. It pays off when requests share long prefixes (system prompts, retrieved documents, multi-turn conversations, agent loops) and when the GPU KV cache is under pressure, which is the normal state for a large model with many concurrent users.
- **Routing** decides whether a cache hit is possible at all once there is more than one replica.
- **Model caching** moves the image pull and the weight download out of the pod's critical path and onto the moment a node joins. On a 3 GB model it barely shows; on a model of tens or hundreds of gigabytes, and when scaling onto fresh nodes, it's the difference between seconds and many minutes.

## Clean up

```bash
kubectl delete inferenceendpointconfig "$ENDPOINT_NAME" -n $NAMESPACE
until ! aws sagemaker describe-endpoint --endpoint-name "$ENDPOINT_NAME" --region $REGION >/dev/null 2>&1; do sleep 10; done
aws sagemaker update-cluster --cluster-name "$HYPERPOD_CLUSTER_NAME" --region $REGION \
  --tiered-storage-config Mode=Disable >/dev/null && echo "tiered storage: disable requested"
```

Disabling tiered storage removes the `ai-toolkit` daemons and returns the 20% of node memory.

## Troubleshooting

- **The endpoint never appears; `kubectl describe inferenceendpointconfig` shows `IntelligentRoutingValidationFailed`.** `invocationEndpoint` isn't one of vLLM's routes. The operator doesn't retry a deployment that failed validation: delete the `InferenceEndpointConfig` and apply it again with `v1/chat/completions`.
- **The Deployment never appears; `kubectl get events -n $NAMESPACE | grep DeploymentCreateFailed` shows `volumeMounts[...].name: Not found: "lmcache-config"`.** The manifest sets `prefetchEnabled` together with the L2 tier. Delete it and apply it again without `prefetchEnabled`.
- **`invoke-endpoint` returns `ModelError` with `missing 'model' in request body`.** The router needs the `model` field: add `"model":"qwen-opt"` to the body.
- **A model pod stays `Pending` with `Insufficient nvidia.com/gpu`, from a newer ReplicaSet.** The Deployment was scaled up before both caches were warm, and the operator's template update is waiting for a free GPU. Scale to zero and back: `kubectl scale deploy/"$ENDPOINT_NAME" -n $NAMESPACE --replicas=0`, wait until the pods are gone, then scale to `$REPLICAS` again.
- **A pod stays `Pending` with `Too many pods`.** The node is at its pod limit. See the pod budget on the overview page.
- **No `LMCache` lines in the model log and `vllm:external_prefix_cache_hits_total` stays at 0.** Check the `vLLM server arguments` line for `--kv-transfer-config`. If it's missing, `SM_VLLM_KV_TRANSFER_CONFIG` is missing or misspelled.
- **Step 8 shows no hit.** Either `PYTHONHASHSEED` isn't set in the model container (the log warns `PYTHONHASHSEED not set`), or the document was evicted from L2 before you came back to it, for example because other runs wrote to L2 in between: run Step 8 again with another `DOC_OFFSET`. Also check that the `ai-toolkit` pod on each GPU node is running.
- **`Loading weights took` several seconds and the pod has no `cache-resolver` init container.** The pod started before the weights cache was warm and read the weights from S3. It still serves; scale to zero and back to pick up the cache.

## Going further

- **Redis as L2.** `l2CacheBackend: redis` with `l2CacheLocalUrl` uses a Redis cluster you run, for example Amazon ElastiCache, instead of the nodes' memory. You size and secure it yourself; keep it in the cluster's VPC. Neither backend encrypts KV data at rest, and managed tiered storage doesn't isolate the deployments of a cluster from each other. See [KV caching and intelligent routing](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-model-deployment-caching-routing.html).
- **Other routing strategies.** `session` keeps a user session on one replica, `roundrobin` ignores the cache, and `kvaware` routes to the replica with the highest measured cache hit rate; `kvaware` needs `invocationEndpoint: v1/completions`. The strategy can be changed on a running deployment with `kubectl patch`; enabling routing can't.
- **Disaggregated prefill and decode** (`pdSpec`) combines with these features for large models.
