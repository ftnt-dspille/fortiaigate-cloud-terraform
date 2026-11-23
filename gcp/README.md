# FortiAIGate on GCP -- Terraform

FortiAIGate (FAIG) 8.0.2 lab VMs on Google Cloud, built to run AI-guardrail
workshops: cheap CPU build → snapshot → L4 GPU run → clone for students. VMs are
**IAP-only by default** (no public IPs), stop to ~$0 when the lab closes, and
`make up` takes any VM from any state to *ready* (running, deployed, licensed,
passing all 11 readiness checks).

## Architecture

```
                        ┌──────────────────────────── google IAP (35.235.240.0/20)
SSH 22 / HTTP 80 / HTTPS 443            │  (default: the ONLY ingress)
                        ┌───────────────▼──────┐
                        │  faig-N (g2-standard-8, NVIDIA L4)
                        │  k3s → FAIG helm chart, llama.cpp (GPU), cert-manager
                        └───────────┬──────────┘
        per-region VPC ┌────────────┴─────────────┐
        faig-vpc ──────┤ subnet (10.0.x.0/24)     │ Cloud Router + NAT (egress)
                       └──────────────────────────┘
        optional: static IP + 443 allowlist (public_access_cidrs)
        optional: Cloud DNS zone (dns_zone) + Let's Encrypt (FAIG_ACME_EMAIL)
        optional: instance schedule (auto_start/stop) + GPU-hold release job
```

Key design points:

- **One subnet/router/NAT per region** an instance lands in, keyed by region
  name (never renumbered, so moving a VM never replaces another VM's subnet).
- **GPU placement is automatic**: `scripts/gpu_place.sh` claims an L4
  reservation ("hold") in a zone that has one, writes `placement.tfvars.json`,
  and terraform converges onto it. If a zone dries up, a stopped VM is
  relocated to where an L4 exists (DNS and static IP follow it).
- **The unreserve job** (`unreserve.tf`) deletes each VM's GPU hold on the stop
  schedule, so a stopped lab stops billing for its reservation.

## Prerequisites

- terraform >= 1.5, gcloud CLI logged in, an SSH keypair
- ansible + `kubernetes.core` collection (for the `faig_seed` playbook)
- **FAIG install tars** on this laptop in `faig-images/` (default) or on an
  SSH-reachable host (`FAIG_TARS_HOST`) -- not in this repo; see the root
  README, Prerequisites and `faig-images/README.md`
- **FAIG helm chart tar** dropped into `../faig_seed/` (`FAIG_helm_chart-*.tar`)
- **One `.lic` per running VM** -- single-occupancy serials
- python3 (stdlib only; no pip packages needed by the scripts)

## 1. Configure

```bash
cd gcp
cp terraform.tfvars.example terraform.tfvars
# edit: project_id, ssh_public_key (required)

cp gpu.tfvars.example gpu.tfvars      # edit before the GPU phase (step 4)
```

Optional local settings in `gcp/.env` (gitignored, auto-loaded by the Makefile):

```bash
# License pool: a directory of FAIG .lic files; one seat is allocated per VM
FAIG_LICENSE_POOL=/path/to/Lab Licenses/FAIG

# Let's Encrypt for the FAIG UI (cert-manager DNS-01 via Cloud DNS).
# Requires the service-account key JSON at gcp/.env.dns-sa-key.json and the
# Secret name it is uploaded as:
FAIG_ACME_EMAIL=you@example.com
FAIG_DNS_SA_SECRET=clouddns-dns01-solver-sa

# Admin password for the FAIG admin API (else: macOS Keychain item faig-lab-admin)
FAIG_ADMIN_PASS=...

# Where the FAIG tars live -- only for the REMOTE tar mode. With tars in
# faig-images/ on this laptop, nothing here is needed for the build.
FAIG_TARS_HOST=lab.example.com
FAIG_TARS_PORT=11001
```

## 2. Build phase (cheap CPU VM)

```bash
make init
make build
```

The tars come from wherever they are (picked automatically):

- **`faig-images/` in the repo root** (default) -- download the FAIG tars
  there once (gitignored; see `faig-images/README.md`); the copy script pushes
  them up through the IAP tunnel. Nothing to configure.
- **A remote host** -- set `FAIG_TARS_HOST`/`FAIG_TARS_PORT` (and optionally
  `FAIG_TARS_USER`/`FAIG_TARS_DIR`) and the tars relay from there through the
  same tunnel. Set `FAIG_TARS_DIR` to a local path only if you want to
  override the local dir.

`make build` = `terraform apply` with the CPU profile (`e2-standard-4`,
pd-standard) + `copy_faig_images.sh` + `build.sh` (runs the `faig_seed`
playbook: installs k3s, imports the FAIG container images, stages the helm
chart -- **without starting FAIG**). It verifies the tars are on the VM and
that the disk has room before starting, and fails fast with a clear message
otherwise.

## 3. Snapshot to an image

```bash
make image
# prints: projects/<project>/global/images/faig-build-<ts>  -- the GPU phase's source_image
```

## 4. GPU phase

Edit `gpu.tfvars`:

```hcl
machine_type = "g2-standard-8"        # NVIDIA L4 (a T4 cannot run 8.0.2's policyguard model)
gpu_type     = "nvidia-l4"
gpu_count    = 1
disk_type    = "pd-ssd"
source_image = "projects/<your-project>/global/images/<faig-build-image>"

# Optional: let students reach FAIG directly on 443 (one /32 per egress IP).
# Empty keeps the VMs IAP-only.
public_access_cidrs = []

# Optional: a stable name (delegated subdomain) + Let's Encrypt certs
dns_zone = ""
```

Then bring the lab up:

```bash
make up                # one VM (INSTANCE=1 default)
make up COUNT=3        # three VMs: zones, IPs, DNS and certs follow on their own
```

`make up` = **converge** (hold a GPU where one exists → `terraform apply` with
`gpu.tfvars` + `placement.tfvars.json` → drop redundant holds) then
**ready.sh** per VM: start it, redeploy if the VM was (re)created or moved, put
llama.cpp on the GPU, license it (`$FAIG_LICENSE_POOL` pool, or `LICENSE=path`
for a one-off file), and run the 11 readiness checks as the final gate.

First time only -- bootstrap the FAIG org + admin user (needs
`FAIG_ADMIN_PASS`):

```bash
make setup
```

`make license FILE=path/to.lic` uploads a specific license;
`make license` (no FILE) allocates from `$FAIG_LICENSE_POOL` and rotates on
`FAIG_LICENSE_IN_USE`.

## 5. DNS + TLS (optional but recommended)

1. Set `dns_zone` in `gpu.tfvars` to a subdomain delegated to Cloud DNS
   (e.g. `faig.example.com`), then `make apply-gpu`.
2. After the first apply, add the zone's `dns_name_servers` output as NS
   records for that subdomain at your registrar (once).
3. Put `FAIG_ACME_EMAIL` + `FAIG_DNS_SA_SECRET` (+ `.env.dns-sa-key.json`) in
   `gcp/.env`. cert-manager issues a trusted cert per VM hostname via DNS-01;
   `ready.sh` re-issues automatically if a VM's cert is wrong or self-signed.
   Without the email, the UI falls back to a self-signed cert (browser warning).

VM 1 answers at the zone apex; VM n at `faig-<n>.<zone>`. TTL is 60s so a zone
move reaches students within a minute.

## 6. Day-2 operations

| Command | What it does |
|---|---|
| `make up` / `make up COUNT=N` | any state → ready (idempotent; converges drift) |
| `make down` | stop all VMs, release GPU holds + static IPs (keeps disks + image) |
| `make health` | read-only pod/node health of every VM |
| `make test` | the 11 readiness checks (pods, license, GPU, API, model, gateway, ...) |
| `make ssh` / `make tunnel [http\|https\|<port>]` | IAP access to a VM |
| `make status` | terraform outputs (names, IPs, gateway URLs, IAP commands) |
| `make license [FILE=x.lic]` | license from pool or file |
| `make destroy` | delete everything terraform manages (+ holds, + placement file) |

Useful knobs:

- `INSTANCE=N` targets VM N; `COUNT=N` acts on all N
- `MOVE=N` relocates VM N to another zone now (drain a zone)
- `GPU_REGIONS=us-` narrows the zone search; `MAX_PARALLEL=1` makes hold
  claims strictly sequential (small L4 quota)
- `FAIG_RELOCATE=0` never moves a stopped VM; `KEEP_GPU_HOLD=1` on stop keeps
  the hold for a guaranteed next start (bills while stopped)
- `auto_start_schedule` / `auto_stop_schedule` (cron, `schedule_time_zone`)
  start/stop the lab automatically; the GPU holds are released on stop by the
  Cloud Scheduler job (`auto_unreserve`, default on)

## 7. Class day (optional)

`../api/` holds the 8.0.2 admin-API client and class tooling (stdlib-only
Python):

- `scripts/faig_api.sh <instance> <command...>` -- exports `FAIG_API_URL`
  (IAP-tunneled admin API) and `FAIG_BASE_URL` (the students' URL), then runs
  any command, e.g. `faig_api.sh 1 python3 ../api/faig802.py status`
- `scripts/approver.sh install <instance> <vars.yml> <roster.csv>` -- installs
  an on-VM systemd service that auto-approves student changes for the roster's
  workspaces (survives the instructor's laptop; starts at boot)
- `faig_class.py --vars <vars.yml> --roster <roster.csv> <status|score|handout|...>`
  -- one idempotent setup / health-check / scorecard pass over every student

Rosters and vars files carry student identities and credentials: they are
gitignored (`class*.csv`, `vars.*.yml`) -- keep them local.

## Troubleshooting

- **`make up` can't find a GPU**: L4s are scarce. `make gpu-zones --probe`
  lists stock; widen `GPU_REGIONS` or let the VM relocate (`FAIG_RELOCATE=1`).
- **Quota errors on hold**: every hold counts against `NVIDIA_L4_GPUS` (per
  region) and `GPUS_ALL_REGIONS`; set `MAX_PARALLEL=1` and retry.
- **IAP tunnel refused**: the IAP API is enabled by the stack
  (`google_project_service.iap`); check `gcloud iap` permissions
  (`roles/iap.tunnelResourceAccessor`) for your user.
- **License "In Use"**: serials are single-occupancy; the pool rotation
  quarantines and takes the next one. Check the ledger:
  `python3 -m tools.faig_license_pool status`.
- **`cannot read <file>` on a .lic**: an OneDrive online-only placeholder --
  right-click → *Always Keep on This Device*.
- **UI cert warnings**: set `FAIG_ACME_EMAIL` (Let's Encrypt) or accept the
  self-signed fallback; `ready.sh` re-issues the cert on every up.
