#!/bin/bash
# =============================================================================
# cubeos-boot-detect.sh — Detect boot mode
# =============================================================================
# Returns "first-boot" or "normal-boot" based on provisioning state.
# Called by cubeos-init.service to select the correct boot script.
#
# B37: Uses .provisioned (set by first-boot.sh after services deployed)
#      NOT .setup_complete (wizard completion is tracked in DB by API).
#      This prevents bricked state if Pi reboots before wizard finishes.
# =============================================================================

PROVISIONED_FLAG="/cubeos/data/.provisioned"
DB_PATH="/cubeos/data/cubeos.db"

# First boot if provisioning hasn't completed
if [ ! -f "$PROVISIONED_FLAG" ]; then
    echo "first-boot"
    exit 0
fi

# First boot if database doesn't exist (corrupted state)
if [ ! -f "$DB_PATH" ]; then
    echo "first-boot"
    exit 0
fi

echo "normal-boot"
exit 0
