#!/usr/bin/env bash
set -euo pipefail

# Phase 2 (GPU): On a GPU VM deployed from the build image:
#   1. Fix k3s cert for the new VM's internal IP (the image has the build VM's IP pinned)
#   2. Install gcc-12 (needed for DKMS on Ubuntu 22.04 with kernel 6.8)
#   3. Run the gpu role (NVIDIA driver + Container Toolkit + device plugin)
#   4. Configure k3s containerd with nvidia as default runtime
#   5. Install nvidia-device-plugin with RuntimeClass
#   6. Fix my-values.yaml: set FAIG image repo, enable GPU, reduce memory for lab sizing
#   7. Keep llamacpp running (the workshop's upstream model)
#   8. Helm install
#
# Usage: enable_gpu.sh [vm-name]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
ZONE="$(get_zone "$VM_NAME")"
INTERNAL_IP="$(get_internal_ip "$(( ${VM_NAME##*-} - 1 ))")"

REPO_ROOT="$(git rev-parse --show-toplevel)"
FAIG_SEED="${FAIG_SEED_DIR:-$REPO_ROOT/faig_seed}"

echo "=== Starting IAP tunnel to $VM_NAME ==="
iap_start_ssh "$VM_NAME" "$ZONE"
trap iap_cleanup EXIT

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== Detecting primary interface ==="
IFACE=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
  "ip -4 addr show | grep -v 'docker0\|lo\|cni\|flannel' | grep -oP '^\d+: \K\S+' | head -1" | tr -d ':' | tr -d '[:space:]')
echo "Primary interface: $IFACE"

INVENTORY=$(mktemp /tmp/faig-cloud-gpu.XXXX.yml)
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
        gpu_enabled: true
        primary_interface: $IFACE
        faig_primary_interface: $IFACE
        external_address: $INTERNAL_IP
EOF

echo "=== Step 1: Fixing k3s config for new VM internal IP ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" IFACE="$IFACE" 'bash -s' << 'REMOTE'
set -e
IFACE="${IFACE:?}"
NEW_IP=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "New internal IP: $NEW_IP"

sudo sed -i "s|node-ip:.*|node-ip: \"$NEW_IP\"|" /etc/rancher/k3s/config.yaml
sudo sed -i "s|bind-address:.*|bind-address: \"$NEW_IP\"|" /etc/rancher/k3s/config.yaml
sudo sed -i "s|advertise-address:.*|advertise-address: \"$NEW_IP\"|" /etc/rancher/k3s/config.yaml

grep -q '127.0.0.1' /etc/rancher/k3s/config.yaml || sudo sed -i "/tls-san:/a\\  - \"127.0.0.1\"" /etc/rancher/k3s/config.yaml
grep -q "$NEW_IP" /etc/rancher/k3s/config.yaml || sudo sed -i "/tls-san:/a\\  - \"$NEW_IP\"" /etc/rancher/k3s/config.yaml

sudo rm -f /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt
sudo rm -f /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.key

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

echo "=== Step 2: Installing gcc-12 (needed for DKMS on kernel 6.8) ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" 'bash -s' << 'REMOTE'
set -e
if gcc --version 2>&1 | grep -q "12\."; then
  echo "gcc-12 already installed"
else
  sudo apt-get update -qq
  sudo apt-get install -y gcc-12 g++-12
  sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100
  sudo update-alternatives --install /usr/bin/cc cc /usr/bin/gcc-12 100
  sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 100
  echo "gcc-12 installed"
fi
gcc --version | head -1
REMOTE

echo "=== Step 3: Running GPU role (NVIDIA driver + toolkit + device plugin) ==="
ansible-playbook -i "$INVENTORY" "$FAIG_SEED/site.yml" --tags gpu \
  -e faig_primary_interface=$IFACE -e primary_interface=$IFACE

echo "=== Step 4: Configuring k3s containerd with nvidia as default runtime ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" 'bash -s' << 'REMOTE'
set -e

sudo mkdir -p /var/lib/rancher/k3s/agent/etc/containerd

# Only create if not already present
if [ ! -f /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl ] || ! grep -q "default_runtime_name = \"nvidia\"" /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl 2>/dev/null; then
  sudo tee /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl > /dev/null << 'EOF'
version = 2

[plugins."io.containerd.internal.v1.opt"]
  path = "/var/lib/rancher/k3s/agent/containerd"
[plugins."io.containerd.grpc.v1.cri"]
  stream_server_address = "127.0.0.1"
  stream_server_port = "10010"
  enable_selinux = false
  enable_unprivileged_ports = true
  enable_unprivileged_icmp = true
  device_ownership_from_security_context = false
  sandbox_image = "rancher/mirrored-pause:3.6"

[plugins."io.containerd.grpc.v1.cri".containerd]
  snapshotter = "overlayfs"
  disable_snapshot_annotations = true
  default_runtime_name = "nvidia"

[plugins."io.containerd.grpc.v1.cri".cni]
  bin_dir = "/var/lib/rancher/k3s/data/cni"
  conf_dir = "/var/lib/rancher/k3s/agent/etc/cni/net.d"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
    BinaryName = "/usr/bin/nvidia-container-runtime"
    SystemdCgroup = true
EOF
  echo "Created k3s containerd config with nvidia as default runtime"
else
  echo "k3s containerd config already has nvidia as default"
fi

sudo systemctl restart k3s
sleep 15
echo "k3s restarted"

# Fix ldconfig for nvidia libs
sudo ldconfig
REMOTE

echo "=== Step 5: Installing nvidia-device-plugin with RuntimeClass ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" 'bash -s' << 'REMOTE'
set -e

# Install device plugin if not present
if ! sudo k3s kubectl get ds nvidia-device-plugin-daemonset -n kube-system >/dev/null 2>&1; then
  sudo -u ubuntu sudo k3s kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.1/nvidia-device-plugin.yml
  echo "Installed nvidia-device-plugin"
else
  echo "nvidia-device-plugin already installed"
fi

# Create RuntimeClass if not present
if ! sudo k3s kubectl get runtimeclass nvidia >/dev/null 2>&1; then
  sudo -u ubuntu sudo k3s kubectl apply -f - << 'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF
  echo "Created nvidia RuntimeClass"
else
  echo "RuntimeClass nvidia already exists"
fi

# Patch device plugin to use nvidia runtime class
if ! sudo k3s kubectl get ds nvidia-device-plugin-daemonset -n kube-system -o jsonpath='{.spec.template.spec.runtimeClassName}' 2>/dev/null | grep -q "nvidia"; then
  sudo -u ubuntu sudo k3s kubectl patch ds nvidia-device-plugin-daemonset -n kube-system --type=json -p '[{"op":"add","path":"/spec/template/spec/runtimeClassName","value":"nvidia"}]'
  echo "Patched device plugin with nvidia runtime class"
  sleep 15
fi

# Restart device plugin to pick up ldconfig
sudo -u ubuntu sudo k3s kubectl delete pod -n kube-system -l app=nvidia-device-plugin-daemonset --force 2>/dev/null || true
sleep 15

echo "=== GPU verification ==="
nvidia-smi
echo ""
sudo k3s kubectl describe node | grep -B1 -A3 'nvidia.com/gpu' || echo "GPU not yet advertised"
REMOTE

echo "=== Step 6: Keeping llamacpp running (the lab's upstream model) ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" 'bash -s' << 'REMOTE'
sudo -u ubuntu sudo k3s kubectl scale deployment llamacpp -n llamacpp --replicas=1
REMOTE

echo "=== Step 7: Fixing my-values.yaml ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" 'bash -s' << 'REMOTE'
set -e
cd ~/fortiaigate

# Set FAIG image repository (only the FAIG global image, not bitnami)
if grep -q "^    repository:$" ~/my-values.yaml; then
  sed -i '0,/^    repository:$/{s/^    repository:$/    repository: dops-jfrog.fortinet-us.com\/docker-fortiaigate-local/}' ~/my-values.yaml
  echo "Set FAIG image repository"
fi

if grep -q "^    tag:$" ~/my-values.yaml; then
  sed -i '0,/^    tag:$/{s/^    tag:$/    tag: V8.0.2-build6191/}' ~/my-values.yaml
  echo "Set FAIG image tag"
fi

# Enable GPU
if grep -A2 '  gpu:' ~/my-values.yaml | grep -q 'enabled: false'; then
  sed -i '/^  gpu:/,/^[^ ]/ s/enabled: false/enabled: true/' ~/my-values.yaml
  echo "Enabled GPU"
fi

# Reduce triton memory for lab sizing
sed -i '/^triton:/,/^[^ ]/ s/memory: 12Gi/memory: 6Gi/' ~/my-values.yaml 2>/dev/null || true
sed -i '/^triton:/,/^[^ ]/ s/memory: 25Gi/memory: 15Gi/' ~/my-values.yaml 2>/dev/null || true

echo "=== my-values.yaml image config ==="
grep -A2 '  image:' ~/my-values.yaml | head -8
REMOTE

echo "=== Step 8: Helm install/upgrade ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
  "sudo -u ubuntu bash -c 'cd ~/fortiaigate && helm upgrade fortiaigate . -n fortiaigate --create-namespace -f ~/my-values.yaml 2>&1'"

echo ""
echo "=== GPU enablement complete ==="
echo "Verify the stack:"
echo "  ./scripts/tunnel.sh ssh $VM_NAME"
echo "  ssh -p 2222 ubuntu@localhost 'sudo k3s kubectl get pods -A'"
echo ""
echo "Access the FAIG UI:"
echo "  ./scripts/tunnel.sh http $VM_NAME"
echo "  Open http://localhost:8080"
