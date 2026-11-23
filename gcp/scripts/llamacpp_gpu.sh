#!/usr/bin/env bash
set -euo pipefail

# llamacpp_gpu.sh -- run the workshop model (llama.cpp, provider local-llamacpp)
# on the L4 instead of the CPU. Idempotent; ready.sh calls it on every `make up`.
#
# Measured on faig-1 (Llama-3.2-1B Q4_K_M, 200-token answers): CPU 30 tok/s alone
# and 14.6 tok/s each with 4 at once (13.7s for the 4); GPU 229 and 164 tok/s
# (1.3s for the 4). On the CPU it also fought FAIG's own pods for the 8 vCPUs.
#
# It does NOT request nvidia.com/gpu: triton-server holds the node's only one,
# so a request would leave the pod Pending (the faig_seed llamacpp role's GPU
# mode does that). Like vllm-server, it reaches the GPU through the nvidia
# runtime + NVIDIA_VISIBLE_DEVICES instead. It needs ~1.2 GB (1B) to ~3 GB (Qwen2.5-3B) beside
# vLLM's share (capped at 70% by vllm_gpu_budget.sh) and triton's ~3 GB; with less than MIN_FREE_MIB free it stays on the CPU.
#
# Usage: llamacpp_gpu.sh [vm-name]      Undo on the VM: kubectl -n llamacpp rollout undo deploy/llamacpp

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
ZONE="$(get_zone "$VM_NAME")"
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
# Pinned: the moving `server-cuda` tag could pull a build that needs a newer
# CUDA than the VM's driver (550 = CUDA 12.4). b11515 is the measured build.
IMAGE="${LLAMACPP_GPU_IMAGE:-ghcr.io/ggml-org/llama.cpp:server-cuda-b11515}"
MIN_FREE_MIB="${MIN_FREE_MIB:-1500}"

gcloud compute ssh --tunnel-through-iap --zone="$ZONE" --project="$PROJECT" "$VM_NAME" \
  --command="IMAGE='$IMAGE' MIN_FREE_MIB='$MIN_FREE_MIB' bash -s" << 'REMOTE'
set -euo pipefail
k() { sudo k3s kubectl -n llamacpp "$@"; }
spec() { k get deploy llamacpp -o jsonpath="$1"; }

# Target the llama-server container by NAME: the pod also carries the llama-proxy
# (nginx) sidecar, and llama-proxy is containers[0], so a hardcoded index 0 would
# patch the proxy (and its args-less container makes "add /args/-" a 422).
IDX=$(spec '{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' |
      grep -n '^llama-server$' | head -1 | cut -d: -f1) || true
IDX=$(( ${IDX:-0} - 1 ))
[ "$IDX" -ge 0 ] || { echo "  ERROR: no llama-server container in deploy/llamacpp" >&2; exit 1; }
# Two spellings: jsonpath wants containers[$IDX]; JSON Patch paths want containers/$IDX.
JP="containers[$IDX]"
C="containers/$IDX"

if [ "$(spec "{.spec.template.spec.$JP.image}")" = "$IMAGE" ] &&
   [ "$(spec '{.spec.template.spec.runtimeClassName}')" = "nvidia" ]; then
  echo "  workshop model already on the GPU ($IMAGE)"
  exit 0
fi

# What llama-server holds now comes back when its pod is replaced, so it counts
# as free (it's already on the GPU when only the image tag is being changed).
free=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1)
mine=$(nvidia-smi --query-compute-apps=process_name,used_memory --format=csv,noheader,nounits |
  awk -F', ' '/llama-server/ {s += $2} END {print s + 0}')
if [ $(( ${free:-0} + mine )) -lt "$MIN_FREE_MIB" ]; then
  echo "  WARNING: only $(( ${free:-0} + mine )) MiB GPU free (< $MIN_FREE_MIB): workshop model left as it is"
  exit 0
fi

patch='[{"op":"replace","path":"/spec/template/spec/'"$C"'/image","value":"'"$IMAGE"'"},
 {"op":"add","path":"/spec/template/spec/runtimeClassName","value":"nvidia"},
 {"op":"add","path":"/spec/template/spec/'"$C"'/env","value":[
   {"name":"NVIDIA_VISIBLE_DEVICES","value":"all"},
   {"name":"NVIDIA_DRIVER_CAPABILITIES","value":"compute,utility"}]}'
# Append the offload flag once, even if an earlier run got this far.
if ! spec "{.spec.template.spec.$JP.args}" | grep -q -- '--n-gpu-layers'; then
  patch="$patch"',{"op":"add","path":"/spec/template/spec/'"$C"'/args/-","value":"--n-gpu-layers"},
 {"op":"add","path":"/spec/template/spec/'"$C"'/args/-","value":"999"}'
fi
echo "  moving the workshop model to the GPU ($IMAGE; first pull ~2.6 GB)..."
k patch deploy llamacpp --type=json -p="$patch]"
k rollout status deploy/llamacpp --timeout=900s
nvidia-smi --query-compute-apps=process_name,used_memory --format=csv,noheader | grep llama-server ||
  { echo "  ERROR: llama-server is not on the GPU" >&2; exit 1; }
REMOTE
