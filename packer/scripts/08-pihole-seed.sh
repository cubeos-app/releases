#!/bin/bash
# =============================================================================
# 08-pihole-seed.sh — Pre-seed Pi-hole gravity.db for offline-first boot
# =============================================================================
# Without this, Pi-hole enters a crash loop on first boot without internet:
#   "gravity.db does not exist" -> tries gravity download -> no DNS -> timeout
#
# IMPORTANT: This runs inside packer-builder-arm QEMU chroot where Docker
# is NOT available. We use sqlite3 (installed in the Ubuntu 24.04 base)
# to create the database directly.
#
# Pi-hole v6 FTL checks for /etc/pihole/gravity.db on startup. If missing,
# it attempts to download blocklists which requires DNS resolution —
# creating a chicken-and-egg problem when Pi-hole IS the DNS server.
#
# This script creates a valid, empty gravity.db with the correct schema
# so Pi-hole starts cleanly without needing any network connectivity.
# =============================================================================
set -euo pipefail

PIHOLE_DIR="/cubeos/coreapps/pihole/appdata/etc-pihole"

echo "=== [08] Pi-hole Offline Seed ==="

# ---------------------------------------------------------------------------
# Verify sqlite3 is available
# ---------------------------------------------------------------------------
if ! command -v sqlite3 &>/dev/null; then
    echo "[08] ERROR: sqlite3 not found — cannot pre-seed gravity.db"
    echo "[08] Install with: apt-get install sqlite3"
    exit 1
fi

mkdir -p "${PIHOLE_DIR}"

# ---------------------------------------------------------------------------
# 1. Create valid gravity.db with Pi-hole v6 schema (empty, no blocklists)
# ---------------------------------------------------------------------------
# Schema version 17 matches Pi-hole v6.x FTL expectations.
# With no adlist entries, Pi-hole won't attempt any blocklist downloads.
# Users can add adlists later via the web UI once internet is available.
# ---------------------------------------------------------------------------
echo "[08] Creating empty gravity.db (Pi-hole v6 schema)..."

GRAVITY_DB="${PIHOLE_DIR}/gravity.db"

# Remove any stale/corrupt gravity.db from previous builds
rm -f "${GRAVITY_DB}"

sqlite3 "${GRAVITY_DB}" <<'SQL'
-- Pi-hole v6 gravity.db schema (version 17)
-- Empty tables = no blocklist downloads on startup

CREATE TABLE IF NOT EXISTS "group" (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    enabled BOOLEAN NOT NULL DEFAULT 1,
    name TEXT UNIQUE NOT NULL,
    description TEXT
);
INSERT OR IGNORE INTO "group" VALUES (0, 1, 'Default', 'The default group');

CREATE TABLE IF NOT EXISTS adlist (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    address TEXT UNIQUE NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT 1,
    date_added INTEGER NOT NULL DEFAULT (cast(strftime('%s', 'now') as int)),
    date_modified INTEGER NOT NULL DEFAULT (cast(strftime('%s', 'now') as int)),
    comment TEXT,
    type INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS adlist_by_group (
    adlist_id INTEGER NOT NULL REFERENCES adlist(id),
    group_id INTEGER NOT NULL REFERENCES "group"(id),
    PRIMARY KEY (adlist_id, group_id)
);

CREATE TABLE IF NOT EXISTS gravity (
    domain TEXT NOT NULL,
    adlist_id INTEGER NOT NULL REFERENCES adlist(id),
    PRIMARY KEY (domain, adlist_id)
);

CREATE TABLE IF NOT EXISTS domainlist (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    type INTEGER NOT NULL DEFAULT 0,
    domain TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT 1,
    date_added INTEGER NOT NULL DEFAULT (cast(strftime('%s', 'now') as int)),
    date_modified INTEGER NOT NULL DEFAULT (cast(strftime('%s', 'now') as int)),
    comment TEXT
);

CREATE TABLE IF NOT EXISTS domainlist_by_group (
    domainlist_id INTEGER NOT NULL REFERENCES domainlist(id),
    group_id INTEGER NOT NULL REFERENCES "group"(id),
    PRIMARY KEY (domainlist_id, group_id)
);

CREATE TABLE IF NOT EXISTS client (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ip TEXT NOT NULL UNIQUE,
    date_added INTEGER NOT NULL DEFAULT (cast(strftime('%s', 'now') as int)),
    date_modified INTEGER NOT NULL DEFAULT (cast(strftime('%s', 'now') as int)),
    comment TEXT
);

CREATE TABLE IF NOT EXISTS client_by_group (
    client_id INTEGER NOT NULL REFERENCES client(id),
    group_id INTEGER NOT NULL REFERENCES "group"(id),
    PRIMARY KEY (client_id, group_id)
);

CREATE TABLE IF NOT EXISTS info (
    property TEXT PRIMARY KEY,
    value TEXT
);
INSERT OR REPLACE INTO info VALUES ('version', '17');
INSERT OR REPLACE INTO info VALUES ('updated', '0');
INSERT OR REPLACE INTO info VALUES ('gravity_count', '0');
SQL

chmod 644 "${GRAVITY_DB}"
echo "[08]   gravity.db created ($(stat -c%s "${GRAVITY_DB}") bytes, schema v17)"

# ---------------------------------------------------------------------------
# 2. Verify the database is valid
# ---------------------------------------------------------------------------
TABLE_COUNT=$(sqlite3 "${GRAVITY_DB}" "SELECT count(*) FROM sqlite_master WHERE type='table';")
SCHEMA_VER=$(sqlite3 "${GRAVITY_DB}" "SELECT value FROM info WHERE property='version';")

if [ "${TABLE_COUNT}" -lt 8 ]; then
    echo "[08] ERROR: gravity.db has ${TABLE_COUNT} tables, expected 9+"
    exit 1
fi

echo "[08]   Verified: ${TABLE_COUNT} tables, schema version ${SCHEMA_VER}"

# ---------------------------------------------------------------------------
# 3. Note: custom.list is already created by 04-cubeos.sh
#    No need to duplicate it here. The authoritative DNS entries are:
#    - Baked into image: 04-cubeos.sh seeds /cubeos/coreapps/pihole/appdata/etc-pihole/hosts/custom.list
#    - On first boot: cubeos-first-boot.sh Step 5 re-seeds with $GATEWAY_IP
#    - Runtime wildcard: docker-compose.yml FTLCONF_misc_dnsmasq_lines catches all *.cubeos.cube
# ---------------------------------------------------------------------------

echo "[08] Pi-hole offline seed complete. DNS will serve on first boot without internet."
