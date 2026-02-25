# =============================================================================
# CubeOS Image Builder — Makefile
# =============================================================================
# Quick commands for local image building.
#
# Prerequisites:
#   - Golden base image in GitLab Package Registry (see platforms/raspberrypi/base-image/README.md)
#   - Docker with privileged mode support
#   - skopeo (for ARM64 image downloads)
#
# Usage:
#   make download-base  — Download golden base from Package Registry
#   make images         — Download ARM64 Docker images
#   make build          — Build the full image
#   make compress       — Compress with xz
#   make all            — Full pipeline (download-base + images + build + compress)
#   make clean          — Remove build artifacts
# =============================================================================

VERSION       ?= 0.2.0-beta.01
IMAGE_NAME     = cubeos-$(VERSION)-arm64
DOCKER_IMAGES  = docker-images

# Golden base image settings
BASE_VERSION  ?= 1.0.0
BASE_NAME      = cubeos-base-ubuntu24.04.3-arm64
BASE_FILE      = cubeos-base.img.xz

# GitLab settings — override with environment variables for your instance
GITLAB_URL    ?= https://gitlab.example.com
GITLAB_PROJECT ?= products%2Fcubeos%2Freleases

.PHONY: all download-base images build compress clean help

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-17s\033[0m %s\n", $$1, $$2}'

all: download-base images build compress  ## Full pipeline

download-base:  ## Download golden base image from Package Registry
	@if [ -f "$(BASE_FILE)" ]; then \
		echo "Base image already exists: $(BASE_FILE)"; \
		ls -lh $(BASE_FILE); \
	else \
		echo "=== Downloading golden base image ==="; \
		echo "Source: $(GITLAB_URL) / cubeos-base/$(BASE_VERSION)"; \
		if [ -z "$$GITLAB_PAT" ]; then \
			echo "ERROR: Set GITLAB_PAT environment variable"; \
			echo "  export GITLAB_PAT=glpat-xxxxx"; \
			exit 1; \
		fi; \
		curl --fail \
			--header "PRIVATE-TOKEN: $$GITLAB_PAT" \
			--connect-timeout 30 \
			--max-time 600 \
			--retry 3 \
			-o $(BASE_FILE) \
			"$(GITLAB_URL)/api/v4/projects/$(GITLAB_PROJECT)/packages/generic/cubeos-base/$(BASE_VERSION)/$(BASE_NAME).img.xz"; \
		ls -lh $(BASE_FILE); \
	fi

images:  ## Download ARM64 Docker images via skopeo
	@echo "=== Downloading ARM64 Docker images ==="
	chmod +x skopeo/download-images.sh
	./skopeo/download-images.sh $(DOCKER_IMAGES)

build: $(BASE_FILE) $(DOCKER_IMAGES)  ## Build the image with Packer
	@echo "=== Building CubeOS $(VERSION) image ==="
	chmod +x platforms/raspberrypi/scripts/*.sh shared/scripts/*.sh firstboot/*.sh
	docker run --rm --privileged \
		-v /dev:/dev \
		-v $(PWD):/build \
		-w /build \
		mkaczanowski/packer-builder-arm:latest \
		build \
		-var "version=$(VERSION)" \
		-var "base_image_url=file:///build/$(BASE_FILE)" \
		-var "base_image_checksum_type=none" \
		platforms/raspberrypi/packer.pkr.hcl
	@echo "=== Image built: $(IMAGE_NAME).img ==="
	ls -lh $(IMAGE_NAME).img

compress: $(IMAGE_NAME).img  ## Compress image with xz
	@echo "=== Compressing $(IMAGE_NAME).img ==="
	@# Zerofree for better compression (requires root)
	-sudo bash -c '\
		LOOPDEV=$$(losetup -fP --show $(IMAGE_NAME).img); \
		e2fsck -fy $${LOOPDEV}p2 2>/dev/null || true; \
		zerofree $${LOOPDEV}p2 2>/dev/null || true; \
		losetup -d $$LOOPDEV'
	xz -6 -T0 -v $(IMAGE_NAME).img
	sha256sum $(IMAGE_NAME).img.xz > $(IMAGE_NAME).img.xz.sha256
	@echo "=== Compressed ==="
	ls -lh $(IMAGE_NAME).img.xz
	cat $(IMAGE_NAME).img.xz.sha256

clean:  ## Remove build artifacts
	rm -f $(IMAGE_NAME).img $(IMAGE_NAME).img.xz $(IMAGE_NAME).img.xz.sha256 $(IMAGE_NAME).img.xz.md5
	rm -f $(BASE_FILE)
	rm -rf $(DOCKER_IMAGES)
	rm -f packer_cache/*
	@echo "Cleaned."

$(BASE_FILE):
	@echo "Golden base image not found. Run 'make download-base' first."
	@exit 1

$(DOCKER_IMAGES):
	@echo "Docker images not found. Run 'make images' first."
	@exit 1
