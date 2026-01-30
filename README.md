# CubeOS Releases

Build pipeline for CubeOS SD card images for Raspberry Pi 5.

## Creating a Release

### Option 1: Manual Trigger (for testing)

1. Go to **GitLab → CI/CD → Pipelines**
2. Click **"Run pipeline"**
3. Add variable: `VERSION` = `0.1.0`
4. Click **"Run pipeline"**
5. Wait ~30-45 minutes

### Option 2: Git Tag (for real releases)
```bash
git tag -a v0.1.0 -m "Release 0.1.0"
git push origin v0.1.0
```

## Output

- **Download**: `https://github.com/cubeos-app/releases/releases`
- **File**: `cubeos-{version}-pi5.img.xz` (~2-3 GB)

## What's Included

- Ubuntu 24.04 LTS ARM64
- Docker CE pre-installed
- CubeOS directory structure
- 14 coreapps configurations
- First-boot Docker image pull

## First Boot

1. Flash with RPi Imager → "Use custom"
2. Boot Pi 5
3. SSH: `ubuntu@<ip>` (password: ubuntu)
4. Images pull automatically on first boot
