#!/usr/bin/env bash
set -euo pipefail

# Start (deallocated) VM(s). The public IP may change on restart unless
# the VM uses a static public IP (Terraform creates Static SKU PIPs, so it won't).
#
# Usage: start.sh [vm-name]  (defaults to all VMs from Terraform)

RG=$(terraform -chdir="$(git rev-parse --show-toplevel)/cloud/faig_azure" output -raw resource_group_name)

if [ -n "${1:-}" ]; then
  VM_NAMES="$1"
else
  VM_NAMES=$(terraform -chdir="$(git rev-parse --show-toplevel)/cloud/faig_azure" output -json vm_names | jq -r '.[]')
fi

for VM in $VM_NAMES; do
  echo "Starting: $VM"
  az vm start --resource-group "$RG" --name "$VM"
done

echo "Done. VMs are running."
echo "Public IPs:"
terraform -chdir="$(git rev-parse --show-toplevel)/cloud/faig_azure" output public_ips
