#!/bin/sh
# Runs before the backend on every start (compose service `upgrade`).
#
# Up to 2026.10 the portal ran as separate services, each with its own
# database (portal_identity, portal_execution) and volume (execution_data,
# semantic_data). It is now one backend with one database (portal) and one
# volume (portal_data). On the first start after the upgrade this moves the
# data across; the old databases and volumes are left as they were (a backup).
# On a new install, or once moved, it only makes sure /data is writable.
set -eu

export PGHOST="${PGHOST:-postgres}" PGUSER="${PGUSER:-portal}" PGPASSWORD="$POSTGRES_PASSWORD"
owner="${PORTAL_USER:-10001:10001}"

# ── Files: the dbt editor's trash, the stored-credentials key, Cube's state ──
# (compose only: run by hand, e.g. on Kubernetes, there is no /data)
if [ -d /data ]; then
    if [ ! -e /data/.moved-from-services ]; then
        if [ -d /old-execution-data ]; then
            cp -a /old-execution-data/. /data/
        fi
        if [ -d /old-semantic-data/cube ] && [ ! -e /data/cube ]; then
            cp -a /old-semantic-data/cube /data/cube
        fi
        touch /data/.moved-from-services
    fi
    chown "$owner" /data /data/.moved-from-services
fi

# ── Database ─────────────────────────────────────────────────────────────────
has_db() { [ "$(psql -d portal -Atc "SELECT 1 FROM pg_database WHERE datname = '$1'")" = 1 ]; }
has_table() { [ "$(psql -d "$1" -Atc "SELECT to_regclass('public.$2') IS NOT NULL")" = t ]; }

if ! has_db portal_identity && ! has_db portal_execution; then
    exit 0  # a new install
fi
if has_table portal alembic_version_identity || has_table portal alembic_version_execution; then
    exit 0  # already moved
fi

echo "Moving the portal_identity and portal_execution databases into portal"
{
    if has_db portal_identity; then
        pg_dump -d portal_identity --no-owner --no-privileges
    fi
    if has_db portal_execution; then
        if has_db portal_identity && has_table portal_execution portal_settings; then
            # Both services kept a portal_settings table: identity's comes first,
            # then execution's rows (keys identity does not have).
            pg_dump -d portal_execution --no-owner --no-privileges --exclude-table=portal_settings
            pg_dump -d portal_execution --data-only --inserts --on-conflict-do-nothing --table=portal_settings
        else
            pg_dump -d portal_execution --no-owner --no-privileges
        fi
    fi
} | psql -d portal -v ON_ERROR_STOP=1 --single-transaction -q -o /dev/null
echo "Done. The old databases are kept; drop them once the portal works:"
echo "  DROP DATABASE portal_identity; DROP DATABASE portal_execution;"
