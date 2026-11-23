#!/usr/bin/env bash
set -euo pipefail

# Deallocate the VM(s) -- stops compute billing ($0/hr), keeps disk storage cost only.
# Data and k3s state are preserved. Start again with start.sh.
#
# Usage: stop.sh [vm-name]  (defaults to all VMs from Terraform)

RG=$(terraform -chdir="$(git rev-parse --show-toplevel)/cloud/faig_azure" output -raw resource_group_name)

if [ -n "${1:-}" ]; then
  VM_NAMES="$1"
else
  VM_NAMES=$(terraform -chdir="$(git rev-parse --show-toplevel)/cloud/faig_azure" output -json vm_names | jq -r '.[]')
fi

for VM in $VM_NAMES; do
  echo "Deallocating: $VM"
  az vm deallocate --resource-group "$RG" --name "$VM"
done

echo "Done. Compute billing stopped. Disk storage still applies (~$2-5/mo per VM)."
