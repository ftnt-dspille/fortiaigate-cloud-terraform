.PHONY: help up down health license ssh tunnel \
        create deploy start stop test status reserve unreserve gpu-zones place converge \
        init plan-gpu apply-gpu plan-build apply-build build image gpu setup destroy
.DEFAULT_GOAL := help

TF = terraform

# Local, gitignored settings (.env*), e.g. FAIG_LICENSE_POOL=/path/to/Lab Licenses/FAIG
# FAIG_ACME_EMAIL=<email> enables a real Let's Encrypt cert (via cert-manager + Cloud DNS)
-include .env
export FAIG_LICENSE_POOL FAIG_ACME_EMAIL FAIG_DNS_SA_SECRET

# INSTANCE selects which FAIG VM to target (1, 2, 3, ...). Default 1.
# COUNT=N runs N VMs: it is remembered (placement.tfvars.json), and up/start/stop
# then act on all N. Zones are never set by hand -- gpu_place.sh picks them.
# Each instance gets its own IAP local ports to allow concurrent access.
INSTANCE ?= 1
PREFIX := $(or $(shell sed -nE 's/^name_prefix[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' terraform.tfvars 2>/dev/null),faig)
TARGETS = $(if $(COUNT),$(shell seq 1 $(COUNT)),$(INSTANCE))
VM = $(PREFIX)-$(INSTANCE)
ZONE = $(shell $(TF) output -json zones 2>/dev/null | python3 -c "import sys,json; v=json.load(sys.stdin); print(v[$(INSTANCE)-1] if len(v)>=$(INSTANCE) else '')" 2>/dev/null)
# Per-instance IAP ports: SSH 2220+N, HTTP 8080+N-1, HTTPS 8440+N
SSH_PORT = $(shell echo $$((2220 + $(INSTANCE))))
HTTP_PORT = $(shell echo $$((8079 + $(INSTANCE))))
HTTPS_PORT = $(shell echo $$((8439 + $(INSTANCE))))
export SSH_PORT HTTP_PORT GPU_REGIONS FAIG_RELOCATE KEEP_GPU_HOLD RETRY_MIN STAY_MIN MOVE MAX_PARALLEL

# placement.tfvars.json (scripts/gpu_place.sh) carries vm_count + each VM's zone,
# where its GPU is held; it comes after gpu.tfvars so it wins.
GPU_VARS = -var-file=gpu.tfvars $(if $(wildcard placement.tfvars.json),-var-file=placement.tfvars.json)

# ── primary commands (make help) ─────────────────────────────────────────────
# INSTANCE=N targets the Nth VM (default 1). From the repo root, `make faig-up`
# runs `up` and then sets up the students; this file is the VM half.

help:
	@echo "cloud FortiAIGate (INSTANCE=$(INSTANCE)$(if $(COUNT), COUNT=$(COUNT))):"
	@echo "  make up       any state -> ready: hold a GPU (any zone), create/start/relocate,"
	@echo "                deploy, install the GPU driver if missing (auto reboot-retry),"
	@echo "                bootstrap org+admin, license (pool or LICENSE=), 11 checks"
	@echo "  make up COUNT=N   run N VMs (remembered); zones, IPs, DNS and certs follow on their own"
	@echo "  make down     stop all VMs, release GPU holds + static IPs (keeps disks + image)"
	@echo "  make health   read-only pod/node health of every VM"
	@echo "  make license  license from \$$FAIG_LICENSE_POOL (.env), or FILE=<file.lic>"
	@echo "  make ssh | make tunnel [http|https|<port>]"
	@echo "internals: create deploy start stop test status reserve unreserve gpu-zones place converge"
	@echo "           plan-gpu apply-gpu build image gpu setup destroy"
	@echo "knobs: GPU_REGIONS=us- (zone search; empty = worldwide)  FAIG_RELOCATE=0 (never move a stopped VM)"
	@echo "       KEEP_GPU_HOLD=1 on stop (guarantee the next start; bills while stopped)"
	@echo "       make up MOVE=N   rebuild VM N in another zone now (drain a zone)"

# up: any state -> ready, for INSTANCE (or all COUNT VMs). converge holds the
# GPUs and lets terraform create missing VMs / move relocated ones (the static IP
# and DNS name follow); ready.sh starts, redeploys if the VM changed, licenses,
# and runs the 11 checks.
up: converge
	@for n in $(TARGETS); do ./scripts/ready.sh $(PREFIX)-$$n || exit 1; done
	-./scripts/gpu_place.sh --hold

# down: stop all VMs, release every GPU hold and static IP (each in its region).
# Keeps disks + saved image; `make up` recreates the IPs and repoints DNS.
# `make destroy` deletes everything.
down:
	./scripts/stop.sh
	./scripts/gpu_place.sh --release-all
	@gcloud compute addresses list --filter="name~^$(PREFIX)-[0-9]+-ip$$" --format='value(name,region.basename())' 2>/dev/null | \
	while read -r ip region; do \
		echo "Releasing static IP $$ip ($$region)..."; \
		gcloud compute addresses delete "$$ip" --region="$$region" --quiet || true; \
	done
	@echo ""
	@echo "Teardown complete. VMs stopped, GPU holds + static IPs released."
	@echo "Disks and saved image are preserved."
	@echo "Run 'make up' to bring it back."

health:
	./scripts/health.sh $(VM)

license:
	$(if $(FILE),./scripts/license.sh "$(FILE)" $(VM),./scripts/license_pool.sh $(VM))

tunnel:
	./scripts/tunnel.sh $(if $(filter-out tunnel,$(MAKECMDGOALS)),$(filter-out tunnel,$(MAKECMDGOALS)),ssh) $(VM)

ssh:
	gcloud compute ssh --tunnel-through-iap --zone=$(ZONE) $(VM)

# ── internals ────────────────────────────────────────────────────────────────

# place: hold a GPU for every VM that is missing or (targeted and) stopped, in a
# zone that has one, and write placement.tfvars.json. See scripts/gpu_place.sh.
place:
	@test -f gpu.tfvars || { echo "gpu.tfvars missing -- copy gpu.tfvars.example"; exit 1; }
	ONLY="$(TARGETS)" COUNT="$(COUNT)" ./scripts/gpu_place.sh

# converge: place, then terraform onto the held GPUs; drop holds whose VM is gone
# (vm_count shrank). Running VMs keep theirs -- free while they run.
converge: place
	$(TF) apply -auto-approve $(GPU_VARS)
	./scripts/gpu_place.sh --release

apply-gpu: converge

create: converge
	./scripts/deploy_gpu.sh $(VM)

deploy: converge
	./scripts/deploy_gpu.sh $(VM)

start: converge
	@for n in $(TARGETS); do ./scripts/start.sh $(PREFIX)-$$n || exit 1; done

stop:
	./scripts/stop.sh $(if $(COUNT),,$(VM))

test:
	./scripts/test.sh $(VM)

status:
	$(TF) output

# reserve: hold the running VM(s)' GPU now. Usually not needed: up does it.
reserve:
	./scripts/gpu_place.sh --hold $(TARGETS)

unreserve:
	./scripts/gpu_place.sh --release-all

gpu-zones:
	./scripts/gpu_zones.sh $(or $(REGION),us-) $(if $(PROBE),--probe)

init:
	$(TF) init

plan-gpu:
	$(TF) plan $(GPU_VARS)

# image-build path (a new baseline image), not used to run a class
plan-build:
	$(TF) plan

apply-build:
	$(TF) apply -auto-approve

build: apply-build
	./scripts/copy_faig_images.sh
	./scripts/build.sh

image:
	./scripts/make_image.sh

gpu: apply-gpu
	./scripts/enable_gpu.sh

setup:
	./scripts/setup.sh

destroy:
	$(TF) destroy -auto-approve
	./scripts/gpu_place.sh --release-all
	rm -f placement.tfvars.json
