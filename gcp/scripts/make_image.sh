#!/usr/bin/env bash
set -euo pipefail

# Snapshot the build VM's boot disk and create a custom image from it.
# Deploy GPU VMs from it by setting source_image in gpu.tfvars, then `make deploy`
# (which applies with -var-file=gpu.tfvars).
#
# Usage: make_image.sh [image-name]
#
# Outputs the image self-link -- save it for the GPU deploy step.
#
# Requires: gcloud CLI logged in (gcloud auth login)

IMAGE_NAME="${1:-faig-build-$(date +%Y%m%d-%H%M%S)}"

PROJECT=$(terraform -chdir="$(git rev-parse --show-toplevel)/cloud/faig_gcp" output -raw project_id 2>/dev/null || gcloud config get-value project)
ZONE=$(terraform -chdir="$(git rev-parse --show-toplevel)/cloud/faig_gcp" output -raw zone 2>/dev/null || gcloud config get-value compute/zone)
VM_NAME=$(terraform -chdir="$(git rev-parse --show-toplevel)/cloud/faig_gcp" output -json vm_names | python3 -c "import sys,json; print(json.load(sys.stdin)[0])")

echo "=== Stopping VM: $VM_NAME ==="
gcloud compute instances stop "$VM_NAME" --zone="$ZONE"

echo "=== Creating custom image: $IMAGE_NAME ==="
gcloud compute images create "$IMAGE_NAME" \
  --source-disk="$VM_NAME" \
  --source-disk-zone="$ZONE" \
  --storage-location=us

IMAGE_LINK="projects/$PROJECT/global/images/$IMAGE_NAME"

echo ""
echo "=== Image created ==="
echo "Image: $IMAGE_LINK"
echo ""
echo "Deploy GPU VMs from it:"
echo "  set source_image = \"$IMAGE_LINK\" in gpu.tfvars, then: make deploy"
echo "  (an L4 is required -- a T4 cannot run 8.0.2's policyguard model)"
echo ""
echo "Or restart the build VM:"
echo "  gcloud compute instances start $VM_NAME --zone=$ZONE"
