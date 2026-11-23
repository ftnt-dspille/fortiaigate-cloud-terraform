.PHONY: init plan apply build image gpu stop start destroy status

TF = terraform
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
