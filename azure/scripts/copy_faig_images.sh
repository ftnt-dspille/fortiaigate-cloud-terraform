#!/usr/bin/env bash
set -euo pipefail

# Copy the FAIG install tars onto the Azure cloud VM.
#
# Two sources, picked automatically (local wins when it has tars):
#
#   1. LOCAL  -- the tars sit in $FAIG_TARS_DIR on this laptop (default: the
#                repo's faig-images/ dir). They are scp'd straight to the VM's
#                public IP. This is the usual path: download the tars, drop
#                them in faig-images/, run make build.
#   2. REMOTE -- $FAIG_TARS_HOST points at an SSH-reachable host that holds
#                the tars. The source host PUSHES to the cloud VM directly --
#                data goes source → cloud VM, so the source needs internet
#                egress (it reaches FortiCare/FDN), not reachability from the
#                VM. Agent forwarding (-A) authenticates that hop via the
#                laptop's key -- no private key ever copied to the source.
#
# Usage: copy_faig_images.sh <cloud-ip> [cloud-user]
#
# Env vars:
#   FAIG_TARS_DIR   -- LOCAL mode: local dir with the tars
#                      (default: <repo>/faig-images)
#                      REMOTE mode: dir on the remote host (default: ~/faig-images)
#   FAIG_TARS_HOST  -- remote host holding the tars (selects REMOTE mode;
#                      legacy FS_POD_HOST also works)
#   FAIG_TARS_PORT  -- SSH port on FAIG_TARS_HOST (e.g. 11001)
#   FAIG_TARS_USER  -- SSH user on FAIG_TARS_HOST (default: fortinet)
#
# Prereqs:
#   - ssh-agent running with the key that's on the cloud VM (ssh-add -L shows it)
#   - LOCAL mode: nothing else. REMOTE mode: the source host can reach the
#     cloud VM's public IP:22 (internet egress).

CLOUD_IP="${1:?Usage: copy_faig_images.sh <cloud-ip> [cloud-user]}"
CLOUD_USER="${2:-azureuser}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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
  FAIG_TARS_DIR="${FAIG_TARS_DIR:-${FAIG_REMOTE_DIR:-~/faig-images}}"
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

# Verify the agent has a key -- without it, the scp to the cloud VM will
# silently fall back to password auth and hang. LOCAL mode uses the default
# key file directly and skips this check (see gcp/scripts/copy_faig_images.sh).
if [ "$MODE" = remote ] && ! ssh-add -L | grep -q .; then
  echo "ERROR: ssh-agent has no keys. Add the key that's on the cloud VM:"
  echo "  ssh-add ~/.ssh/id_ed25519"
  exit 1
fi

echo "=== Creating ~/faig-images on the cloud VM + checking free disk ==="
ssh $SSH_OPTS "$CLOUD_USER@$CLOUD_IP" "mkdir -p ~/faig-images"
FREE_KB=$(ssh $SSH_OPTS "$CLOUD_USER@$CLOUD_IP" \
  "df -Pk \$HOME/faig-images | awk 'NR==2{print \$4}'")
if [ "${TAR_KB:-0}" -gt 0 ] && [ "${FREE_KB:-0}" -gt 0 ] && [ "$FREE_KB" -lt "$TAR_KB" ]; then
  echo "ERROR: the VM has ~$((FREE_KB / 1024 / 1024)) GB free under ~/faig-images," >&2
  echo "  but the tars are ~$((TAR_KB / 1024 / 1024)) GB. Grow the OS disk" >&2
  echo "  (disk_size_gb) or clear space, then re-run." >&2
  exit 1
fi

if [ "$MODE" = local ]; then
  echo "=== Pushing local tars (${TAR_KB} KB): laptop → $CLOUD_IP ==="
  scp $SSH_OPTS "$LOCAL_TARS_DIR"/FAIG_*.tar* "$CLOUD_USER@$CLOUD_IP:~/faig-images/"
else
  echo "=== Verifying FAIG tars on $FAIG_TARS_HOST ==="
  ssh -p "$FAIG_TARS_PORT" $SSH_OPTS \
    "$FAIG_TARS_USER@$FAIG_TARS_HOST" \
    "ls -lh $FAIG_TARS_DIR/FAIG_*.tar* 2>/dev/null" || {
      echo "No FAIG tars found at $FAIG_TARS_DIR on $FAIG_TARS_HOST."
      exit 1
    }

  echo "=== Pushing FAIG tars: $FAIG_TARS_HOST → cloud VM (agent-forwarded) ==="
  ssh -A -p "$FAIG_TARS_PORT" $SSH_OPTS \
    "$FAIG_TARS_USER@$FAIG_TARS_HOST" \
    "scp $SSH_OPTS $FAIG_TARS_DIR/FAIG_*.tar* $CLOUD_USER@$CLOUD_IP:~/faig-images/"
fi

echo "=== Verifying ==="
ssh $SSH_OPTS "$CLOUD_USER@$CLOUD_IP" "ls -lh ~/faig-images/FAIG_*.tar*"

echo "Done. FAIG tars are on the cloud VM at ~/faig-images/"
