#!/usr/bin/env bash
set -euo pipefail

# Snapshot the build VM's OS disk and create a managed image from it.
# The image can be used to deploy GPU VMs (or more CPU VMs) via
#   terraform apply -var=source_image_id=<image-id>
#
# Usage: make_image.sh <image-name>
#
# Outputs the image ID -- save it for the GPU deploy step.
#
# Requires: az CLI logged in (az login)

IMAGE_NAME="${1:-faig-build-$(date +%Y%m%d-%H%M%S)}"

RG=$(terraform -chdir="$(git rev-parse --show-toplevel)/cloud/faig_azure" output -raw resource_group_name)
VM_NAME=$(terraform -chdir="$(git rev-parse --show-toplevel)/cloud/faig_azure" output -json vm_names | python3 -c "import sys,json; print(json.load(sys.stdin)[0])")

echo "=== Deallocating VM: $VM_NAME ==="
az vm deallocate --resource-group "$RG" --name "$VM_NAME"

echo "=== Generalizing VM: $VM_NAME ==="
az vm generalize --resource-group "$RG" --name "$VM_NAME"

echo "=== Creating managed image: $IMAGE_NAME ==="
az image create \
  --resource-group "$RG" \
  --name "$IMAGE_NAME" \
  --source "$VM_NAME" \
  --hyper-v-generation V2 \
  --output table

IMAGE_ID=$(az image show --resource-group "$RG" --name "$IMAGE_NAME" --query id -o tsv)

echo ""
echo "=== Image created ==="
echo "Image ID: $IMAGE_ID"
echo ""
echo "Deploy GPU VMs from it:"
echo "  terraform apply -var=source_image_id='$IMAGE_ID' -var=instance_type=Standard_NC4as_T4_v3 -var=spot=true"
echo ""
echo "Or restart the build VM:"
echo "  az vm start --resource-group $RG --name $VM_NAME"
