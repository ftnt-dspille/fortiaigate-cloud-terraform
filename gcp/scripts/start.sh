#!/usr/bin/env bash
set -euo pipefail

# Start stopped VM(s), then bring FortiAIGate back to a scanning state.
#
# Usage: start.sh [vm-name]  (defaults to all VMs from Terraform)
#
# WHY THE HEAL STEP. Every stop/start leaves the previous boot's engine pods
# behind: a triton-server that lost the GPU at admission (UnexpectedAdmissionError)
# or one stuck in Unknown. k3s has already started a healthy replacement, but the
# license-manager keeps polling the dead one, and after 5 unanswered reads it logs
# "security scanning is disabled ... Traffic continues to pass, unscanned".
# Nothing looks down -- the gateway answers -- yet no guardrail runs. So after
# the start: wait for IAP SSH, delete dead pods until every pod is Running, and
# wait for the license-manager to log "scanning enabled".

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

if [ -n "${1:-}" ]; then
  VM_NAMES="$1"
else
  VM_NAMES=$(terraform -chdir="$TF_DIR" output -json vm_names | python3 -c "import sys,json; [print(v) for v in json.load(sys.stdin)]")
fi

# WAIT_MIN: how long to wait for pods + scanning. A freshly deployed VM builds
# triton's TensorRT engines on first boot (the cache is not in the image), which
# takes well over the 10 min a plain restart needs; ready.sh passes more.
WAIT_MIN="${WAIT_MIN:-10}"

for VM in $VM_NAMES; do
  ZONE="$(get_zone "$VM")"
  if [ "$(gcloud compute instances describe "$VM" --zone="$ZONE" --format='value(status)' 2>/dev/null)" = RUNNING ]; then
    echo "Already running: $VM"
  else
    echo "Starting: $VM (zone=$ZONE)"
    gcloud compute instances start "$VM" --zone="$ZONE"
  fi
done

for VM in $VM_NAMES; do
  ZONE="$(get_zone "$VM")"
  echo "=== $VM: waiting for SSH (IAP takes a minute or two to see a fresh boot) ==="
  for i in $(seq 1 30); do
    gcloud compute ssh --tunnel-through-iap --zone="$ZONE" "$VM" --command=true >/dev/null 2>&1 && break
    [ "$i" -eq 30 ] && { echo "ERROR: no SSH to $VM after 5 min"; exit 1; }
    sleep 10
  done
  echo "=== $VM: clearing dead pods, waiting for pods + scanning (up to $WAIT_MIN min) ==="
  gcloud compute ssh --tunnel-through-iap --zone="$ZONE" "$VM" --command="WAIT_MIN=$WAIT_MIN bash -s" 2>/dev/null << 'REMOTE'
k() { sudo k3s kubectl --request-timeout=10s "$@"; }
# A VM rebuilt or moved keeps the old VM's k3s node-ip: its API never answers, so
# nothing here can get ready. ready.sh 1b redeploys k3s for this IP; hand over now
# instead of burning the whole wait on API timeouts.
ip=$(hostname -I | cut -d" " -f1)
if ! grep -q "node-ip: \"$ip\"" /etc/rancher/k3s/config.yaml 2>/dev/null; then
  echo "  k3s still has another VM's node-ip (this VM is $ip): skipping the wait, ready.sh redeploys k3s"
  exit 0
fi
for i in $(seq 1 $((WAIT_MIN * 4))); do
  k get pods -n fortiaigate --no-headers 2>/dev/null |
    awk '$3 ~ /AdmissionError|Unknown|Evicted|^Error$/ {print $1}' | while read -r pod; do
      echo "  deleting dead pod $pod"
      k delete pod -n fortiaigate "$pod" --force --grace-period=0 >/dev/null 2>&1 || true
    done
  # Not ready = READY count < total (e.g. 0/1) or STATUS not Running/Completed.
  # Never match on a hardcoded 1/1: multi-container pods (llamacpp is 2/2 with the
  # llama-proxy sidecar) are healthy but would fail a "1/1" match forever.
  NOT_READY=$( { k get pods -n fortiaigate --no-headers; k get pods -n llamacpp --no-headers; } 2>/dev/null |
               awk '{ split($2, r, "/"); if (r[1] != r[2] || ($3 != "Running" && $3 != "Completed")) print }' || true)
  SCAN=$(k logs -n fortiaigate -l app=license-manager --tail=200 2>/dev/null |
         { grep -E "scanning enabled|security scanning is disabled|NO USABLE LICENCE" || true; } | sort | tail -1)
  if [ -z "$NOT_READY" ] && echo "$SCAN" | grep -q "scanning enabled"; then
    echo "  all pods Running; guardrail scanning enabled"
    exit 0
  fi
  [ $((i % 4)) -eq 0 ] && echo "  [$((i / 4)) min] waiting: $(echo "$NOT_READY" | awk '{print $1}' | tr '\n' ' ')${SCAN:+| $(echo "$SCAN" | grep -oE 'scanning [a-z]+|NO USABLE LICENCE' | head -1)}"
  sleep 15
done
echo "TIMEOUT: pods or scanning not ready after $WAIT_MIN min"
k get pods -n fortiaigate
echo "last licence line: ${SCAN:-none}"
exit 1
REMOTE
done

echo "Done. FortiAIGate is up and scanning. Check it end to end with: make test"
