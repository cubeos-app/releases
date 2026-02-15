#!/bin/bash
# =============================================================================
# cubeos-boot-detect.sh — Detect boot mode
# =============================================================================
# Returns "first-boot" or "normal-boot" based on setup state.
# Called by cubeos-init.service to select the correct boot script.
# =============================================================================

SETUP_FLAG="/cubeos/data/.setup_complete"
DB_PATH="/cubeos/data/cubeos.db"

# First boot if setup flag doesn't exist
if [ ! -f "$SETUP_FLAG" ]; then
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
