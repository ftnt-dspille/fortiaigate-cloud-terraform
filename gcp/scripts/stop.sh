#!/usr/bin/env bash
set -euo pipefail

# Stop the VM(s) -- stops compute billing ($0/hr), keeps disk storage cost only.
# Data and k3s state are preserved. Start again with start.sh.
#
# Usage: stop.sh [vm-name]  (defaults to all VMs from Terraform)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

if [ -n "${1:-}" ]; then
  VM_NAMES="$1"
else
  VM_NAMES=$(terraform -chdir="$TF_DIR" output -json vm_names | python3 -c "import sys,json; [print(v) for v in json.load(sys.stdin)]")
fi

# Running VMs keep a GPU hold (free while they run). KEEP_GPU_HOLD=1 keeps it
# through the stop -- guarantees a start later the same day, billing like a
# running VM while stopped; one is made first if the VM has none. Otherwise the
# holds of the VMs being stopped are released after the stop.
NUMS=$(for VM in $VM_NAMES; do echo "${VM##*-}"; done)
# shellcheck disable=SC2086
[ -n "${KEEP_GPU_HOLD:-}" ] && "$SCRIPT_DIR/gpu_place.sh" --hold $NUMS

for VM in $VM_NAMES; do
  ZONE="$(get_zone "$VM")"
  echo "Stopping: $VM (zone=$ZONE)"
  gcloud compute instances stop "$VM" --zone="$ZONE"
done

echo 'Done. VM compute billing stopped; disk storage still applies (~$2-5/mo per VM).'
# shellcheck disable=SC2086
if [ -n "${KEEP_GPU_HOLD:-}" ]; then
  echo "NOTE: GPU holds kept, billing (~\$0.85/hr each) until the next start -- 'make unreserve' to drop them"
else
  "$SCRIPT_DIR/gpu_place.sh" --release $NUMS
fi
