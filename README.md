# FortiAIGate on Cloud -- Terraform (GCP + Azure)

Deploy [FortiAIGate (FAIG)](https://docs.fortinet.com) lab VMs on Google Cloud or
Azure with a two-phase workflow: **build on cheap CPU**, **snapshot to an image**,
**run on GPU**. VMs stop to $0 compute when the lab is not in use, and a lab
schedule can start/stop them automatically.

```
Phase 1 (CPU build)                     Phase 2 (GPU run)
┌───────────────────────┐               ┌───────────────────────┐
│  e2-standard-4 / D4s_v5│   snapshot   │  g2-standard-8 (L4) / │
│  4 vCPU, 16 GiB       │──→ image ──→ │  NC4as_T4_v3 (T4)     │
│  ~$0.12-0.20/hr       │               │  ~$0.15-0.35/hr       │
│                       │               │                       │
│  - k3s installed      │               │  - boots from image   │
│  - FAIG tars imported │               │  - k3s cert reissued  │
│  - helm chart staged  │               │  - NVIDIA driver      │
│  - NOT started        │               │  - FAIG helm install  │
│  - NO license         │               │  - license applied    │
└───────────────────────┘               └───────────────────────┘
                                          clone → N VMs
```

## Repo layout

```
├── gcp/           FortiAIGate on Google Cloud (the full workflow: IAP-only VMs,
│                  automatic GPU zone placement, Cloud DNS, TLS via cert-manager,
│                  auto start/stop schedules, multi-VM classes)
├── azure/         FortiAIGate on Azure (simpler build → image → GPU-clone flow)
├── faig_seed/     Ansible playbook that stages k3s + the FAIG helm chart on a VM
│                  (see its own README for roles and variables)
├── api/           FortiAIGate 8.0.2 admin-API client + class tooling (Python,
│                  stdlib only): faig802.py, faig_class.py, faig_workshop.py
└── tools/         License-pool CLI: allocate single-occupancy .lic serials to VMs
```

Start with the cloud you want:

- **[gcp/README.md](gcp/README.md)** -- the complete walkthrough (`make up` takes a VM
  from any state to licensed and passing all readiness checks)
- **[azure/README.md](azure/README.md)** -- the Azure equivalent

## Prerequisites

### Tooling

| Tool | Used by | Install |
|---|---|---|
| Terraform >= 1.5 | both | `brew install terraform` |
| gcloud CLI (authed: `gcloud auth login`) | gcp | `brew install --cask google-cloud-sdk` |
| Azure CLI (authed: `az login`) | azure | `brew install azure-cli` |
| ansible (run from the repo root so `faig_seed/` resolves) | both | `pip install ansible` then `ansible-galaxy collection install -r faig_seed/requirements.yml` (kubernetes.core, community.crypto, community.general) |
| python3 | scripts | preinstalled on macOS |
| jq | azure `make stop` / `make start` | `brew install jq` |
| An SSH keypair | both | `ssh-keygen -t ed25519` |

### Fortinet-distributed artifacts (not in this repo)

FortiAIGate is a licensed Fortinet product; its artifacts are **not committed
here**. You need, from your Fortinet support channel / your own environment:

1. **FAIG install tars** (`FAIG_*.tar*` -- container images + the helm chart
   that ships in the bundle), obtained from your Fortinet support channel /
   your own environment. **Drop them into `faig-images/` on your laptop**
   (gitignored; see `faig-images/README.md`) and the copy scripts push them up
   automatically -- no other host needed. If the tars already live on some
   SSH-reachable host (a pod, a server), point `FAIG_TARS_HOST` /
   `FAIG_TARS_PORT` at it instead and the scripts relay from there. (RELAY
   mode only: load the key the target VM accepts into your ssh-agent first --
   `ssh-add ~/.ssh/id_ed25519` -- the relay's last hop authenticates through
   the forwarded agent. LOCAL mode uses the default key file.)
2. **The FAIG helm chart tar** (`FAIG_helm_chart-*.tar`) -- needed in TWO
   gitignored places: `faig_seed/` (the playbook stages it from there) and
   `faig-images/` (it is pushed up with the other tars; the build then
   extracts the bundle's chart from it). Copy it into both:
   `cp FAIG_helm_chart-*.tar faig_seed/ faig-images/` -- `build.sh` checks
   for it and stops with a clear message if either is missing.
3. **One `.lic` license file per running VM** -- single-occupancy serials. Hand
   them to `make license FILE=...`, or point `FAIG_LICENSE_POOL` at a directory
   of `.lic` files and let `tools/faig_license_pool.py` allocate one seat per VM.

## Security model

- **gcp**: VMs have **no public IPs by default**. All access goes through
  [IAP tunnels](https://cloud.google.com/iap/docs/using-tcp-forwarding) (SSH +
  HTTP + HTTPS), so the only ingress firewall rule allows Google's IAP range.
  Public IPs + a source-CIDR allowlist are opt-in via `public_access_cidrs`
  (used when students reach FAIG directly from their own networks).
- **azure**: `ssh_source_ips` and `https_source_ips` are **required** variables
  with validation that rejects `0.0.0.0/0` -- the NSG cannot be applied
  world-open. HTTP (80) is off unless you set `enable_http = true`.
- Admin credentials are never stored in the repo: `FAIG_ADMIN_PASS` env var, or
  a macOS Keychain item (`faig-lab-admin`). TLS certs come from Let's Encrypt
  via cert-manager DNS-01 (GCP, optional) or are self-signed.

## Cost notes

| State | GCP (L4, g2-standard-8) | Azure (T4, NC4as_T4_v3) |
|---|---|---|
| Build VM running (CPU) | ~$0.12/hr | ~$0.20/hr |
| GPU VM running | ~$0.35-0.45/hr on-demand, less spot | ~$0.15/hr spot |
| VM stopped | ~$0 (disk only) + GPU **hold** released by the stop schedule | ~$2/mo disk |

The GCP stack can hold GPU reservations ("holds") so a lab starts in a scarce
zone; those holds bill like a running GPU while the VM is stopped, so the stack
ships a Cloud Scheduler job that releases each hold on the same stop schedule
(`unreserve.tf`). Keep this in mind when reading your bill.
