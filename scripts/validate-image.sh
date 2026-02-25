#!/usr/bin/env bash
# =============================================================================
# CubeOS Post-Build Image Validation
# =============================================================================
# Mounts a built CubeOS image and validates critical files, configs, and
# structure WITHOUT booting. Used in CI validate stage to gate releases.
#
# Usage: ./scripts/validate-image.sh <image-file> <platform> <variant> <version>
# Example: ./scripts/validate-image.sh cubeos-0.2.0-arm64.img raspberrypi full 0.2.0-beta.01
#
# Exit codes:
#   0 — All checks passed
#   1 — One or more critical checks failed
# =============================================================================

set -euo pipefail

IMAGE_FILE="${1:?Usage: validate-image.sh <image> <platform> <variant> <version>}"
PLATFORM="${2:?Missing platform (raspberrypi, bananapi, etc.)}"
VARIANT="${3:?Missing variant (full or lite)}"
EXPECTED_VERSION="${4:?Missing expected CUBEOS_VERSION}"
REPORT_FILE="${REPORT_FILE:-validation-report.txt}"

MOUNT_DIR="/mnt/cubeos-validate-$$"
LOOPDEV=""
PASS=0
FAIL=0
WARN=0
TOTAL=0

# ── Helpers ──────────────────────────────────────────────────────────────────

cleanup() {
  if [ -n "${MOUNT_DIR:-}" ]; then
    umount "${MOUNT_DIR}/boot/firmware" 2>/dev/null || true
    umount "${MOUNT_DIR}" 2>/dev/null || true
    rmdir "${MOUNT_DIR}" 2>/dev/null || true
  fi
  if [ -n "${LOOPDEV:-}" ]; then
    losetup -d "$LOOPDEV" 2>/dev/null || true
  fi
}
trap cleanup EXIT

report() {
  echo "$1" | tee -a "$REPORT_FILE"
}

check_pass() {
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  report "  PASS: $1"
}

check_fail() {
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
  report "  FAIL: $1"
}

check_warn() {
  TOTAL=$((TOTAL + 1))
  WARN=$((WARN + 1))
  report "  WARN: $1"
}

# Check if a file/directory exists on the mounted image
check_exists() {
  local label="$1" path="$2"
  if [ -e "${MOUNT_DIR}${path}" ]; then
    check_pass "${label} (${path})"
  else
    check_fail "${label} — ${path} not found"
  fi
}

# Check if a file contains expected content
check_contains() {
  local label="$1" path="$2" pattern="$3"
  if [ -f "${MOUNT_DIR}${path}" ] && grep -q "$pattern" "${MOUNT_DIR}${path}" 2>/dev/null; then
    check_pass "${label}"
  else
    check_fail "${label} — pattern '${pattern}' not found in ${path}"
  fi
}

# ── Start ────────────────────────────────────────────────────────────────────

: > "$REPORT_FILE"
report "============================================================"
report "  CubeOS Post-Build Image Validation Report"
report "============================================================"
report "  Image:    ${IMAGE_FILE}"
report "  Platform: ${PLATFORM}"
report "  Variant:  ${VARIANT}"
report "  Version:  ${EXPECTED_VERSION}"
report "  Date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
report "============================================================"
report ""

# ── Section 0: Image Size ────────────────────────────────────────────────────

report "[0/7] Image size validation..."

IMAGE_SIZE_BYTES=$(stat -c%s "$IMAGE_FILE" 2>/dev/null || stat -f%z "$IMAGE_FILE" 2>/dev/null || echo 0)
IMAGE_SIZE_GB=$(awk "BEGIN { printf \"%.1f\", ${IMAGE_SIZE_BYTES} / 1073741824 }")
report "  Image size: ${IMAGE_SIZE_GB} GB (${IMAGE_SIZE_BYTES} bytes)"

if [ "$VARIANT" = "full" ]; then
  MIN_GB=10; MAX_GB=14
else
  MIN_GB=8; MAX_GB=12
fi

SIZE_OK=$(awk "BEGIN { print (${IMAGE_SIZE_GB} >= ${MIN_GB} && ${IMAGE_SIZE_GB} <= ${MAX_GB}) ? 1 : 0 }")
if [ "$SIZE_OK" = "1" ]; then
  check_pass "Image size ${IMAGE_SIZE_GB}GB within expected range (${MIN_GB}-${MAX_GB}GB)"
else
  check_warn "Image size ${IMAGE_SIZE_GB}GB outside expected range (${MIN_GB}-${MAX_GB}GB) — may be OK if content changed"
fi

# ── Mount the image ──────────────────────────────────────────────────────────

report ""
report "Mounting image..."

LOOPDEV=$(losetup -fP --show "$IMAGE_FILE")
report "  Loop device: ${LOOPDEV}"
sleep 2

# Partition layout differs by platform
if [ "$PLATFORM" = "raspberrypi" ]; then
  ROOT_PART="${LOOPDEV}p2"
  BOOT_PART="${LOOPDEV}p1"
else
  ROOT_PART="${LOOPDEV}p1"
  BOOT_PART=""
fi

if [ ! -b "$ROOT_PART" ]; then
  report "FATAL: Root partition ${ROOT_PART} not found — cannot validate"
  exit 1
fi

mkdir -p "$MOUNT_DIR"
mount -o ro "$ROOT_PART" "$MOUNT_DIR"
report "  Mounted root: ${ROOT_PART} → ${MOUNT_DIR}"

if [ -n "$BOOT_PART" ] && [ -b "$BOOT_PART" ]; then
  mkdir -p "${MOUNT_DIR}/boot/firmware"
  mount -o ro "$BOOT_PART" "${MOUNT_DIR}/boot/firmware" 2>/dev/null && \
    report "  Mounted boot: ${BOOT_PART} → ${MOUNT_DIR}/boot/firmware" || \
    report "  WARN: Could not mount boot partition"
fi

# ── Section 1: Boot Scripts ──────────────────────────────────────────────────

report ""
report "[1/7] Boot scripts..."
check_exists "cubeos-boot-lib.sh"         "/usr/local/bin/cubeos-boot-lib.sh"
check_exists "cubeos-first-boot.sh"       "/usr/local/bin/cubeos-first-boot.sh"
check_exists "cubeos-normal-boot.sh"      "/usr/local/bin/cubeos-normal-boot.sh"
check_exists "cubeos-boot-detect.sh"      "/usr/local/bin/cubeos-boot-detect.sh"
check_exists "cubeos-generate-secrets.sh" "/usr/local/bin/cubeos-generate-secrets.sh"
check_exists "cubeos-deploy-stacks.sh"    "/usr/local/bin/cubeos-deploy-stacks.sh"

# Also check the paths mentioned in the task spec
# (firstboot scripts may also be at /opt/cubeos/firstboot/)
if [ -d "${MOUNT_DIR}/opt/cubeos/firstboot" ]; then
  check_pass "Firstboot directory exists (/opt/cubeos/firstboot/)"
fi

# ── Section 2: Systemd Services ─────────────────────────────────────────────

report ""
report "[2/7] Systemd services..."
# cubeos-init.service is the main boot service (detects first vs normal boot)
# Check common locations for the service file
if [ -f "${MOUNT_DIR}/etc/systemd/system/cubeos-init.service" ]; then
  check_pass "cubeos-init.service (boot detection)"
elif [ -f "${MOUNT_DIR}/etc/systemd/system/cubeos-first-boot.service" ]; then
  check_pass "cubeos-first-boot.service (legacy name)"
else
  check_fail "No CubeOS boot service found (cubeos-init.service or cubeos-first-boot.service)"
fi

check_exists "Docker daemon.json"   "/etc/docker/daemon.json"
check_exists "Netplan config"       "/etc/netplan/01-cubeos.yaml"

# ── Section 3: Docker Installation ──────────────────────────────────────────

report ""
report "[3/7] Docker installation..."
# Docker binary may be at /usr/bin/docker or /usr/bin/dockerd
if [ -f "${MOUNT_DIR}/usr/bin/docker" ] || [ -f "${MOUNT_DIR}/usr/bin/dockerd" ]; then
  check_pass "Docker binary exists"
else
  check_fail "Docker binary not found (/usr/bin/docker or /usr/bin/dockerd)"
fi

# ── Section 4: CubeOS Config & Directories ──────────────────────────────────

report ""
report "[4/7] CubeOS config & directories..."
check_exists "/cubeos/config/"            "/cubeos/config/"
check_exists "/cubeos/data/"              "/cubeos/data/"
check_exists "/cubeos/coreapps/"          "/cubeos/coreapps/"
check_exists "/cubeos/config/defaults.env" "/cubeos/config/defaults.env"

# Validate defaults.env contains CUBEOS_VERSION
if [ -f "${MOUNT_DIR}/cubeos/config/defaults.env" ]; then
  if grep -q "CUBEOS_VERSION" "${MOUNT_DIR}/cubeos/config/defaults.env" 2>/dev/null; then
    BAKED_CFG_VERSION=$(grep "CUBEOS_VERSION" "${MOUNT_DIR}/cubeos/config/defaults.env" | head -1 | cut -d= -f2 | tr -d '"' | tr -d "'")
    if [ "$BAKED_CFG_VERSION" = "$EXPECTED_VERSION" ]; then
      check_pass "defaults.env CUBEOS_VERSION=${BAKED_CFG_VERSION} matches expected"
    else
      check_fail "defaults.env CUBEOS_VERSION=${BAKED_CFG_VERSION} does not match expected ${EXPECTED_VERSION}"
    fi
  else
    check_fail "defaults.env missing CUBEOS_VERSION key"
  fi
fi

# /etc/cubeos-version
check_exists "/etc/cubeos-version" "/etc/cubeos-version"
if [ -f "${MOUNT_DIR}/etc/cubeos-version" ]; then
  BAKED_VERSION=$(cat "${MOUNT_DIR}/etc/cubeos-version" | tr -d '[:space:]')
  if [ "$BAKED_VERSION" = "$EXPECTED_VERSION" ]; then
    check_pass "/etc/cubeos-version matches (${BAKED_VERSION})"
  else
    check_fail "/etc/cubeos-version mismatch: baked=${BAKED_VERSION} expected=${EXPECTED_VERSION}"
  fi
fi

# ── Section 5: Compose Files ────────────────────────────────────────────────

report ""
report "[5/7] Compose files (variant: ${VARIANT})..."

# Core compose files (both variants)
CORE_SERVICES="pihole npm cubeos-api cubeos-hal cubeos-dashboard registry terminal"

# Full-only services
FULL_SERVICES="cubeos-docsindex dozzle kiwix"

for svc in $CORE_SERVICES; do
  check_exists "${svc} compose" "/cubeos/coreapps/${svc}/appconfig/docker-compose.yml"
done

if [ "$VARIANT" = "full" ]; then
  for svc in $FULL_SERVICES; do
    check_exists "${svc} compose (full)" "/cubeos/coreapps/${svc}/appconfig/docker-compose.yml"
  done
else
  report "  (skipping full-only compose checks for lite variant)"
fi

# ── Section 6: Platform-Specific Checks ─────────────────────────────────────

report ""
report "[6/7] Platform-specific checks (${PLATFORM})..."

if [ "$PLATFORM" = "raspberrypi" ]; then
  check_exists "config.txt"        "/boot/firmware/config.txt"
  check_exists "hostapd.conf"      "/etc/hostapd/hostapd.conf"
else
  report "  (skipping Pi-specific checks for ${PLATFORM})"
fi

# ── Section 7: Security Hardening ────────────────────────────────────────────

report ""
report "[7/7] Security hardening..."
check_exists "SSH 01-cubeos.conf"             "/etc/ssh/sshd_config.d/01-cubeos.conf"
check_exists "SSH 99-cubeos-hardening.conf"   "/etc/ssh/sshd_config.d/99-cubeos-hardening.conf"
check_exists "sysctl 99-cubeos.conf"          "/etc/sysctl.d/99-cubeos.conf"
check_exists "journald cubeos.conf"           "/etc/systemd/journald.conf.d/cubeos.conf"
check_exists "watchdog config"                "/etc/systemd/system.conf.d/cubeos-watchdog.conf"
check_exists "fail2ban cubeos-sshd.conf"      "/etc/fail2ban/jail.d/cubeos-sshd.conf"

# Content spot-checks
if [ -f "${MOUNT_DIR}/etc/ssh/sshd_config.d/99-cubeos-hardening.conf" ]; then
  check_contains "SSH PermitRootLogin=no" "/etc/ssh/sshd_config.d/99-cubeos-hardening.conf" "PermitRootLogin no"
fi
if [ -f "${MOUNT_DIR}/etc/systemd/journald.conf.d/cubeos.conf" ]; then
  check_contains "journald Storage=volatile" "/etc/systemd/journald.conf.d/cubeos.conf" "Storage=volatile"
fi
if [ -f "${MOUNT_DIR}/etc/systemd/system.conf.d/cubeos-watchdog.conf" ]; then
  check_contains "watchdog RuntimeWatchdogSec=10s" "/etc/systemd/system.conf.d/cubeos-watchdog.conf" "RuntimeWatchdogSec=10s"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

report ""
report "============================================================"
report "  Validation Summary"
report "============================================================"
report "  PASS: ${PASS}"
report "  FAIL: ${FAIL}"
report "  WARN: ${WARN}"
report "  TOTAL: ${TOTAL}"
report "============================================================"

if [ "$FAIL" -gt 0 ]; then
  report ""
  report "  RESULT: FAILED — ${FAIL} critical check(s) did not pass"
  report "  Image should NOT proceed to release."
  report "============================================================"
  exit 1
else
  report ""
  report "  RESULT: PASSED — All critical checks passed"
  report "============================================================"
  exit 0
fi
