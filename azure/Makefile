.PHONY: init plan apply build image gpu stop start destroy status

TF = terraform

# Local, gitignored settings (.env), e.g. FAIG_LICENSE_POOL=/path/to/pool --
# same format as gcp/.env; the Makefile loads it and exports the FAIG_* vars
# to the recipe shells, so the scripts see them without you sourcing anything.
-include .env
export FAIG_LICENSE_POOL FAIG_ACME_EMAIL FAIG_DNS_SA_SECRET FAIG_ADMIN_PASS FAIG_KEYCHAIN_ACCOUNT FAIG_LICENSE_IN_USE
export FAIG_TARS_HOST FAIG_TARS_PORT FAIG_TARS_USER FAIG_TARS_DIR

IP = $(shell $(TF) output -raw public_ip 2>/dev/null)

init:
	$(TF) init

plan:
	$(TF) plan

apply:
	$(TF) apply -auto-approve

build: apply
	./scripts/copy_faig_images.sh $(IP)
	./scripts/build.sh $(IP)

image:
	./scripts/make_image.sh

gpu: apply
	./scripts/enable_gpu.sh $(IP)

stop:
	./scripts/stop.sh

start:
	./scripts/start.sh

status:
	$(TF) output

destroy:
	$(TF) destroy -auto-approve
