# forcicd — Makefile for the end-to-end lifecycle.
#
#   make up        provision VM + install stack + bootstrap (idempotent)
#   make images    build all 8 runner toolchain images
#   make image-X   build one image (X = ubuntu22, ubi8, ubi9, ubi10,
#                  alpine, debian11, debian12, bootc)
#   make status    print VM / forgejo / runner / mirror state
#   make verify    end-to-end smoke: API responds, runner online,
#                  mirror has the upstream HEAD, registry pushable
#   make logs      tail forgejo + runner logs
#   make ssh       SSH into the VM
#   make destroy   tear down the VM (and remove the DNS record)
#   make clean     destroy + remove build/ + remove proxmox.env
#
# All targets are idempotent. Re-running a finished step is a no-op.

SHELL := /usr/bin/env bash

VARIANTS := ubuntu22 ubi8 ubi9 ubi10 alpine debian11 debian12 bootc

.PHONY: up provision install bootstrap images status verify logs ssh \
        destroy clean help $(addprefix image-,$(VARIANTS))

help:
	@awk '/^# {2,}/ { sub(/^# /, "", $$0); print }' Makefile | head -30

up: provision install bootstrap
	@echo
	@echo "forcicd up. Forgejo: http://forcicd.g8.lo:3000/"

provision:
	./scripts/provision.sh

install:
	./scripts/install.sh

bootstrap:
	./scripts/bootstrap.sh

images:
	./scripts/build-runner-image.sh $(VARIANTS)

$(addprefix image-,$(VARIANTS)):
	./scripts/build-runner-image.sh $(subst image-,,$@)

status:
	./scripts/status.sh

verify:
	./scripts/verify.sh

logs:
	ssh fedora@forcicd.g8.lo 'sudo docker logs --tail 50 forgejo; echo "----- runner -----"; sudo docker logs --tail 50 forgejo-runner'

ssh:
	ssh fedora@forcicd.g8.lo

destroy:
	./scripts/destroy.sh

clean: destroy
	rm -rf build/ proxmox.env
