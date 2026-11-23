#!/usr/bin/env bash
set -euo pipefail

# Copy FAIG tars from the tars source host directly to the cloud VM.
# The source host PUSHES to the cloud VM -- data goes source → cloud VM directly.
# Uses SSH agent forwarding (-A) so the source host authenticates to the cloud
# VM via the laptop's ssh-agent -- no private key ever copied to the source.
#
# The source host need not be publicly reachable as long as it has internet
# egress (e.g. it reaches FortiCare/FDN), so it can initiate outbound to the
# cloud VM's public IP.
#
# Usage: copy_faig_images.sh <cloud-ip> [cloud-user]
#
# Required env vars:
#   FAIG_TARS_HOST  -- an SSH-reachable host that holds the FAIG install tars
#                      (a Fabric Studio pod, a jump host, a server you control...)
#   FAIG_TARS_PORT  -- the SSH port on FAIG_TARS_HOST (e.g. 11001)
#
# Optional env vars:
#   FAIG_TARS_USER  -- SSH user on FAIG_TARS_HOST (default: fortinet)
#   FAIG_TARS_DIR   -- dir on that host with the tars (default: ~/faig-images)
#
# Prereqs:
#   - ssh-agent running with the key that's on the cloud VM (ssh-add -L shows it)
#   - The faig guest can reach the cloud VM's public IP:22 (internet egress)

CLOUD_IP="${1:?Usage: copy_faig_images.sh <cloud-ip> [cloud-user]}"
CLOUD_USER="${2:-azureuser}"

: "${FAIG_TARS_HOST:=${FS_POD_HOST:?Need FAIG_TARS_HOST -- an SSH-reachable host holding the FAIG tars}}"
: "${FAIG_TARS_PORT:=${FS_FAIG_PORT:?Need FAIG_TARS_PORT -- the SSH port on FAIG_TARS_HOST (e.g. 11001)}}"
FAIG_TARS_USER="${FAIG_TARS_USER:-${FS_FAIG_USER:-fortinet}}"
FAIG_TARS_DIR="${FAIG_TARS_DIR:-${FAIG_REMOTE_DIR:-\~/faig-images}}"

# Verify the agent has a key -- without it, the forwarded scp to the cloud VM
# will silently fall back to password auth and hang.
if ! ssh-add -L | grep -q .; then
  echo "ERROR: ssh-agent has no keys. Add the key that's on the cloud VM:"
  echo "  ssh-add ~/.ssh/id_ed25519"
  exit 1
fi

echo "=== Verifying FAIG tars on FS pod ==="
ssh -p "$FAIG_TARS_PORT" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "$FAIG_TARS_USER@$FAIG_TARS_HOST" \
  "ls -lh $FAIG_TARS_DIR/FAIG_*.tar* 2>/dev/null" || {
    echo "No FAIG tars found at $FAIG_TARS_DIR on $FAIG_TARS_HOST."
    echo "Check the path -- REPRODUCE.md puts them at ~/faig-images/"
    exit 1
  }

echo "=== Creating target dir on cloud VM ==="
ssh "$CLOUD_USER@$CLOUD_IP" "mkdir -p ~/faig-images"

echo "=== Pushing FAIG tars: FS pod → cloud VM (agent-forwarded) ==="
# -A forwards the laptop's ssh-agent to the faig guest. The scp from there
# to the cloud VM authenticates through the forwarded agent -- the private
# key never leaves the laptop.
ssh -A -p "$FAIG_TARS_PORT" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "$FAIG_TARS_USER@$FAIG_TARS_HOST" \
  "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    $FAIG_TARS_DIR/FAIG_*.tar* $CLOUD_USER@$CLOUD_IP:~/faig-images/"

echo "=== Verifying ==="
ssh "$CLOUD_USER@$CLOUD_IP" "ls -lh ~/faig-images/FAIG_*.tar*"

echo "Done. FAIG tars are on the cloud VM at ~/faig-images/"
