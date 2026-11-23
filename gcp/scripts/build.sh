#!/usr/bin/env bash
set -euo pipefail

# Phase 1 (CPU): Run the faig_seed playbook on the cloud VM, then import
# FAIG container images into k3s containerd. Does NOT helm install -- the
# stack is staged but not started. Helm install happens on the GPU VM
# (enable_gpu.sh) so k3s gets the right IP/cert from the start.
#
# Usage: build.sh [vm-name]
#
# Prereqs:
#   - ansible-playbook + kubernetes.core collection installed locally
#   - FAIG tars already on the cloud VM (run copy_faig_images.sh first)
#   - The FAIG helm chart tar at faig_seed/ (Fortinet-distributed, not in this
#     repo -- see the root README "Prerequisites")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
ZONE="$(get_zone)"
INTERNAL_IP="$(get_internal_ip)"
# Stable DNS name for this VM (e.g. faig.example.com). Added to the
# ingress default TLS cert as a DNS SAN so the UI cert matches the name
# students use, not just an IP. Empty when dns_zone is unset.
HOSTNAME="$(get_hostname "$VM_NAME")"

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

echo "=== Starting IAP tunnel to $VM_NAME ==="
iap_start_ssh "$VM_NAME" "$ZONE"
trap iap_cleanup EXIT

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

INVENTORY=$(mktemp /tmp/faig-cloud-inventory.XXXX.yml)
trap 'rm -f "$INVENTORY"; iap_cleanup' EXIT

cat > "$INVENTORY" <<EOF
---
all:
  children:
    k3s_node:
      hosts:
        cloud-faig:
          ansible_host: localhost
          ansible_port: $SSH_PORT
          ansible_user: ubuntu
          ansible_ssh_common_args: $SSH_OPTS
      vars:
        gpu_enabled: false
        primary_interface: ens4
        faig_primary_interface: ens4
        external_address: $INTERNAL_IP
$( [ -n "$HOSTNAME" ] && printf '        extra_tls_sans:\n          - %s\n' "$HOSTNAME" )
EOF

echo "=== Running faig_seed playbook (CPU mode, no GPU) ==="
ansible-playbook -i "$INVENTORY" "$FAIG_SEED/site.yml" \
  -e faig_primary_interface=ens4 -e primary_interface=ens4

echo "=== Staging 8.0.2 helm chart ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" << 'REMOTE'
set -e
tar xf ~/faig-images/FAIG_helm_chart-V8.0.2-build6191-FORTINET.tar -C ~/
head -4 ~/fortiaigate/Chart.yaml
[ -f ~/my-values.yaml ] || cp ~/fortiaigate/values.yaml ~/my-values.yaml
mkdir -p ~/fortiaigate/files/licenses
REMOTE

echo "=== Importing FAIG container images into k3s containerd ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" << 'REMOTE'
set -e
for f in ~/faig-images/FAIG_*.tar; do
  case "$f" in
    *helm_chart*) echo "Skipping helm chart: $f"; continue ;;
    *deploy-docker-compose-cli*) echo "Skipping helper: $f"; continue ;;
  esac
  echo "Importing $(basename $f)..."
  sudo k3s ctr -n k8s.io images import "$f" 2>&1 | tail -1
done
echo "Imported images:"
sudo k3s ctr -n k8s.io images list | grep -i 'fortinet\|vllm' | grep -v sha256 | awk '{print $1, $2}'
REMOTE

echo "=== Build complete ==="
echo "k3s is running with FAIG images imported and the helm chart staged."
echo "Next: run make_image.sh to snapshot this VM into a reusable image."
