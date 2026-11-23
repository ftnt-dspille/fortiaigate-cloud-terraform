#!/usr/bin/env bash
set -euo pipefail

# Phase 2 (GPU): On a GPU VM deployed from the build image:
#   1. Fix k3s cert for the new VM's IP (the image has the build VM's IP pinned)
#   2. Run the gpu role (NVIDIA driver + Container Toolkit + device plugin)
#   3. Edit my-values.yaml: gpu.enabled = true
#   4. Helm install (first time on this VM -- build phase only staged)
#
# Usage: enable_gpu.sh <cloud-ip> [cloud-user]
#
# After this, apply a FAIG .lic (see license/README.md).

CLOUD_IP="${1:?Usage: enable_gpu.sh <cloud-ip> [cloud-user]}"
CLOUD_USER="${2:-azureuser}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
FAIG_SEED="${FAIG_SEED_DIR:-$REPO_ROOT/faig_seed}"

INVENTORY=$(mktemp /tmp/faig-cloud-gpu.XXXX.yml)
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
        gpu_enabled: true
        primary_interface: eth0
        external_address: $CLOUD_IP
EOF

echo "=== Fixing k3s config for new VM IP ==="
ssh "$CLOUD_USER@$CLOUD_IP" << 'REMOTE'
set -e
NEW_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "New primary IP: $NEW_IP"

# Update k3s config: replace the pinned node-ip/bind/advertise with the new IP
sudo sed -i "s|node-ip:.*|node-ip: \"$NEW_IP\"|" /etc/rancher/k3s/config.yaml
sudo sed -i "s|bind-address:.*|bind-address: \"$NEW_IP\"|" /etc/rancher/k3s/config.yaml
sudo sed -i "s|advertise-address:.*|advertise-address: \"$NEW_IP\"|" /etc/rancher/k3s/config.yaml

# Add the public IP to tls-san (for external kubectl access)
# The line with the old external_address needs replacing too
PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)
sudo sed -i "/^tls-san:/,/^[^ ]/ s|.*- .*|  - \"$NEW_IP\"|" /etc/rancher/k3s/config.yaml || true
# Ensure 127.0.0.1 is in the SAN (for local kubectl)
grep -q '127.0.0.1' /etc/rancher/k3s/config.yaml || sudo sed -i "/tls-san:/a\\  - \"127.0.0.1\"" /etc/rancher/k3s/config.yaml

# Delete the old serving cert so k3s regenerates it with the new SAN
sudo rm -f /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt
sudo rm -f /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.key

# Fix kubeconfig to use 127.0.0.1
sudo sed -i 's|server: https://.*:6443|server: https://127.0.0.1:6443|' /etc/rancher/k3s/k3s.yaml
sudo sed -i 's|server: https://.*:6443|server: https://127.0.0.1:6443|' ~/.kube/config 2>/dev/null || true

sudo systemctl restart k3s
sleep 5
echo "Waiting for k3s API..."
sudo k3s kubectl wait --for=condition=Ready node --timeout=120s 2>/dev/null || {
  echo "k3s not ready yet, waiting more..."
  sleep 15
  sudo k3s kubectl get nodes
}
REMOTE

echo "=== Running GPU role (NVIDIA driver + toolkit + device plugin) ==="
ansible-playbook -i "$INVENTORY" "$FAIG_SEED/site.yml" --tags gpu

echo "=== Verifying GPU ==="
ssh "$CLOUD_USER@$CLOUD_IP" << 'REMOTE'
echo "--- nvidia-smi ---"
nvidia-smi
echo ""
echo "--- k8s GPU capacity ---"
sudo k3s kubectl describe node | grep -A5 'nvidia.com/gpu' || echo "GPU not yet advertised (may need a reboot)"
REMOTE

echo "=== Enabling GPU in my-values.yaml ==="
ssh "$CLOUD_USER@$CLOUD_IP" << 'REMOTE'
cd ~/fortiaigate
if [ -f my-values.yaml ]; then
  # Enable GPU in the fortiaigate.gpu.enabled field
  if grep -A2 '  gpu:' my-values.yaml | grep -q 'enabled: false'; then
    sed -i '/^  gpu:/,/^[^ ]/ s/enabled: false/enabled: true/' my-values.yaml
    echo "Set gpu.enabled: true in my-values.yaml"
  else
    echo "gpu already enabled or field not found -- verify manually"
  fi
else
  echo "my-values.yaml not found -- run build.sh first"
  exit 1
fi
REMOTE

echo "=== Helm install ==="
ssh "$CLOUD_USER@$CLOUD_IP" \
  "cd ~/fortiaigate && helm install fortiaigate . -n fortiaigate --create-namespace -f ~/my-values.yaml"

echo ""
echo "=== GPU enablement complete ==="
echo "Verify the stack:"
echo "  ssh $CLOUD_USER@$CLOUD_IP 'sudo k3s kubectl get pods -A'"
echo ""
echo "Apply a FAIG license next:"
echo "  scp <your-lic> $CLOUD_USER@$CLOUD_IP:~/fortiaigate/files/licenses/faig-node.lic"
echo "  ssh $CLOUD_USER@$CLOUD_IP 'cd ~/fortiaigate && helm upgrade fortiaigate . -n fortiaigate -f ~/my-values.yaml'"
echo "  ssh $CLOUD_USER@$CLOUD_IP 'sudo k3s kubectl rollout restart -n fortiaigate daemonset/license-manager'"
