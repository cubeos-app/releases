#!/bin/bash
# =============================================================================
# 08-pihole-seed.sh — Pre-seed Pi-hole gravity.db for offline-first boot
# =============================================================================
# Without this, Pi-hole enters a crash loop on first boot without internet:
#   "gravity.db does not exist" -> tries gravity download -> no DNS -> timeout
#
# IMPORTANT: This runs inside packer-builder-arm QEMU chroot where Docker
# is NOT available and sqlite3 CLI may not be installed. We use Python3's
# built-in sqlite3 module (always available, no extra packages needed).
#
# Pi-hole v6 FTL checks for /etc/pihole/gravity.db on startup. If missing,
# it attempts to download blocklists which requires DNS resolution —
# creating a chicken-and-egg problem when Pi-hole IS the DNS server.
# =============================================================================
set -euo pipefail

PIHOLE_DIR="/cubeos/coreapps/pihole/appdata/etc-pihole"

echo "=== [08] Pi-hole Offline Seed ==="

# ---------------------------------------------------------------------------
# Verify python3 is available (it's used by 05-docker-preload.sh too)
# ---------------------------------------------------------------------------
if ! command -v python3 &>/dev/null; then
    echo "[08] ERROR: python3 not found — cannot pre-seed gravity.db"
    exit 1
fi

mkdir -p "${PIHOLE_DIR}"

# ---------------------------------------------------------------------------
# Create valid gravity.db with Pi-hole v6 schema (empty, no blocklists)
# ---------------------------------------------------------------------------
echo "[08] Creating empty gravity.db (Pi-hole v6 schema via python3)..."

GRAVITY_DB="${PIHOLE_DIR}/gravity.db"

# Remove any stale/corrupt gravity.db from previous builds
rm -f "${GRAVITY_DB}"

python3 << PYEOF
import sqlite3
import sys

db_path = "${GRAVITY_DB}"

try:
    conn = sqlite3.connect(db_path)
    c = conn.cursor()

    c.executescript("""
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
    """)

    conn.commit()

    # Verify
    c.execute("SELECT count(*) FROM sqlite_master WHERE type='table'")
    table_count = c.fetchone()[0]
    c.execute("SELECT value FROM info WHERE property='version'")
    schema_ver = c.fetchone()[0]

    conn.close()

    print(f"[08]   Verified: {table_count} tables, schema version {schema_ver}")

except Exception as e:
    print(f"[08] ERROR: Failed to create gravity.db: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

chmod 644 "${GRAVITY_DB}"
DB_SIZE=$(stat -c%s "${GRAVITY_DB}")
echo "[08]   gravity.db created (${DB_SIZE} bytes)"

# ---------------------------------------------------------------------------
# Note: custom.list is already created by 04-cubeos.sh
# ---------------------------------------------------------------------------

echo "[08] Pi-hole offline seed complete. DNS will serve on first boot without internet."
