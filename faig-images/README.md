# Drop the FAIG install tars here

This directory holds the **FortiAIGate installation tars** — Fortinet-distributed
artifacts that are **not committed to this repo** (gitignored).

## What goes here

```
faig-images/
├── FAIG_<component>-<version>.tar   container-image tars (several)
├── FAIG_helm_chart-<version>.tar    the helm chart that ships in the bundle
└── ...
```

Obtain them from your Fortinet support channel / your own FortiAIGate
environment, then:

```bash
cp /path/to/FAIG_*.tar* faig-images/
```

## What happens with them

- `gcp/scripts/copy_faig_images.sh` and `azure/scripts/copy_faig_images.sh`
  **push this directory's tars up to the build VM** (through the GCP IAP
  tunnel, or straight to the Azure VM's public IP). This local-dir mode is
  picked automatically whenever tars are present here — no extra env vars.
- The build (`make build`) imports the container-image tars into k3s
  containerd and stages the bundle's helm chart.
- Alternatively, point `FAIG_TARS_HOST`/`FAIG_TARS_PORT` at any SSH-reachable
  host that already has the tars; the copy scripts then relay from there
  instead (useful when the tars live on a pod or a faster server).

The helm chart tar that `faig_seed/` needs for the playbook is a separate
file: see the root README, Prerequisites.
