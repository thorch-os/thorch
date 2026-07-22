SHELL := /usr/bin/env bash

IMAGE ?= output/thorch-arch-aarch64.img
DEVICE ?=
THORCH_CONFIG ?= config/thorch.conf
ROCKNIX_REF ?= $(shell bash -c 'source "$(THORCH_CONFIG)" >/dev/null 2>&1; printf "%s" "$$ROCKNIX_REF"')
BOOT_DIR ?=
ROOT_DIR ?=
KERNEL_REF ?= $(ROCKNIX_REF)
THORCH_SUDO_ENV := THORCH_USER,THORCH_PASSWORD,THORCH_ENABLE_SSH,THORCH_IMAGE_SIZE,THORCH_IMAGE_AUTO_HEADROOM,THORCH_ROOT_FSTYPE,THORCH_BTRFS_MOUNT_OPTIONS,THORCH_USER_CACHE_TMPFS_SIZE,THORCH_BOOT_SIZE,THORCH_DEFAULT_SESSION,THORCH_IMAGE_PACKAGES,THORCH_BUILD_DIR,THORCH_ROOTFS_RUNNER,THORCH_OUTPUT_DIR,THORCH_LOCAL_REPO_DIR,THORCH_ROCKNIX_DIR,THORCH_FIRMWARE_DIR,THORCH_ROCKNIX_KERNEL_DIR,THORCH_ROCKNIX_RUNTIME_DIR,THORCH_KERNEL_SOURCE_BUILD,THORCH_WAYDROID_KERNEL_REQUIRED,THORCH_KERNEL_REPO,THORCH_KERNEL_REF,THORCH_KERNEL_TARBALL_URL,THORCH_KERNEL_TARBALL_SHA256,THORCH_KERNEL_CONFIG,THORCH_KERNEL_CONFIG_FRAGMENT,THORCH_KERNEL_PATCH_DIRS,THORCH_KERNEL_DTS_DIR,THORCH_KERNEL_SOURCE_DIR,THORCH_KERNEL_BUILD_DIR,THORCH_KERNEL_CROSS_COMPILE,THORCH_KERNEL_JOBS,THORCH_PACKAGE_JOBS,ROCKNIX_REF,ROCKNIX_REPO,ROCKNIX_KERNEL_SOURCE,ROCKNIX_KERNEL_RELEASE,ROCKNIX_KERNEL_PLATFORM,ROCKNIX_KERNEL_IMAGE_URL,ROCKNIX_KERNEL_SHA256_URL,ROCKNIX_KERNEL_ALLOW_UNVERIFIED,ROCKNIX_KERNEL_CACHE_DIR,ALARM_ROOTFS_URL,ALARM_ROOTFS_SIG_URL,ALARM_ROOTFS_SHA256,ALARM_ROOTFS_SIGNING_KEYS,ALARM_ROOTFS_KEYRING_URL,ALARM_ROOTFS_KEYSERVER,ALARM_ROOTFS_KEY_FETCH_TIMEOUT,ALARM_MIRRORS,ALARM_MIRROR
THORCH_SUDO := sudo --preserve-env=$(THORCH_SUDO_ENV)

comma := ,
THORCH_DOCKER_IMAGE ?= ghcr.io/thorch-os/thorch-build:latest
THORCH_DOCKER_BASE_IMAGE ?= $(shell if uname -m | grep -Eq '^(arm64|aarch64)$$'; then echo menci/archlinuxarm:base-devel; else sed -n 's/^ARG THORCH_DOCKER_BASE_IMAGE=//p' Dockerfile; fi)
THORCH_DOCKER_CMD ?= $(shell if command -v docker >/dev/null 2>&1; then echo docker; elif command -v podman >/dev/null 2>&1; then echo podman; fi)
THORCH_DOCKER_WORKDIR ?= /work
THORCH_DOCKER_RUN_ARGS ?=
THORCH_DOCKER_INTERACTIVE ?= $(shell [ -t 0 ] && echo -it)
THORCH_DOCKER_ENV := $(subst $(comma), ,$(THORCH_SUDO_ENV))
THORCH_DOCKER_ENV_ARGS := $(foreach var,$(THORCH_DOCKER_ENV),--env $(var))
THORCH_DOCKER_FIX_OWNERSHIP ?= 1
HOST_UID ?= $(shell id -u)
HOST_GID ?= $(shell id -g)

# macOS bind mounts are normally case-insensitive, but the Arch rootfs contains
# case-distinct paths. Keep chroots and build caches on a native Docker volume;
# release artifacts still land in the repository's output directory.
ifeq ($(shell uname -s),Darwin)
THORCH_DOCKER_BUILD_DIR ?= /thorch-build
THORCH_DOCKER_BUILD_VOLUME ?= thorch-build-$(shell printf '%s' '$(CURDIR)' | cksum | awk '{print $$1}')
THORCH_DOCKER_BUILD_ARGS := --volume "$(THORCH_DOCKER_BUILD_VOLUME):$(THORCH_DOCKER_BUILD_DIR)" --env THORCH_BUILD_DIR="$(THORCH_DOCKER_BUILD_DIR)"
else
THORCH_DOCKER_BUILD_ARGS :=
endif

docker-audit docker-check docker-test docker-test-rust: THORCH_DOCKER_FIX_OWNERSHIP=0

.PHONY: help doctor ci audit sync firmware kernel import-kernel packages packages-userspace build fast nightly test test-rust check write clean docker-image-build docker-image-pull docker-shell

help:
	@printf '%s\n' \
	  'Thorch build targets:' \
	  '  make docker-image-build            Build the local Thorch Docker builder image' \
	  '  make docker-image-pull             Pull the Thorch Docker builder image' \
	  '  make docker-<target>               Run any make target inside the Docker builder' \
	  '  make docker-shell                  Open a shell inside the Docker builder' \
	  '  make doctor                        Diagnose the contributor environment' \
	  '  make ci                            Run the required rootless pull-request checks' \
	  '  make sync                         Sync ROCKNIX sources and firmware' \
	  '  make firmware                     Sync firmware only' \
	  '  make kernel                       Sync ROCKNIX runtime, then source-build BinderFS Thor kernel' \
	  '  make import-kernel BOOT_DIR=... ROOT_DIR=... [KERNEL_REF=...]' \
	  '  make packages                     Build all local packages' \
	  '  make packages-userspace           Build local packages except linux-thorch' \
	  '  make build                        Build output/thorch-arch-aarch64.img' \
	  '  make fast                         Fast rebuild after one full build' \
	  '  make nightly                      Run audit, tests, build, and image check' \
	  '  make test                         Run local test suites' \
	  '  make test-rust                    Run Rust component unit tests' \
	  '  make check [IMAGE=...]            Validate a raw image or block device' \
	  '  make write DEVICE=/dev/sdX        Write IMAGE to removable media' \
	  '  make audit                        Run release/source checks' \
	  '  make clean                        Remove generated build/output artifacts'

define thorch_docker_run
	@test -n "$(THORCH_DOCKER_CMD)" || { echo 'docker or podman is required'; exit 2; }
	$(THORCH_DOCKER_CMD) run --privileged --rm $(THORCH_DOCKER_INTERACTIVE) \
	  --security-opt label=disable \
	  $(THORCH_DOCKER_ENV_ARGS) \
	  --env HOST_UID="$(HOST_UID)" \
	  --env HOST_GID="$(HOST_GID)" \
	  --volume "$(CURDIR):$(THORCH_DOCKER_WORKDIR)" \
	  $(THORCH_DOCKER_BUILD_ARGS) \
	  --workdir "$(THORCH_DOCKER_WORKDIR)" \
	  $(THORCH_DOCKER_RUN_ARGS) \
	  "$(THORCH_DOCKER_IMAGE)" \
	  bash -lc 'set -euo pipefail; git config --global --add safe.directory "$(THORCH_DOCKER_WORKDIR)" 2>/dev/null || true; status=0; $(1) || status=$$?; if [[ "$(THORCH_DOCKER_FIX_OWNERSHIP)" == 1 ]]; then ./scripts/fix-container-ownership.sh "$${HOST_UID}" "$${HOST_GID}"; fi; exit "$$status"'
endef

docker-image-build:
	@test -n "$(THORCH_DOCKER_CMD)" || { echo 'docker or podman is required'; exit 2; }
	$(THORCH_DOCKER_CMD) build --pull \
	  --build-arg THORCH_DOCKER_BASE_IMAGE="$(THORCH_DOCKER_BASE_IMAGE)" \
	  --tag "$(THORCH_DOCKER_IMAGE)" --file Dockerfile .

docker-image-pull:
	@test -n "$(THORCH_DOCKER_CMD)" || { echo 'docker or podman is required'; exit 2; }
	$(THORCH_DOCKER_CMD) pull "$(THORCH_DOCKER_IMAGE)"

docker-shell:
	$(call thorch_docker_run,bash)

docker-%:
	$(call thorch_docker_run,make $* IMAGE="$(IMAGE)" DEVICE="$(DEVICE)" ROCKNIX_REF="$(ROCKNIX_REF)" BOOT_DIR="$(BOOT_DIR)" ROOT_DIR="$(ROOT_DIR)" KERNEL_REF="$(KERNEL_REF)")

doctor:
	./scripts/doctor.sh

ci:
	./scripts/ci.sh

audit:
	./scripts/audit-release.sh

sync:
	./scripts/sync-rocknix-sources.sh --ref "$(ROCKNIX_REF)" --with-firmware

firmware:
	./scripts/sync-rocknix-firmware.sh --ref "$(ROCKNIX_REF)"

kernel:
	$(THORCH_SUDO) ./scripts/sync-rocknix-kernel.sh

import-kernel:
	@test -n "$(BOOT_DIR)" || { echo 'BOOT_DIR is required'; exit 2; }
	@test -n "$(ROOT_DIR)" || { echo 'ROOT_DIR is required'; exit 2; }
	./scripts/import-rocknix-kernel.sh --boot-dir "$(BOOT_DIR)" --root-dir "$(ROOT_DIR)" --ref "$(KERNEL_REF)"
	./scripts/import-rocknix-runtime.sh --root-dir "$(ROOT_DIR)" --ref "$(KERNEL_REF)"
	@if [[ "$${THORCH_KERNEL_SOURCE_BUILD:-1}" != "0" ]]; then \
	  $(THORCH_SUDO) ./scripts/build-thorch-kernel.sh; \
	else \
	  echo 'skipping Thorch kernel source build; Waydroid BinderFS support is not guaranteed'; \
	fi

packages:
	$(THORCH_SUDO) ./scripts/build-packages.sh

packages-userspace:
	$(THORCH_SUDO) ./scripts/build-packages.sh --skip-kernel

build:
	$(THORCH_SUDO) ./scripts/build-image.sh

fast:
	$(THORCH_SUDO) ./scripts/build-image-fast.sh

nightly: audit test build
	$(MAKE) check IMAGE="$${THORCH_OUTPUT_DIR:-output}/thorch-arch-aarch64.img"

test:
	@set -e; \
	for test in tests/*.bash; do \
	  printf '== %s ==\n' "$$test"; \
	  bash "$$test"; \
	done

test-rust:
	./scripts/test-rust-components.sh

check:
	./scripts/check-thorch-image.sh "$(IMAGE)"

write:
	@test -n "$(DEVICE)" || { echo 'DEVICE is required, for example DEVICE=/dev/sdX'; exit 2; }
	./scripts/check-thorch-image.sh "$(IMAGE)"
	$(THORCH_SUDO) ./scripts/write-image.sh "$(IMAGE)" "$(DEVICE)"

clean:
	sudo rm -rf build output
