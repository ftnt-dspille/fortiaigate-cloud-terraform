# FortiAIGate on Azure -- Terraform + Ansible

Deploy FortiAIGate to Azure with a two-phase approach: **build on cheap CPU**,
**switch to GPU later**. Stop VMs to $0 compute. Snapshot and clone.

## Architecture

```
Phase 1 (CPU build)                    Phase 2 (GPU run)
┌──────────────────────┐              ┌──────────────────────┐
│  Standard_D4s_v5     │   snapshot   │  Standard_NC4as_T4_v3│
│  4 vCPU, 16 GiB      │──→ image ──→│  1x T4 GPU, 28 GiB   │
│  ~$0.20/hr on-demand  │              │  ~$0.15/hr spot       │
│                      │              │                      │
│  - k3s installed      │              │  - boots from image   │
│  - FAIG tars imported │              │  - k3s cert reissued  │
│  - helm chart staged  │              │  - NVIDIA driver      │
│  - NO helm install    │              │  - gpu.enabled: true │
│  - NO license         │              │  - helm install       │
└──────────────────────┘              │  - apply .lic         │
                                      └──────────────────────┘
                                               clone → N VMs
```

## Prerequisites

```bash
# Azure CLI
brew install azure-cli
az login

# Terraform
brew install terraform

# Ansible + kubernetes.core collection
pip install ansible
ansible-galaxy collection install kubernetes.core

# SSH key (if you don't have one)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
```

## Workflow

### 1. Configure

```bash
cd azure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars -- set ssh_public_key AND the source CIDR lists at
# minimum. ssh_source_ips / https_source_ips are REQUIRED and validated:
# 0.0.0.0/0 is rejected at plan time.
```

### 2. Build (CPU phase)

```bash
# Deploy a cheap CPU VM + run the faig_seed playbook + import FAIG images
make build
```

The tars come from wherever they are (picked automatically):

- **`faig-images/` in the repo root** (default) -- download the FAIG tars
  there once (gitignored; see `faig-images/README.md`); the copy script pushes
  them straight to the VM's public IP. Nothing to configure.
- **A remote host** -- set `FAIG_TARS_HOST`/`FAIG_TARS_PORT` (and optionally
  `FAIG_TARS_USER`/`FAIG_TARS_DIR`) and the tars are pushed from that host
  directly to the cloud VM (it needs internet egress, not inbound reachability).

The FAIG helm chart tar (`FAIG_helm_chart-*.tar`, Fortinet-distributed, not in
this repo) must be in `../faig_seed/` first -- see the root README,
Prerequisites. `build.sh` checks and stops with a clear message if it is
missing.

### 3. Snapshot → image

```bash
make image
# Outputs an image ID -- save it
```

### 4. Deploy GPU VM(s) from the image

```bash
# Single GPU VM:
terraform apply \
  -var=source_image_id='<image-id-from-step-3>' \
  -var=instance_type=Standard_NC4as_T4_v3 \
  -var=spot=true

# Multiple clones:
terraform apply \
  -var=source_image_id='<image-id>' \
  -var=instance_type=Standard_NC4as_T4_v3 \
  -var=spot=true \
  -var=vm_count=3
```

### 5. Enable GPU on each VM

```bash
# Get the IPs:
terraform output public_ips

# For each VM:
./scripts/enable_gpu.sh <ip>

# Apply a FAIG license (each clone needs its own .lic):
scp <serial>.lic azureuser@<ip>:~/fortiaigate/files/licenses/faig-node.lic
ssh azureuser@<ip> 'cd ~/fortiaigate && helm upgrade fortiaigate . -n fortiaigate -f ~/my-values.yaml'
ssh azureuser@<ip> 'sudo k3s kubectl rollout restart -n fortiaigate daemonset/license-manager'
```

Tip: the GCP stack in `../gcp/` automates licensing via the admin API
(`scripts/license.sh`) and ships a license-pool CLI in `../tools/`; the same
approach works on Azure if you prefer API licensing over the helm mount.

### 6. Stop / start (no cost when stopped)

```bash
make stop    # deallocate -- $0 compute, disk only (~$2/mo)
make start   # restart -- same IP (Static public IP)
```

### 7. Tear down

```bash
make destroy
```

## Cost summary

| State | Cost |
|---|---|
| Build VM running (D4s_v5 on-demand) | ~$0.20/hr |
| GPU VM running (NC4as_T4_v3 spot) | ~$0.15/hr |
| VM stopped (deallocated) | ~$2/mo (disk only) |
| VM deleted, image stored | ~$0.50/mo (image only) |

## Instance type reference

| Phase | Type | GPU | RAM | $/hr spot | $/hr on-demand |
|---|---|---|---|---|---|
| Build | Standard_D4s_v5 | none | 16 GiB | ~$0.05 | ~$0.20 |
| GPU | Standard_NC4as_T4_v3 | 1x T4 (16 GB) | 28 GiB | ~$0.15 | ~$0.53 |
| GPU (cheaper) | Standard_NC4ads_T4_v3 | 1x T4 (16 GB) | 28 GiB | ~$0.12 | ~$0.41 |

## Files

```
azure/
├── versions.tf, providers.tf     Terraform provider config
├── variables.tf                   All tunable parameters (CIDRs validated)
├── main.tf                         RG, VNet, NSG, public IP, VM(s)
├── outputs.tf                      IPs, VM names, RG name
├── cloud-init/user-data.yml       Package install on first boot
├── scripts/
│   ├── copy_faig_images.sh         Source host → cloud VM (pushed over SSH)
│   ├── build.sh                    Ansible playbook + image import
│   ├── make_image.sh               Snapshot → managed image (az CLI)
│   ├── enable_gpu.sh               k3s cert fix + GPU role + helm install
│   ├── stop.sh                     Deallocate ($0 compute)
│   └── start.sh                    Restart
├── Makefile                        Orchestrates everything
└── terraform.tfvars.example        Copy → terraform.tfvars
```
