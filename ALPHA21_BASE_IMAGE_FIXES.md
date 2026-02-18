# CubeOS Alpha.21 — Base Image Fixes Handover

**Date:** 2026-02-18  
**Scope:** P0 bugs B61, B56 + P2/P3 infrastructure fixes  
**Repos:** `cubeos-releases` (base-image + release packer + CI)  
**Based on:** Alpha.20 QA Report

---

## Executive Summary

Alpha.20 failed QA (56.5%) due to **B61 (SSH lockout)** — a ship-blocking bug where cloud-init cascade failures left the cubeos user with no password. This handover fixes the root cause with a multi-layer defense that eliminates all cloud-init dependency for SSH access.

---

## Root Cause Analysis: B61

The `cubeos` user was created entirely by cloud-init at boot time. No script in the build pipeline explicitly ran `useradd` or `chpasswd`. The chain of failure:

1. `07-cleanup.sh` runs `cloud-init clean --logs --seed --machine-id` (wipes instance state + machine-id)
2. On real boot, `systemd-machine-id-setup` regenerates machine-id, but cloud-init-local fails during re-initialization
3. Cascade: `cloud-init-local` → `cloud-init` → `cloud-config` all FAILED
4. `99-cubeos.cfg` never processed → `chpasswd` tried to set password for `ubuntu` (stock default) which doesn't exist (was already renamed during Packer build)
5. Result: **no user has a password**

Secondary factor: `pam_lastlog.so` was missing (deprecated in Ubuntu 24.04, removed from `libpam-modules`), generating confusing PAM errors during login attempts.

---

## Changes Made

### 1. B61 FIX: Explicit user creation in `packer/scripts/02-networking.sh`

**What:** Added a 50-line block that creates the `cubeos` user directly during the Packer build, independent of cloud-init.

**Details:**
- Creates `i2c` group if missing
- Renames `ubuntu` → `cubeos` if stock user exists, or creates from scratch
- Adds to groups: `sudo`, `docker`, `adm`, `i2c`
- Sets password via `chpasswd` (THE critical fix)
- Creates `/etc/sudoers.d/cubeos` for passwordless sudo
- Unlocks password (`passwd -u`)
- Removes deprecated `pam_lastlog` reference from `/etc/pam.d/login`

**Cloud-init is now SECONDARY** — kept for Pi Imager support (SSH keys, hostname override, growpart) but no longer the sole path to a working user.

### 2. B61 SAFETY NET: `firstboot/cubeos-first-boot.sh` + `cubeos-normal-boot.sh`

**What:** Added password verification at the start of both boot scripts.

**Logic:**
```bash
PW_STATUS=$(passwd -S cubeos | awk '{print $2}')
if [ "$PW_STATUS" != "P" ]; then
    echo "cubeos:cubeos" | chpasswd
    passwd -u cubeos
fi
```

This catches edge cases where cloud-init clean reset the password, or the image was modified post-build.

### 3. B61 HARDENING: `packer/scripts/07-cleanup.sh`

**What:** 
- Changed `cloud-init clean --logs --seed --machine-id` to `cloud-init clean --logs --seed` (no `--machine-id` flag — machine-id is already handled separately above, passing both caused conflicts)
- Added post-clean removal of `50-cloud-init.conf` SSH override (cloud-init clean may regenerate it)

### 4. B56 FIX: `.gitlab-ci.yml` Phase 0b2

**What:** Changed curated image download from non-fatal to **fatal**.

**Before:** `./skopeo/download-curated.sh curated-images || { echo "WARN" }` — if download failed, Phase 1c silently skipped and the image shipped with broken Kiwix.

**After:** Download failure exits with error, preventing broken images from being built.

### 5. smartmontools: `base-image/scripts/01-ubuntu-base.sh`

**What:** Added `systemctl disable smartd` + `systemctl disable smartmontools` after ModemManager section.

**Why:** SD cards don't support SMART. smartd fails on every boot with "No devices found to scan". The package stays installed for users with USB/SATA drives but doesn't auto-start.

### 6. PAM protection: `base-image/scripts/02-cleanup.sh`

**What:** Added `libpam-modules`, `libpam-runtime`, `openssh-server`, and `fail2ban` to the protected packages list.

**Why:** The aggressive `autoremove` in cleanup could theoretically strip PAM modules if APT marks them as auto-installed under QEMU emulation (same pattern that caused the hwclock B44 saga).

---

## Files Changed

| File | Change |
|------|--------|
| `packer/scripts/02-networking.sh` | +50 lines: explicit user creation, PAM fix, updated comments |
| `packer/scripts/07-cleanup.sh` | Removed `--machine-id` from cloud-init clean, added 50-cloud-init.conf removal |
| `firstboot/cubeos-first-boot.sh` | +15 lines: B61 password safety net |
| `firstboot/cubeos-normal-boot.sh` | +10 lines: B61 password safety net |
| `.gitlab-ci.yml` | B56: curated download now fatal |
| `base-image/scripts/01-ubuntu-base.sh` | +10 lines: disable smartd |
| `base-image/scripts/02-cleanup.sh` | +1 line: protect libpam-modules, openssh-server, fail2ban |

---

## Build & Deploy Sequence

### If golden base v2.0 is NOT yet built:

1. **Build golden base first** (required for smartmontools + libpam fixes):
   ```bash
   ssh nllei01gpu01
   cd /srv/cubeos-base-builder
   # Copy updated base-image/scripts/01-ubuntu-base.sh and 02-cleanup.sh
   vim .env  # Set BASE_VERSION=2.1.0
   ./build.sh
   ```

2. **Update releases CI** to use new base:
   ```
   BASE_VERSION: "2.1.0"
   ```

### If golden base v2.0 is already built:

The B61 and B56 fixes are in the release packer scripts and CI, not the base image. You can deploy them immediately:

1. Push `cubeos-releases` changes to main
2. CI pipeline runs → builds new image
3. Flash and verify

The smartmontools and libpam fixes will only take effect when the golden base is rebuilt.

---

## Verification Checklist

After flashing the new image:

```bash
# B61: SSH works immediately
ssh cubeos@10.42.24.1   # Password: cubeos — MUST WORK

# B61: User is correct
id cubeos               # uid=1000(cubeos) gid=1000(cubeos) groups=...,sudo,docker,adm,i2c
passwd -S cubeos        # cubeos P ... (P = password set)
sudo -n whoami          # root (passwordless sudo)

# B61: No PAM warnings
journalctl -b | grep -i "pam_lastlog"   # Should be empty

# B56: Kiwix in registry
curl -s http://localhost:5000/v2/kiwix/kiwix-serve/tags/list
# {"name":"kiwix/kiwix-serve","tags":["3.8.1"]}

# B56: ttyd in registry
curl -s http://localhost:5000/v2/tsl0922/ttyd/tags/list
# {"name":"tsl0922/ttyd","tags":["latest"]}

# Cloud-init status (informational — failure is now acceptable)
cloud-init status       # May show "error" — that's OK, SSH still works

# smartmontools (after base rebuild)
systemctl is-enabled smartd   # disabled
systemctl status smartd       # inactive (dead), no failed state
```

---

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| chpasswd fails in Packer chroot | Unlikely — chpasswd is a simple PAM operation. Even if it fails, the first-boot safety net catches it. |
| cloud-init clean regenerates SSH override | Post-clean `rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf` handles this. |
| User rename fails (ubuntu → cubeos) | Fallback: creates cubeos from scratch if rename fails. |
| Curated download fails on CI | Pipeline now fails visibly instead of shipping broken image. Fix the network/auth issue and retry. |
| libpam-modules stripped by autoremove | Protected with apt-mark manual. Three layers: base install, cleanup protection, post-autoremove verification. |

---

## What's NOT Fixed (Deferred)

| Bug | Why Deferred | Next Sprint |
|-----|-------------|-------------|
| B60 (GPS null dereference) | Dashboard repo, not releases | Alpha.21 dashboard batch |
| FR01 (WiFi country default) | Dashboard repo, not releases | Alpha.21 dashboard batch |
| fail2ban failed service | Likely resolves itself once cloud-init stops cascading. Monitor in QA. | Verify in Alpha.21 QA |
| fwupd-refresh failed | Expected in offline mode. Cosmetic. | P3 — suppress or mask |

---

*Handover generated: 2026-02-18*
