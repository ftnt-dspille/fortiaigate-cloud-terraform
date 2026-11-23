#!/usr/bin/env bash
set -euo pipefail

# Copy the FAIG install tars onto the GCP build VM.
#
# Two sources, picked automatically (local wins when it has tars):
#
#   1. LOCAL  -- the tars sit in $FAIG_TARS_DIR on this laptop (default: the
#                repo's faig-images/ dir). They are pushed up through the IAP
#                tunnel. This is the usual path: download the tars, drop them
#                in faig-images/, run make build.
#   2. REMOTE -- $FAIG_TARS_HOST points at an SSH-reachable host that holds
#                the tars (a Fabric Studio pod, a jump host, a server you
#                control). They relay: source host → laptop IAP tunnel → VM,
#                with agent forwarding authenticating the last hop.
#
# VMs have no public IPs (IAP-only), so every path goes through the IAP tunnel.
#
# Usage: copy_faig_images.sh [vm-name]
#
# Env vars:
#   FAIG_TARS_DIR   -- LOCAL mode: local dir with the tars
#                      (default: <repo>/faig-images)
#                      REMOTE mode: dir on the remote host
#                      (default: ~/faig-images-8.0.2)
#   FAIG_TARS_HOST  -- remote host holding the tars (selects REMOTE mode;
#                      legacy FS_POD_HOST also works)
#   FAIG_TARS_PORT  -- SSH port on FAIG_TARS_HOST (e.g. 11001)
#   FAIG_TARS_USER  -- SSH user on FAIG_TARS_HOST (default: fortinet)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
ZONE="$(get_zone)"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# ── Resolve the source ───────────────────────────────────────────────────────
LOCAL_TARS_DIR="${FAIG_TARS_DIR:-$REPO_ROOT/faig-images}"
if ls "$LOCAL_TARS_DIR"/FAIG_*.tar* >/dev/null 2>&1; then
  MODE=local
elif [ -n "${FAIG_TARS_HOST:-${FS_POD_HOST:-}}" ]; then
  MODE=remote
  : "${FAIG_TARS_HOST:=${FS_POD_HOST:?Need FAIG_TARS_HOST -- an SSH-reachable host holding the FAIG tars}}"
  : "${FAIG_TARS_PORT:=${FS_FAIG_PORT:?Need FAIG_TARS_PORT -- the SSH port on FAIG_TARS_HOST (e.g. 11001)}}"
  FAIG_TARS_USER="${FAIG_TARS_USER:-${FS_FAIG_USER:-fortinet}}"
  FAIG_TARS_DIR="${FAIG_TARS_DIR:-${FAIG_REMOTE_DIR:-~/faig-images-8.0.2}}"
else
  echo "ERROR: no FAIG tars in $LOCAL_TARS_DIR and FAIG_TARS_HOST is not set." >&2
  echo "  Put the FAIG_*.tar* files in $LOCAL_TARS_DIR (gitignored -- see" >&2
  echo "  faig-images/README.md), or point FAIG_TARS_HOST/FAIG_TARS_PORT at a" >&2
  echo "  host that has them. See the root README, Prerequisites." >&2
  exit 1
fi

# Total size of the tars (KB), for the VM disk check below.
if [ "$MODE" = local ]; then
  TAR_KB=$(cd "$LOCAL_TARS_DIR" && wc -c FAIG_*.tar* | tail -1 | awk '{print int($1 / 1024)}')
else
  TAR_KB=$(ssh -p "$FAIG_TARS_PORT" $SSH_OPTS \
    "$FAIG_TARS_USER@$FAIG_TARS_HOST" \
    "cd $FAIG_TARS_DIR && wc -c FAIG_*.tar* 2>/dev/null | tail -1" | awk '{print int($1 / 1024)}' || echo 0)
fi

# The agent matters only for REMOTE mode: the relay's last hop authenticates
# via the laptop's forwarded agent. LOCAL mode scp authenticates with the
# default key file, so no agent is needed there.
if [ "$MODE" = remote ] && ! ssh-add -L | grep -q .; then
  echo "ERROR: ssh-agent has no keys. Run: ssh-add ~/.ssh/id_ed25519"
  exit 1
fi

echo "=== Starting IAP tunnel to $VM_NAME ==="
iap_start_ssh "$VM_NAME" "$ZONE"
trap iap_cleanup EXIT

echo "=== Creating ~/faig-images on the VM + checking free disk ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" "mkdir -p ~/faig-images"
FREE_KB=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
  "df -Pk \$HOME/faig-images | awk 'NR==2{print \$4}'")
if [ "${TAR_KB:-0}" -gt 0 ] && [ "${FREE_KB:-0}" -gt 0 ] && [ "$FREE_KB" -lt "$TAR_KB" ]; then
  echo "ERROR: the VM has ~$((FREE_KB / 1024 / 1024)) GB free under ~/faig-images," >&2
  echo "  but the tars are ~$((TAR_KB / 1024 / 1024)) GB. Grow the boot disk" >&2
  echo "  (disk_size_gb) or clear space, then re-run." >&2
  exit 1
fi

if [ "$MODE" = local ]; then
  echo "=== Pushing local tars (${TAR_KB} KB): laptop → IAP tunnel → $VM_NAME ==="
  scp -P "$SSH_PORT" $SSH_OPTS \
    "$LOCAL_TARS_DIR"/FAIG_*.tar* "$SSH_TARGET:~/faig-images/"
else
  echo "=== Verifying FAIG tars on $FAIG_TARS_HOST ==="
  ssh -p "$FAIG_TARS_PORT" $SSH_OPTS \
    "$FAIG_TARS_USER@$FAIG_TARS_HOST" \
    "ls -lh $FAIG_TARS_DIR/FAIG_*.tar* 2>/dev/null" || {
      echo "No FAIG tars found at $FAIG_TARS_DIR on $FAIG_TARS_HOST."
      exit 1
    }

  echo "=== Pushing FAIG tars: $FAIG_TARS_HOST → IAP tunnel → $VM_NAME ==="
  # Reverse tunnel: source host port 2222 → laptop SSH_PORT (IAP tunnel) → VM:22.
  # Agent forwarding (-A) lets the source host authenticate to the VM via the
  # laptop's key -- no private key ever copied to the source host.
  ssh -A -R 2222:localhost:"$SSH_PORT" -p "$FAIG_TARS_PORT" $SSH_OPTS \
    "$FAIG_TARS_USER@$FAIG_TARS_HOST" \
    "cd $FAIG_TARS_DIR && \
     scp -P 2222 $SSH_OPTS FAIG_*.tar* $SSH_TARGET:~/faig-images/"
fi

echo "=== Verifying ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" "ls -lh ~/faig-images/FAIG_*.tar*"

echo "Done. FAIG tars are on $VM_NAME at ~/faig-images/"
