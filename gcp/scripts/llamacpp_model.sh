#!/usr/bin/env bash
set -euo pipefail

# llamacpp_model.sh -- make llama.cpp serve the workshop model (default Qwen2.5-3B-Instruct
# Q4_K_M). Idempotent; ready.sh calls it on every `make up`, before llamacpp_gpu.sh.
#
# Why: the VM image ships the Llama-3.2-1B file and its deployment, and deploy_gpu.sh runs
# the faig_seed playbook only for certificates, so the llamacpp role's Qwen default never
# reached a rebuilt VM. faig-1 rebuilt on 2026-11-06 came up on the 1B, which writes broken
# tool calls; one of those started the 2026-11-11 class outage (see llamacpp_proxy.sh).
# Qwen2.5-3B measured 91% vs 78% quality and 12/12 `faig scenarios` on the same harness.
# It downloads the GGUF onto the model volume if missing (the 1B stays, for rollback),
# It downloads the GGUF onto the model volume if missing (the 1B stays, for rollback),
# points llama-server's --model at it, and waits for the model to load. If the pod does not
# come back healthy it rolls the deployment back. The served alias (llama3.2:1b) is unchanged,
# so keys, guardrails and the lab guide need nothing.
#
# The pod uses the Recreate strategy: the model is offline for the restart (about a minute).
#
# Usage: llamacpp_model.sh [vm-name]
#   LLAMACPP_MODEL_URL=<gguf url>   serve another model (e.g. the 1B URL to roll back)
#   Undo on the VM: kubectl -n llamacpp rollout undo deploy/llamacpp

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
ZONE="$(get_zone "$VM_NAME")"
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
MODEL_URL="${LLAMACPP_MODEL_URL:-https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf}"

gcloud compute ssh --tunnel-through-iap --zone="$ZONE" --project="$PROJECT" "$VM_NAME" \
  --command="MODEL_URL='$MODEL_URL' bash -s" << 'REMOTE'
set -euo pipefail
k() { sudo k3s kubectl -n llamacpp "$@"; }
FILE="$(basename "${MODEL_URL%%\?*}")"

# llama-server is found by NAME: the pod also carries the llama-proxy sidecar.
IDX=$(k get deploy llamacpp -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' |
      grep -n '^llama-server$' | head -1 | cut -d: -f1) || true
IDX=$(( ${IDX:-0} - 1 ))
[ "$IDX" -ge 0 ] || { echo "  ERROR: no llama-server container in deploy/llamacpp" >&2; exit 1; }
ARGS=$(k get deploy llamacpp -o jsonpath="{.spec.template.spec.containers[$IDX].args}")
# position of the value after --model
POS=$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); print(a.index("--model")+1)' "$ARGS")
CUR=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[int(sys.argv[2])])' "$ARGS" "$POS")
if [ "$CUR" = "/models/$FILE" ]; then
  echo "  workshop model already $FILE"
  exit 0
fi

# The models PVC is a local-path volume: download straight into its host directory.
PV=$(k get pvc llamacpp-models-pvc -o jsonpath='{.spec.volumeName}')
DIR=$(sudo k3s kubectl get pv "$PV" -o jsonpath='{.spec.local.path}{.spec.hostPath.path}')
[ -d "$DIR" ] || { echo "  ERROR: model volume dir '$DIR' not found" >&2; exit 1; }
if [ ! -s "$DIR/$FILE" ]; then
  echo "  downloading $FILE (~2 GB) into $DIR ..."
  sudo curl -fL --retry 5 --retry-delay 10 -C - -o "$DIR/$FILE.part" "$MODEL_URL"
  [ "$(sudo head -c 4 "$DIR/$FILE.part")" = "GGUF" ] || { echo "  ERROR: not a GGUF file" >&2; exit 1; }
  sudo mv "$DIR/$FILE.part" "$DIR/$FILE"
fi

echo "  switching llama-server from $CUR to /models/$FILE (model offline ~1 min)..."
k patch deploy llamacpp --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/'"$IDX"'/args/'"$POS"'","value":"/models/'"$FILE"'"}]'
if ! k rollout status deploy/llamacpp --timeout=420s; then
  echo "  ERROR: llama.cpp did not come up on $FILE -- rolling back" >&2
  k rollout undo deploy/llamacpp
  k rollout status deploy/llamacpp --timeout=420s || true
  exit 1
fi
POD=$(k get pod -l app=llamacpp -o jsonpath='{.items[0].metadata.name}')
for _ in $(seq 1 60); do
  k exec "$POD" -c llama-proxy -- wget -qO- http://127.0.0.1:8080/health 2>/dev/null | grep -q ok && break
  sleep 5
done
k exec "$POD" -c llama-proxy -- wget -qO- http://127.0.0.1:8080/props 2>/dev/null |
  grep -o '"model_path":"[^"]*"' || { echo "  ERROR: model did not load" >&2; exit 1; }
echo "  workshop model now $FILE"
REMOTE
