#!/usr/bin/env bash
set -euo pipefail

# Copy FAIG tars to the GCP build VM via IAP tunnel.
# VMs have no public IPs, so we relay: source host → laptop IAP tunnel → GCP VM.
#
# Usage: copy_faig_images.sh [vm-name]
#
# Required env vars:
#   FAIG_TARS_HOST  -- an SSH-reachable host that holds the FAIG install tars
#                      (a Fabric Studio pod, a jump host, a server you control...)
#   FAIG_TARS_PORT  -- the SSH port on FAIG_TARS_HOST (e.g. 11001)
#
# Optional env vars:
#   FAIG_TARS_USER  -- SSH user on FAIG_TARS_HOST (default: fortinet)
#   FAIG_TARS_DIR   -- dir on that host with the tars (default: ~/faig-images-8.0.2)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
ZONE="$(get_zone)"

: "${FAIG_TARS_HOST:=${FS_POD_HOST:?Need FAIG_TARS_HOST -- an SSH-reachable host holding the FAIG tars}}"
: "${FAIG_TARS_PORT:=${FS_FAIG_PORT:?Need FAIG_TARS_PORT -- the SSH port on FAIG_TARS_HOST (e.g. 11001)}}"
FAIG_TARS_USER="${FAIG_TARS_USER:-${FS_FAIG_USER:-fortinet}}"
FAIG_TARS_DIR="${FAIG_TARS_DIR:-${FAIG_REMOTE_DIR:-~/faig-images-8.0.2}}"

if ! ssh-add -L | grep -q .; then
  echo "ERROR: ssh-agent has no keys. Run: ssh-add ~/.ssh/id_ed25519"
  exit 1
fi

echo "=== Starting IAP tunnel to $VM_NAME ==="
iap_start_ssh "$VM_NAME" "$ZONE"
trap iap_cleanup EXIT

echo "=== Verifying FAIG tars on FS pod ==="
ssh -p "$FAIG_TARS_PORT" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "$FAIG_TARS_USER@$FAIG_TARS_HOST" \
  "ls -lh $FAIG_TARS_DIR/FAIG_*.tar* 2>/dev/null" || {
    echo "No FAIG tars found at $FAIG_TARS_DIR on $FAIG_TARS_HOST."
    exit 1
  }

echo "=== Creating target dir on cloud VM ==="
ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$SSH_TARGET" "mkdir -p ~/faig-images"

echo "=== Pushing FAIG tars: FS pod → IAP tunnel → cloud VM ==="
# Reverse tunnel: FS pod port 2222 → laptop SSH_PORT (IAP tunnel) → GCP VM:22
# Agent forwarding (-A) lets FS pod authenticate to GCP VM via laptop's key
ssh -A -R 2222:localhost:"$SSH_PORT" -p "$FAIG_TARS_PORT" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "$FAIG_TARS_USER@$FAIG_TARS_HOST" \
  "cd $FAIG_TARS_DIR && \
   scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     FAIG_*.tar* $SSH_TARGET:~/faig-images/"

echo "=== Verifying ==="
ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$SSH_TARGET" "ls -lh ~/faig-images/FAIG_*.tar*"

echo "Done. FAIG tars are on $VM_NAME at ~/faig-images/"
