# Golden Base Image — Built Externally

The golden base image is **no longer built in CI**. It is built on `nllei01gpu01`
using the dedicated tooling at `/srv/cubeos-base-builder/`.

## Why?

Building the golden base requires ~20 minutes of heavy QEMU ARM64 emulation
(apt-get installing ~60 packages inside an ARM64 chroot on an x86_64 host).
This is unreliable and slow inside the CI runner's Docker-in-Docker environment.

The GPU VM (`nllei01gpu01`) has native QEMU support, more RAM, and more CPU,
making it the right place for this heavy operation.

## How to rebuild the golden base

```bash
ssh root@nllei01gpu01
cd /srv/cubeos-base-builder

# Edit package list if needed
vim base-image/scripts/01-ubuntu-base.sh

# Build and upload to GitLab Package Registry
./build.sh

# Or build only (no upload)
./build.sh --build-only
```

The `build.sh` script:
1. Runs `packer-builder-arm` in a privileged Docker container
2. Installs all system packages via QEMU ARM64 emulation
3. Compresses with `xz -6 -T0`
4. Uploads to GitLab Generic Package Registry as `cubeos-base/1.0.0`

## When to rebuild

- Monthly (security updates)
- When the package list changes in `01-ubuntu-base.sh`
- When upgrading Ubuntu base version

## Where the CI finds it

The release pipeline (`.gitlab-ci.yml`) downloads the base from:
```
${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/generic/cubeos-base/${BASE_VERSION}/${BASE_IMAGE_NAME}.img.xz
```

## Files in this directory

The `cubeos-base.pkr.hcl` and `scripts/` are kept as **reference copies**.
The canonical versions live on `nllei01gpu01:/srv/cubeos-base-builder/base-image/`.
If you change the package list, update it there and rebuild.
