# =============================================================================
# CubeOS Image Builder — Makefile
# =============================================================================
# Quick commands for local image building.
# Usage:
#   make images      — Download ARM64 Docker images
#   make build       — Build the full image
#   make compress    — Compress with xz
#   make all         — Full pipeline (images + build + compress)
#   make clean       — Remove build artifacts
# =============================================================================

VERSION      ?= 0.1.0-alpha
IMAGE_NAME    = cubeos-$(VERSION)-arm64
DOCKER_IMAGES = docker-images

.PHONY: all images build compress clean help

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

all: images build compress  ## Full pipeline: download + build + compress

images:  ## Download ARM64 Docker images via skopeo
	@echo "=== Downloading ARM64 Docker images ==="
	chmod +x skopeo/download-images.sh
	./skopeo/download-images.sh $(DOCKER_IMAGES)

build: $(DOCKER_IMAGES)  ## Build the image with Packer
	@echo "=== Building CubeOS $(VERSION) image ==="
	chmod +x packer/scripts/*.sh firstboot/*.sh
	docker run --rm --privileged \
		-v /dev:/dev \
		-v $(PWD):/build \
		-w /build \
		mkaczanowski/packer-builder-arm:latest \
		build \
		-var "version=$(VERSION)" \
		packer/cubeos.pkr.hcl
	@echo "=== Image built: $(IMAGE_NAME).img ==="
	ls -lh $(IMAGE_NAME).img

compress: $(IMAGE_NAME).img  ## Compress image with xz
	@echo "=== Compressing $(IMAGE_NAME).img ==="
	@# Zerofree for better compression (requires root)
	-sudo bash -c '\
		LOOPDEV=$$(losetup -fP --show $(IMAGE_NAME).img); \
		zerofree $${LOOPDEV}p2 2>/dev/null || true; \
		losetup -d $$LOOPDEV'
	xz -6 -T0 -v $(IMAGE_NAME).img
	sha256sum $(IMAGE_NAME).img.xz > $(IMAGE_NAME).img.xz.sha256
	@echo "=== Compressed ==="
	ls -lh $(IMAGE_NAME).img.xz
	cat $(IMAGE_NAME).img.xz.sha256

clean:  ## Remove build artifacts
	rm -f $(IMAGE_NAME).img $(IMAGE_NAME).img.xz $(IMAGE_NAME).img.xz.sha256
	rm -rf $(DOCKER_IMAGES)
	rm -f packer_cache/*
	@echo "Cleaned."

$(DOCKER_IMAGES):
	@echo "Docker images not found. Run 'make images' first."
	@exit 1
