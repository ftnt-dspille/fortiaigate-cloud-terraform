# ansible-gpu-server

Ansible playbook that builds a single-node Kubernetes (k3s) stack on a Linux host and deploys:

- **llama.cpp** (`llama-server`) - single-model, OpenAI-compatible LLM server
- **Streamlit chatbot** - UI pre-wired to the in-cluster LLM
- **FortiAIGate (FAIG)** - staging files for an optional Helm-based deployment (licenses, values)

Supporting infrastructure: NFS export + dynamic provisioner, ingress-nginx with a shared self-signed default TLS cert, and an idempotent installer for k3s itself.

The host is reachable on a single external URL: `https://<host>/llm` for the LLM API and `https://<host>/chat` for the chatbot UI.

---

## Simple CPU Run

```bash
ansible-playbook -i inventory site.yml -k \
-e llamacpp_model_url=https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf \
-e llamacpp_model_alias=llama3.2:1b \
-e llamacpp_threads=12
```

## Quick start

```bash
# 1. Edit inventory/hosts.yml with your host's SSH details and primary interface.
# 2. (Optional) Customize behavior via env vars or -e overrides - see below.
# 3. Run the playbook.
ansible-playbook -i inventory site.yml

# Once it finishes:
#   https://<external_address>/chat        - chatbot UI
#   https://<external_address>/llm/v1/models - llama.cpp OpenAI-compatible API
```

The first run downloads a ~2.2 GB GGUF model file from HuggingFace; expect 5-15 minutes depending on link speed.

---

## Roles, in order (see `site.yml`)

| # | Role | What it does |
|-|-|-|
| 1 | `nfs` | Host-side NFS export consumed by the dynamic provisioner |
| 2 | `k3s` | Install k3s with Traefik/ServiceLB disabled, DNAT-aware TLS |
| 3 | `gpu` | *(optional, `gpu_enabled=true`)* Install NVIDIA driver + Container Toolkit + k8s device plugin |
| 4 | `helm` | Install Helm 3 + `python-kubernetes` for `kubernetes.core` modules |
| 5 | `ingress-nginx` | DaemonSet on hostNetwork, default-ssl-certificate wired in |
| 6 | `cert-manager` | *(optional)* Let's Encrypt via Google Cloud DNS (DNS-01), writes a trusted cert into the ingress default TLS secret |
| 7 | `nfs-provisioner` | Helm release providing the `nfs-client` StorageClass (default) |
| 8 | `llamacpp` | `llama-server` Deployment, hostPath PV, init-container model fetch, ingress at `/llm` |
| 9 | `chatbot` | Build local image, import into containerd, deploy + ingress at `/chat` |
| 10 | `fortiaigate` | Stage FAIG Helm chart tar + licenses + my-values.yaml in user's home |

### Selective runs

```bash
ansible-playbook -i inventory site.yml --tags base       # infra only (no apps)
ansible-playbook -i inventory site.yml --tags apps       # llamacpp + chatbot + faig
ansible-playbook -i inventory site.yml --tags llamacpp   # llama.cpp only
ansible-playbook -i inventory site.yml --tags chatbot    # rebuild + redeploy chatbot
ansible-playbook -i inventory site.yml --tags faig       # FAIG staging only
ansible-playbook -i inventory site.yml --tags ingress    # reapply ingress-nginx
ansible-playbook -i inventory site.yml --tags certmanager # issue/renew Let's Encrypt cert
ansible-playbook -i inventory site.yml --tags gpu        # GPU stack only (driver + toolkit + plugin)
```

---

## GPU support (NVIDIA)

CPU is the default. To run llama.cpp on an NVIDIA GPU, set `gpu_enabled: true`
under the host's `vars:` in `inventory/hosts.yml`:

```yaml
gpu_enabled: true
nvidia_driver_branch: "550"   # optional; defaults to "550" in group_vars/all.yml
```

When enabled, the `gpu` role:

1. Verifies an NVIDIA GPU is on the PCI bus (fails fast if not).
2. Installs the NVIDIA driver (`cuda-drivers-<branch>`) from NVIDIA's CUDA repo
   - Debian/Ubuntu and RHEL families both supported.
3. Installs the NVIDIA Container Toolkit (containerd runtime integration).
4. Restarts `k3s` so containerd reloads and picks up the `nvidia` runtime.
5. Applies the [NVIDIA k8s-device-plugin](https://github.com/NVIDIA/k8s-device-plugin)
   DaemonSet (advertises `nvidia.com/gpu` as a schedulable resource).
6. Drives `llamacpp_gpu_enabled` → llama.cpp uses the `server-cuda` image,
   passes `--n-gpu-layers`, and requests `nvidia.com/gpu` from the scheduler.

**First-run reboot:** A fresh driver install almost always requires a reboot
for the kernel module to load. The role detects this and aborts with a clear
message - reboot the host, then re-run the playbook (it's idempotent).

**Verification after a successful run:**

```bash
nvidia-smi                                                 # on the host
kubectl describe node | grep nvidia.com/gpu                # capacity ≥ 1
kubectl -n llamacpp logs deploy/llamacpp | head -40        # look for "CUDA0"
```

To force-disable on a GPU host (e.g. for CPU benchmarking), override
`llamacpp_gpu_enabled: false` while leaving `gpu_enabled: true`.

---

## Environment variables (controller side)

Variables read by Ansible from the shell that runs `ansible-playbook`. Set them before running, or pass values inline.

| Env var | Effect | Default |
|-|-|-|
| `LLAMACPP_MODEL_URL` | Direct HuggingFace GGUF URL. Must use `/resolve/main/` (not `/blob/main/`). Filename basename is what llama-server loads. | `bartowski/Llama-3.2-3B-Instruct-GGUF/Llama-3.2-3B-Instruct-Q4_K_M.gguf` |
| `LLAMACPP_API_KEY` | When non-empty, llama-server is launched with `--api-key` and `/v1/*` requires `Authorization: Bearer <key>`. The chatbot inherits the same value automatically. | empty (open, lab mode) |
| `LLM_API_KEY` | Chatbot API key for external providers (OpenAI, Azure, FortiAIGate). Takes precedence over `LLAMACPP_API_KEY`. | empty (falls back to `LLAMACPP_API_KEY`, then to a harmless sentinel) |

For anything not exposed as an env var, use `-e <var>=<value>` on the `ansible-playbook` command line. See **All overridable variables** below.

---

## Examples

### Override the default LLM model

The default GGUF is `Llama-3.2-3B-Instruct-Q4_K_M`. To swap to a different model, point `LLAMACPP_MODEL_URL` at the new GGUF. The init container detects the change, downloads the new file, and (when `llamacpp_prune_old_models: true`) deletes the previous one after a successful rollout.

**Via env var (recommended for ad-hoc swaps):**

```bash
# Smaller: Llama-3.2-1B for faster CPU-only inference
export LLAMACPP_MODEL_URL=https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf
ansible-playbook -i inventory site.yml --tags llamacpp,chatbot
```

**Via `-e` override (one-shot, no env state):**

```bash
ansible-playbook -i inventory site.yml --tags llamacpp,chatbot \
  -e llamacpp_model_url=https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf \
  -e llamacpp_model_alias=qwen2.5:3b
```

If you change the alias, include `--tags chatbot` so the ConfigMap's `LLM_MODEL` value matches what `/v1/models` returns (otherwise chat completions get HTTP 404).

**For larger models** (7B/8B Q4_K_M ≈ 4.7 GB), also raise the memory limit:

```bash
ansible-playbook -i inventory site.yml --tags llamacpp \
  -e llamacpp_model_url=https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf \
  -e llamacpp_model_alias=llama3.1:8b \
  -e '{"llamacpp_resources":{"requests":{"cpu":"1","memory":"6Gi"},"limits":{"cpu":"4","memory":"12Gi"}}}'
```

### Override the number of CPUs for llama.cpp

There are two related knobs:

- **`llamacpp_threads`** (default `4`) - value passed to `llama-server --threads`. This is what controls inference parallelism. On x86 CPUs, performance scales linearly up to ~6-10 threads before memory bandwidth saturates; hyperthreads rarely help. Pick a value close to the number of **physical cores** on one socket.
- **`llamacpp_resources.requests.cpu` / `.limits.cpu`** (default `"1"` / `"4"`) - Kubernetes CPU requests/limits. The pod will be throttled if it exceeds the limit, so set the limit at or above `llamacpp_threads`.

**Both together** (typical case - give the pod more CPU and use it):

```bash
# 8 threads, scheduled with 2 CPU request and 8 CPU limit
ansible-playbook -i inventory site.yml --tags llamacpp \
  -e llamacpp_threads=8 \
  -e '{"llamacpp_resources":{"requests":{"cpu":"2","memory":"4Gi"},"limits":{"cpu":"8","memory":"8Gi"}}}'
```

**Threads only** (keep the K8s limits, just internal threading):

```bash
ansible-playbook -i inventory site.yml --tags llamacpp -e llamacpp_threads=6
```

**Why both?** Even with `--threads 8`, Kubernetes will CFS-throttle the pod once it exceeds `limits.cpu`, so raising one without the other wastes capacity.

### Enable API-key enforcement on llama-server

The default install is open - anyone on the network who can reach `https://<host>/llm` can use the LLM. To require Bearer auth on `/v1/*`:

```bash
export LLAMACPP_API_KEY="$(openssl rand -hex 24)"
ansible-playbook -i inventory site.yml --tags llamacpp,chatbot

# llama-server now enforces:
curl -fkSs https://<host>/llm/v1/models                                       # 401
curl -fkSs -H "Authorization: Bearer $LLAMACPP_API_KEY" https://<host>/llm/v1/models  # JSON

# The chatbot Secret is updated to use the same key - UI works without manual config.
```

`/health` stays open so K8s probes keep working.

### Point the chatbot at an external provider (OpenAI, Azure, FAIG)

```bash
export LLM_API_KEY=sk-real-openai-key
ansible-playbook -i inventory site.yml --tags chatbot \
  -e chatbot_llm_endpoint=https://api.openai.com/v1 \
  -e chatbot_llm_model=gpt-4o-mini
```

`LLM_API_KEY` wins over `LLAMACPP_API_KEY`, so the chatbot can talk to OpenAI even when llama.cpp is still deployed in the cluster.

### Enable GPU support (NVIDIA)

> Prerequisite: the NVIDIA device plugin DaemonSet must already be installed on the node. **This playbook does not install it.**

```bash
ansible-playbook -i inventory site.yml --tags llamacpp -e llamacpp_gpu_enabled=true
```

This swaps the container image to `ghcr.io/ggml-org/llama.cpp:server-cuda`, adds `--n-gpu-layers 999` to the server args, and requests `nvidia.com/gpu: 1`.

---

## All overridable variables

Set via `-e <var>=<value>` on `ansible-playbook` or by editing `group_vars/all.yml`. Selection of the most useful:

### llama.cpp (`roles/llamacpp/`)

| Variable | Default | What it does |
|-|-|-|
| `llamacpp_model_url` | (3B Q4_K_M URL) | Direct GGUF URL; filename basename is what llama-server loads. |
| `llamacpp_model_alias` | `llama3.2:3b` | OpenAI `model` field clients send; what `/v1/models` returns. |
| `llamacpp_threads` | `4` | `llama-server --threads N` - internal inference parallelism. |
| `llamacpp_ctx_size` | `8192` | `--ctx-size N` - token context window. |
| `llamacpp_parallel` | `2` | `--parallel N` - concurrent request slots. |
| `llamacpp_resources` | `{requests:{cpu:1,memory:4Gi}, limits:{cpu:4,memory:8Gi}}` | Pod CPU/memory requests and limits. |
| `llamacpp_gpu_enabled` | `false` | Toggle CUDA image + `nvidia.com/gpu` request. |
| `llamacpp_gpu_count` | `1` | Number of GPUs to request when GPU is enabled. |
| `llamacpp_api_key` | `""` (env: `LLAMACPP_API_KEY`) | When non-empty, enforce `--api-key` Bearer auth on `/v1/*`. |
| `llamacpp_storage_size` | `30Gi` | PV size at `/var/lib/llamacpp`. |
| `llamacpp_ingress_path` | `/llm` | External path under ingress. |
| `llamacpp_prune_old_models` | `true` | After successful rollout, delete `*.gguf` files that aren't the current one. |

### Chatbot (`roles/chatbot/`)

| Variable | Default | What it does |
|-|-|-|
| `chatbot_llm_endpoint` | (in-cluster llamacpp URL) | OpenAI-compatible `/v1` endpoint the chatbot calls. |
| `chatbot_llm_model` | `{{ llamacpp_model_alias }}` | Default `model` string in the UI. |
| `chatbot_llm_api_key` | (env: `LLM_API_KEY` → `llamacpp_api_key` → sentinel) | API key the chatbot sends. |
| `chatbot_llm_tls_verify` | `"false"` | TLS verification for the upstream LLM (in-cluster HTTPS uses self-signed). |
| `chatbot_ingress_path` | `/chat` | External path under ingress. |
| `chatbot_bedrock_kb_id` | `""` | AWS Bedrock Knowledge Base ID (optional). |
| `chatbot_bedrock_model_id` | `""` | AWS Bedrock model ID fallback in the UI. |

### Infrastructure

| Variable | Default | What it does |
|-|-|-|
| `external_address` | (primary iface IP) | Public/DNAT'd address. Set in `inventory/hosts.yml` for DNAT setups. |
| `k3s_version` | `v1.31.4+k3s1` | k3s release pinned for reproducibility. |
| `ingress_default_tls_cn` | `{{ external_address }}` | CN on the shared self-signed cert. |
| `ingress_default_tls_validity_days` | `3650` | Cert validity. |

### cert-manager / Let's Encrypt (optional)

| Variable | Default | What it does |
|-|-|-|
| `cert_manager_email` | `""` | ACME email (required to issue - also the Let's Encrypt TOS consent). |
| `cert_manager_acme_server` | `acme-v02.api.letsencrypt.org` | ACME directory. Use the staging server for non-production testing. |
| `cert_manager_dns_project` | `""` | GCP project owning the delegated zone (Google Cloud DNS solver). |
| `cert_manager_dns_zone` | `""` | Hosted zone name, e.g. `faig.example.com`. Optional - cert-manager auto-discovers the zone otherwise. |
| `cert_manager_dns_sa_secret` | `""` | Name of a Secret holding a service-account key JSON. Empty → uses Application Default Credentials (the VM's default compute SA must hold `roles/dns.admin`). |
| `cert_manager_cert_hostname` | `{{ external_address }}` | Hostname to issue the cert for (DNS-01). |
| `cert_manager_target_secret` | `ingress-default-tls` | Secret the cert is written into (the ingress default-ssl-certificate). |

The issued cert replaces the self-signed one, so the UI/chatbot present a
publicly-trusted cert. DNS-01 is used because the node is reachable on 443 only
from allowlisted CIDRs - Let's Encrypt's HTTP-01/TLS-ALPN validators can't reach
it. Requires the service account (or VM default) to be able to write a TXT
record in the delegated zone.

---

## Chatbot container env vars

These are set automatically by the `chatbot` role from the variables above. They're listed here for awareness when debugging - you don't need to set them manually.

| Container env | Source | Notes |
|-|-|-|
| `LLM_ENDPOINT` | ConfigMap, from `chatbot_llm_endpoint` | OpenAI-compatible base URL with `/v1` suffix. |
| `LLM_MODEL` | ConfigMap, from `chatbot_llm_model` | Default model in the sidebar input. |
| `LLM_TLS_VERIFY` | ConfigMap, from `chatbot_llm_tls_verify` | `"true"` / `"false"`. |
| `LLM_API_KEY` | Secret, from `chatbot_llm_api_key` | Bearer credential for the upstream LLM. |
| `AWS_REGION` | ConfigMap, from `chatbot_aws_region` | Bedrock region. |
| `BEDROCK_KNOWLEDGE_BASE_ID` | Secret, from `chatbot_bedrock_kb_id` | Optional KB id for retrieval. |
| `BEDROCK_MODEL_ID` | Secret, from `chatbot_bedrock_model_id` | Fallback model id in the UI. |

The Streamlit sidebar lets the user override endpoint, key, and model at runtime; those values are persisted in browser local storage per device.

---

## Teardown

```bash
ansible-playbook -i inventory teardown.yml                  # all apps
ansible-playbook -i inventory teardown.yml --tags llamacpp  # llama.cpp only
ansible-playbook -i inventory teardown.yml --tags chatbot   # chatbot only
ansible-playbook -i inventory teardown.yml --tags faig      # FAIG staging files only
```

**Preserved** on disk so a re-install reuses them:

- `/var/lib/llamacpp` - downloaded GGUF file (multi-GB)
- `/opt/ansible-chatbot` - chatbot source/build dir
- The chatbot's image in containerd

To wipe the GGUF too: `ssh <host> "rm -rf /var/lib/llamacpp/*"`.

The teardown is idempotent and never touches k3s itself, ingress-nginx, the NFS provisioner, or the host's storage classes.

---

## Verifying a deployment

```bash
# Pod health (inside the cluster)
kubectl -n llamacpp get pods
kubectl -n llamacpp exec deploy/llamacpp -- wget -qO- localhost:8080/health
kubectl -n llamacpp exec deploy/llamacpp -- wget -qO- localhost:8080/v1/models

# Chat completion through the pod (substitute model alias if you changed it)
kubectl -n llamacpp exec deploy/llamacpp -- sh -c '
  wget -qO- --header="Content-Type: application/json" \
    --post-data="{\"model\":\"llama3.2:3b\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" \
    localhost:8080/v1/chat/completions
'

# External via ingress
curl -fkSs https://<external_address>/llm/v1/models
curl -fkSs https://<external_address>/chat/_stcore/health

# Inspect what got rendered into the chatbot
kubectl -n chatbot get cm chatbot-config -o yaml
kubectl -n chatbot get secret chatbot-secrets -o jsonpath='{.data.LLM_API_KEY}' | base64 -d ; echo
```

---

## Project layout

```
ansible-gpu-server/
├── ansible.cfg                        # Ansible runtime config
├── site.yml                           # Main playbook (8 roles)
├── teardown.yml                       # Removes apps; leaves k3s + data intact
├── requirements.yml                   # Galaxy collection requirements
├── inventory/
│   └── hosts.yml                      # Per-host config (SSH, external_address)
├── group_vars/
│   └── all.yml                        # All defaults and env-var lookups
├── roles/
│   ├── k3s/                           # k3s install + DNAT-aware TLS SANs
│   ├── helm/                          # Helm 3 + python-kubernetes
│   ├── nfs/                           # Host NFS export
│   ├── nfs-provisioner/               # Dynamic PV provisioner
│   ├── ingress-nginx/                 # Helm release + shared self-signed TLS
│   ├── llamacpp/                      # llama.cpp Deployment + Service + Ingress
│   ├── chatbot/                       # Build image + deploy Streamlit UI
│   └── fortiaigate/                   # Stage FAIG tar + licenses + my-values
├── files/
│   └── chatbot-src/                   # Streamlit source baked into chatbot image
├── licenses/                          # FAIG license files (uploaded by faig role)
└── FAIG_helm_chart-V*.tar             # FAIG Helm chart tar (staged by faig role)
```

---

## Notes on common pitfalls

- **GGUF URL must be `/resolve/main/`, not `/blob/main/`.** The `blob` form returns an HTML page; the init container will happily save that and llama-server will fail to load it.
- **Model alias mismatch returns HTTP 404.** Whatever the chatbot (or `curl`) puts in the `model` field of a chat-completion request must match `llamacpp_model_alias`. The playbook keeps them in sync automatically; only an issue if you override one without the other.
- **`/var/lib/llamacpp` fills up across model swaps** if you set `llamacpp_prune_old_models: false`. The default (`true`) garbage-collects after a successful rollout, but only files in `/var/lib/llamacpp` - not the container image cache.
- **Hyperthreads don't help llama-server.** On x86 CPUs, set `llamacpp_threads` to the physical-core count of one socket. Going beyond that mostly burns scheduling overhead.
