#!/usr/bin/env bash
set -uo pipefail

# Which zones can run the GPU profile right now? Diagnostic only: `make up` /
# `make place` (gpu_place.sh) already pick and HOLD a zone on their own.
#
# Usage: gpu_zones.sh [region-prefix] [--probe]
#   region-prefix  zones to look at (default: us-); e.g. us-central1, us-east, europe-
#   --probe        also test live capacity in each zone (see below)
#
# Without --probe it lists the zones that OFFER the GPU and the regional GPU quota.
# Offered is not in stock: GCP has no read-only capacity API. --probe asks the only
# way GCP answers -- it creates a one-VM reservation of the exact gpu.tfvars shape
# (machine type + accelerator) and deletes it at once. A reservation needs no
# network or disk and bills only for the seconds it exists. A pass is a snapshot:
# capacity can go between the probe and the deploy.
#
# Staying in the current region keeps the static IP (it is regional); another
# region means a new FAIG address in every lab vars file and the pod allowlist.

cd "$(dirname "$0")/.."
PREFIX="us-"
PROBE=0
for a in "$@"; do
  case "$a" in
    --probe) PROBE=1 ;;
    *) PREFIX="$a" ;;
  esac
done

tfvar() { sed -nE "s/^$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$2" 2>/dev/null | head -1; }
PROJECT=$(tfvar project_id terraform.tfvars)
PROJECT=${PROJECT:-$(gcloud config get-value project 2>/dev/null)}
MACHINE=$(tfvar machine_type gpu.tfvars)
GPU=$(tfvar gpu_type gpu.tfvars)
ZONE_NOW=$(tfvar zone gpu.tfvars)
REGION_NOW=$(tfvar region gpu.tfvars)
REGION_NOW=${REGION_NOW:-$(tfvar region terraform.tfvars)}
REGION_NOW=${REGION_NOW:-us-central1}
: "${MACHINE:?machine_type missing from gpu.tfvars}" "${GPU:?gpu_type missing from gpu.tfvars}"
# Quota metric for the accelerator: nvidia-l4 -> NVIDIA_L4_GPUS
QUOTA_METRIC="$(echo "${GPU#nvidia-}" | tr '[:lower:]-' '[:upper:]_')"
QUOTA_METRIC="NVIDIA_${QUOTA_METRIC}_GPUS"

echo "=== $MACHINE + 1x $GPU in zones matching '$PREFIX*' (project $PROJECT) ==="
echo "    gpu.tfvars now: zone=${ZONE_NOW:-<default>}  region=$REGION_NOW (the static IP lives here)"
ZONES=$(gcloud compute accelerator-types list --project "$PROJECT" \
  --filter="name=$GPU AND zone~zones/$PREFIX" --format='value(zone.basename())' 2>/dev/null | sort)
if [ -z "$ZONES" ]; then
  echo "no zone matching '$PREFIX*' offers $GPU"
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Regional quota, once per region (files, not an assoc array: macOS bash is 3.2).
for r in $(echo "$ZONES" | sed -E 's/-[a-z]$//' | sort -u); do
  gcloud compute regions describe "$r" --project "$PROJECT" --format=json 2>/dev/null |
    python3 -c "import sys,json
q=[x for x in json.load(sys.stdin).get('quotas',[]) if x['metric']=='$QUOTA_METRIC']
print(f\"{int(q[0]['usage'])}/{int(q[0]['limit'])}\" if q else 'n/a')" 2>/dev/null > "$TMP/quota-$r" || echo "?" > "$TMP/quota-$r"
done

probe() {
  local z=$1 name="faig-probe-$1-$$" out
  out=$(gcloud compute reservations create "$name" --project "$PROJECT" --zone "$z" \
        --vm-count 1 --machine-type "$MACHINE" --accelerator "count=1,type=$GPU" 2>&1)
  if [ $? -eq 0 ]; then
    gcloud compute reservations delete "$name" --project "$PROJECT" --zone "$z" --quiet >/dev/null 2>&1 ||
      echo "WARNING: reservation $name in $z was NOT deleted -- delete it by hand (it bills like a running VM)" >&2
    echo "AVAILABLE"
  elif echo "$out" | grep -qiE 'STOCKOUT|RESOURCE_POOL_EXHAUSTED|enough resources'; then
    echo "STOCKOUT"
  elif echo "$out" | grep -qi 'quota'; then
    echo "NO-QUOTA"
  else
    echo "ERROR: $(echo "$out" | grep -m1 -iE 'error|invalid' | cut -c1-90)"
  fi
}

if [ "$PROBE" = 1 ]; then
  echo "    probing capacity (a throwaway reservation per zone, deleted immediately)..."
  for z in $ZONES; do probe "$z" > "$TMP/$z" & done
  wait
fi

printf '\n%-26s %-16s %-10s %s\n' ZONE REGION-QUOTA CAPACITY NOTE
for z in $ZONES; do
  r=${z%-*}
  cap="-"; [ "$PROBE" = 1 ] && cap=$(cat "$TMP/$z")
  note=""
  [ "$z" = "$ZONE_NOW" ] && note="<- gpu.tfvars zone"
  [ "$r" = "$REGION_NOW" ] && [ -z "$note" ] && note="same region: keeps the IP"
  printf '%-26s %-16s %-10s %s\n' "$z" "used/limit $(cat "$TMP/quota-$r")" "$cap" "$note"
done

echo
if [ "$PROBE" = 1 ]; then
  pick=$(for z in $ZONES; do [ "$(cat "$TMP/$z")" = AVAILABLE ] && echo "$z"; done)
  same=$(echo "$pick" | grep "^$REGION_NOW-" | head -1)
  if [ -n "$same" ]; then
    echo "Capacity in $REGION_NOW ($same). make up places on its own -- no tfvars edit needed."
  elif [ -n "$pick" ]; then
    echo "Nothing in $REGION_NOW. Available elsewhere: $(echo $pick)"
    echo "make up places on its own (new region = new static IP; the DNS name follows it)."
  else
    echo "No zone matching '$PREFIX*' has capacity right now -- retry later or widen the prefix."
  fi
else
  echo "Offered is not in stock -- add PROBE=1 (make gpu-zones PROBE=1) to test live capacity."
fi
