#!/usr/bin/env bash
set -euo pipefail

# vllm_gpu_budget.sh -- cap vLLM's GPU share so the Qwen workshop model fits beside it.
# Idempotent; ready.sh calls it on every `make up`, before llamacpp_gpu.sh.
#
# The FAIG chart starts vllm-server (the policyguard model) with
# --gpu-memory-utilization=0.80: a fixed 17.6 GiB of the L4's 22. Triton holds ~2.3 GiB
# and llama.cpp needs ~3 GiB for Qwen2.5-3B (the 1B needed ~1.2), so 0.80 + both no
# longer fits. vLLM then refuses to start ("Free memory ... is less than desired GPU
# memory utilization"), crash-loops, and guardrail scanning stays off while traffic
# passes unscanned.
#
# At 0.70 (15.4 GiB) all three fit with ~1 GiB spare. The policyguard weights are 13.8 GiB,
# so the cost is KV cache: ~2.3 GiB at 0.80 -> ~0.7 GiB at 0.70 (24.8k tokens, 1.5x
# concurrency at the 16k max length). Short scans are unaffected; many long prompts at
# once queue instead of running in parallel (measured: 64 x 1k-token and 32 x 3k-token
# concurrent requests, 0 errors, no preemption).
#
# The Helm chart owns this deployment, so a `helm upgrade` / deploy_gpu.sh puts 0.80 back;
# ready.sh re-applies it on the next `make up`.
#
# Usage: vllm_gpu_budget.sh [vm-name]      Undo on the VM: kubectl -n fortiaigate rollout undo deploy/vllm-server
#        VLLM_GPU_UTIL=0.75 vllm_gpu_budget.sh   (default 0.70)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
ZONE="$(get_zone "$VM_NAME")"
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
UTIL="${VLLM_GPU_UTIL:-0.70}"

gcloud compute ssh --tunnel-through-iap --zone="$ZONE" --project="$PROJECT" "$VM_NAME" \
  --command="UTIL='$UTIL' bash -s" << 'REMOTE'
set -euo pipefail
k() { sudo k3s kubectl -n fortiaigate "$@"; }
want="--gpu-memory-utilization=$UTIL"
args=$(k get deploy vllm-server -o jsonpath='{.spec.template.spec.containers[0].args}')
if [ -z "$args" ]; then echo "  no vllm-server deployment: nothing to cap"; exit 0; fi
if echo "$args" | grep -q -- "\"$want\""; then
  echo "  vLLM already capped ($want)"
  exit 0
fi
idx=$(k get deploy vllm-server -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}' |
  grep -n -- '^--gpu-memory-utilization=' | head -1 | cut -d: -f1)
[ -n "$idx" ] || { echo "  ERROR: vllm-server has no --gpu-memory-utilization arg to change" >&2; exit 1; }
echo "  capping vLLM at $want (was: $(echo "$args" | grep -o 'gpu-memory-utilization=[0-9.]*'))..."
# Scale to zero first: a rolling update's surge pod cannot schedule beside the old one
# (the node is out of CPU requests), so it would sit Pending forever.
replicas=$(k get deploy vllm-server -o jsonpath='{.spec.replicas}')
k scale deploy vllm-server --replicas=0
k wait --for=delete pod -l app=vllm-server --timeout=120s || true
k patch deploy vllm-server --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/$((idx - 1))\",\"value\":\"$want\"}]"
k scale deploy vllm-server --replicas="${replicas:-1}"
k rollout status deploy/vllm-server --timeout=600s
REMOTE
