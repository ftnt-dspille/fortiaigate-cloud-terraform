#!/usr/bin/env bash
set -euo pipefail

# Phase 1 (CPU): Run the faig_seed playbook on the cloud VM, then import
# FAIG container images into k3s containerd. Does NOT helm install -- the
# stack is staged but not started. Helm install happens on the GPU VM
# (enable_gpu.sh) so k3s gets the right IP/cert from the start.
#
# Usage: build.sh <cloud-ip> [cloud-user]
#
# Prereqs:
#   - ansible-playbook + kubernetes.core collection installed locally
#   - FAIG tars already on the cloud VM (run copy_faig_images.sh first)
#   - The FAIG helm chart tar at faig_seed/ (Fortinet-distributed, not in this
#     repo -- see the root README "Prerequisites")

CLOUD_IP="${1:?Usage: build.sh <cloud-ip> [cloud-user]}"
CLOUD_USER="${2:-azureuser}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
FAIG_SEED="${FAIG_SEED_DIR:-$REPO_ROOT/faig_seed}"

if [ ! -d "$FAIG_SEED" ]; then
  echo "faig_seed not found at $FAIG_SEED"
  exit 1
fi

# The fortiaigate role stages the FAIG helm chart tar from faig_seed/. The tar
# is Fortinet-distributed and NOT committed to this repo -- drop it in place.
ls "$FAIG_SEED"/FAIG_helm_chart-*.tar >/dev/null 2>&1 || {
  echo "ERROR: no FAIG_helm_chart-*.tar in $FAIG_SEED"
  echo "  The chart tar is Fortinet-distributed and is not in this repo."
  echo "  Put it there before building (see the root README, Prerequisites)."
  exit 1
}

INVENTORY=$(mktemp /tmp/faig-cloud-inventory.XXXX.yml)
trap 'rm -f "$INVENTORY"' EXIT

cat > "$INVENTORY" <<EOF
---
all:
  children:
    k3s_node:
      hosts:
        cloud-faig:
          ansible_host: $CLOUD_IP
          ansible_user: $CLOUD_USER
      vars:
        gpu_enabled: false
        primary_interface: eth0
        faig_primary_interface: eth0
        external_address: $CLOUD_IP
EOF

echo "=== Verifying FAIG tars are on the cloud VM ==="
# Fail fast, before a multi-minute playbook run: copy_faig_images.sh puts
# them there ('make build' runs it first).
ssh $SSH_OPTS "$CLOUD_USER@$CLOUD_IP" "ls ~/faig-images/FAIG_*.tar* >/dev/null 2>&1" || {
  echo "ERROR: no FAIG_*.tar* in ~/faig-images on $CLOUD_IP." >&2
  echo "  Run scripts/copy_faig_images.sh first ('make build' does it for you)." >&2
  exit 1
}

echo "=== Running faig_seed playbook (CPU mode, no GPU) ==="
ansible-playbook -i "$INVENTORY" "$FAIG_SEED/site.yml" \
  -e faig_primary_interface=eth0 -e primary_interface=eth0

echo "=== Importing FAIG container images into k3s containerd ==="
ssh "$CLOUD_USER@$CLOUD_IP" << 'REMOTE'
set -e
shopt -s nullglob
tars=(~/faig-images/FAIG_*.tar)
if [ ${#tars[@]} -eq 0 ]; then
  echo "ERROR: no FAIG_*.tar in ~/faig-images on the VM." >&2
  exit 1
fi
for f in "${tars[@]}"; do
  case "$f" in
    *helm_chart*) echo "Skipping helm chart: $f"; continue ;;
  esac
  echo "Importing $f..."
  sudo k3s ctr -n k8s.io images import "$f"
done
echo "Imported images:"
sudo k3s ctr -n k8s.io images list | grep -i faig || true
REMOTE

echo "=== Build complete ==="
echo "k3s is running with FAIG images imported and the helm chart staged."
echo "Next: run make_image.sh to snapshot this VM into a reusable image."
