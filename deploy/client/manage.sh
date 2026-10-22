#!/usr/bin/env bash
# Day-to-day operations for a portal installed with setup.sh.
#
#   ./manage.sh status                 what is running, health, modules
#   ./manage.sh start|stop|restart [service...]
#   ./manage.sh logs [service]         follow logs (all services without one)
#   ./manage.sh doctor                 check this machine and the stack
#   ./manage.sh upgrade [release]      move to a release from releases.yml (default: latest)
#   ./manage.sh backup                 write a backup now (the portal also makes one every day)
#   ./manage.sh backups                the backups in the backup folder, newest first
#   ./manage.sh restore [file] [--yes] replace this portal's data with a backup (default: the newest)
#   ./manage.sh reset-password [user]  a new password for an account (default: admin), shown once
#   ./manage.sh services               the service names, and what each does
#   ./manage.sh service install [--user] [--workers N] [--no-start]
#                                      run the stack as a systemd service on this Linux server: it
#                                      starts at boot and is managed with systemctl (root; --user:
#                                      rootless Podman). Also: service uninstall | status | print
#   ./manage.sh help
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$here/compose.yaml" ]]; then ROOT="$here"; else ROOT="$(cd "$here/../.." && pwd)"; fi
# shellcheck source=lib.sh
source "$here/lib.sh"
cd "$ROOT"

[[ -f .env ]] || fail "No .env in $ROOT: install first with ./setup.sh /path/to/dbt-project"
PORT="$(get_env PORTAL_PORT)"; PORT="${PORT:-8080}"
cmd="${1:-help}"; shift || true

need_runtime() { find_runtime || fail "Docker or Podman with compose is not running. $(install_hint)"; }

# app.backup in a one-off backend container: it works while the backend is stopped.
backup_cli() { "${C[@]}" run --rm --no-deps -T --entrypoint python backend -m app.backup "$@"; }
wait_postgres() {
    for _ in $(seq 1 30); do
        "${C[@]}" exec -T postgres pg_isready -U portal -d portal >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

# ── the stack as a systemd service ───────────────────────────────────────────
SERVICE_NAME=dbt-portal.service

# service_unit SCOPE ENGINE: the unit file (system | user; docker | podman) on stdout.
# One oneshot unit that stays "active" after it has run `manage.sh start` (compose up -d, idempotent)
# and runs `manage.sh stop` (compose stop, a running dbt step gets its grace period) when stopped.
# The containers keep restart: unless-stopped; the unit is what starts them at boot, which Podman
# does not do by itself. The engine is pinned with PORTAL_ENGINE so a reboot picks the same one.
service_unit() {
    local scope="$1" engine="$2" home_dir wanted after="network-online.target" wants="network-online.target"
    case "$ROOT" in *%* | *$'\n'*) fail "The install folder '$ROOT' contains a % or a line break: move it before installing a service." ;; esac
    home_dir="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"; home_dir="${home_dir:-$HOME}"
    if [[ "$scope" == user ]]; then wanted=default.target; else wanted=multi-user.target; fi
    if [[ "$engine" == docker ]]; then after="$after docker.service"; wants="$wants docker.service"; fi
    cat <<EOF
# Written by manage.sh service install. Remove with: manage.sh service uninstall
[Unit]
Description=Capgemini dbt Portal ($engine compose in $ROOT)
Wants=$wants
After=$after

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$ROOT
Environment=PORTAL_ENGINE=$engine
Environment=HOME=$home_dir
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$home_dir/.local/bin
ExecStart="$ROOT/manage.sh" start
ExecStop="$ROOT/manage.sh" stop
# First start pulls nothing (setup.sh did) but may wait for the database; a stop lets dbt steps finish.
TimeoutStartSec=900
TimeoutStopSec=300

[Install]
WantedBy=$wanted
EOF
}

service_command() {  # service_command install|uninstall|status|print [--user] [--workers N] [--no-start]
    local sub="${1:-}" scope=system workers="" start_now=1 engine unit_dir sc=(systemctl)
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user) scope=user; shift ;;
            --workers) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || fail "--workers needs a number (1 or more)."; workers="$2"; shift 2 ;;
            --no-start) start_now=""; shift ;;
            *) fail "Unknown option '$1' for 'service $sub'." ;;
        esac
    done
    if [[ "$scope" == user ]]; then sc=(systemctl --user); unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"; else unit_dir=/etc/systemd/system; fi

    # The engine this install runs on (the unit pins it). `print` works without one running.
    if find_runtime; then engine="$E"; else engine="${PORTAL_ENGINE:-docker}"; fi

    case "$sub" in
        print) service_unit "$scope" "$engine" ;;
        install)
            [[ "$(uname -s)" == Linux ]] || fail "systemd services are for Linux servers. On Windows and macOS use Docker/Podman Desktop's own start-at-login setting."
            command -v systemctl >/dev/null 2>&1 || fail "systemctl was not found: this host does not run systemd."
            find_runtime || fail "Docker or Podman with compose is not running: start it, run ./setup.sh, then install the service. $(install_hint)"
            if [[ "$scope" == user ]]; then
                [[ "$engine" == podman ]] || fail "--user is for rootless Podman. Docker's daemon is a system service: run 'sudo ./manage.sh service install'."
            elif [[ "$EUID" -ne 0 ]]; then
                fail "A system service needs root: sudo ./manage.sh service install   (rootless Podman: ./manage.sh service install --user)"
            fi
            [[ -z "$workers" ]] || set_env PORTAL_WORKERS "$workers"
            mkdir -p "$unit_dir"
            service_unit "$scope" "$engine" > "$unit_dir/$SERVICE_NAME"
            chmod 644 "$unit_dir/$SERVICE_NAME"
            ok "Wrote $unit_dir/$SERVICE_NAME ($engine, $scope)"
            "${sc[@]}" daemon-reload
            "${sc[@]}" enable "$SERVICE_NAME" >/dev/null 2>&1 || fail "systemctl enable failed."
            ok "Enabled: the portal starts at boot"
            if [[ "$scope" == user ]]; then
                # Without lingering a user's units stop at logout and do not start at boot.
                if loginctl enable-linger "$(id -un)" 2>/dev/null; then ok "Lingering is on for $(id -un): the service runs without a login"
                else warn "Could not turn on lingering: run 'sudo loginctl enable-linger $(id -un)' or the portal will not start at boot."; fi
            fi
            if [[ -n "$start_now" ]]; then "${sc[@]}" start "$SERVICE_NAME" && ok "Started"; fi
            echo
            echo "  ${sc[*]} status $SERVICE_NAME    ${sc[*]} restart $SERVICE_NAME    journalctl $([[ "$scope" == user ]] && echo --user )-u $SERVICE_NAME"
            ;;
        uninstall)
            command -v systemctl >/dev/null 2>&1 || fail "systemctl was not found."
            if [[ "$scope" == system && "$EUID" -ne 0 ]]; then fail "Removing a system service needs root: sudo ./manage.sh service uninstall"; fi
            "${sc[@]}" disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
            rm -f "$unit_dir/$SERVICE_NAME"
            "${sc[@]}" daemon-reload
            ok "Removed $SERVICE_NAME. The containers and the data are untouched (./manage.sh stop to stop them)."
            ;;
        status)
            command -v systemctl >/dev/null 2>&1 || fail "systemctl was not found."
            "${sc[@]}" status "$SERVICE_NAME" --no-pager || true
            ;;
        *) fail "Usage: ./manage.sh service install|uninstall|status|print [--user] [--workers N] [--no-start]" ;;
    esac
}

modules() {
    local m mode url
    for m in AIRBYTE AIRFLOW; do
        mode="$(get_env "${m}_MODE")"; url="$(get_env "${m}_URL")"
        if [[ -z "$mode" ]]; then mode="$([[ -n "$url" ]] && echo external || echo "off (or set in the portal)")"; fi
        printf '  %-9s %s%s\n' "$(echo "$m" | tr '[:upper:]' '[:lower:]')" "$mode" "${url:+  $url}"
    done
    echo "  (the Modules page in the portal can override these)"
}

case "$cmd" in
    status)
        need_runtime
        say "Containers"
        "${C[@]}" ps
        say "Portal"
        if curl -fs "http://localhost:$PORT/api/health" >/dev/null 2>&1; then ok "http://localhost:$PORT answers"
        else bad "http://localhost:$PORT does not answer (./manage.sh logs frontend backend)"; fi
        say "Modules (from .env)"
        modules
        ;;
    start)
        need_runtime
        # PORTAL_WORKERS (.env: setup.sh --workers, service install --workers) keeps the worker count across restarts and reboots.
        workers="$(get_env PORTAL_WORKERS)"
        [[ -z "$workers" || "$workers" =~ ^[1-9][0-9]*$ ]] || fail "PORTAL_WORKERS in .env must be a number."
        if [[ $# -gt 0 ]]; then "${C[@]}" start "$@"
        elif [[ -n "$workers" ]]; then "${C[@]}" up -d --scale worker="$workers"
        else "${C[@]}" up -d; fi
        ;;
    service) service_command "$@" ;;
    stop) need_runtime; "${C[@]}" stop "$@" ;;
    restart) need_runtime; "${C[@]}" restart "$@" ;;
    logs) need_runtime; "${C[@]}" logs -f --tail 200 "$@" ;;
    doctor)
        problems=0
        host_check "$ROOT" || problems=1
        if find_runtime; then
            say "Stack"
            unhealthy="$("${C[@]}" ps --format '{{.Name}} {{.Status}}' 2>/dev/null | grep -Ei 'unhealthy|exited|restarting' || true)"
            if [[ -n "$unhealthy" ]]; then bad "Not healthy:"; echo "$unhealthy" | sed 's/^/      /'; problems=1
            else ok "Every container is running"; fi
            if curl -fs "http://localhost:$PORT/api/health" >/dev/null 2>&1; then ok "Portal answers on port $PORT"
            else bad "Portal does not answer on port $PORT"; problems=1; fi
        fi
        project="$(get_env DBT_PROJECT_PATH)"
        if [[ -n "$project" && -f "$project/dbt_project.yml" ]]; then ok "dbt project: $project"
        elif [[ -n "$project" ]]; then bad "No dbt_project.yml in $project"; problems=1; fi
        [[ -n "$project" && ! -f "$project/.env" ]] && warn "$project/.env is missing: no warehouse credentials."
        echo
        if [[ "$problems" == 0 ]]; then ok "No problems found."
        else echo "Fixes: ./manage.sh logs <service>   ·   ./manage.sh restart <service>   ·   docs: README.md, 'Troubleshooting'"; exit 1; fi
        ;;
    upgrade)
        release="${1:-latest}"
        project="$(get_env DBT_PROJECT_PATH)"
        say "Upgrading to $release (accounts, history and settings are kept)"
        if [[ -n "$project" ]]; then exec "$here/setup.sh" "$project" --release "$release" --non-interactive; fi
        exec "$here/setup.sh" --release "$release" --non-interactive
        ;;
    backup)
        need_runtime
        say "Writing a backup"
        backup_cli now
        ;;
    backups)
        need_runtime
        backup_cli list
        ;;
    restore)
        need_runtime
        file="latest"; yes=""
        for arg in "$@"; do if [[ "$arg" == --yes ]]; then yes=1; else file="$arg"; fi; done
        "${C[@]}" up -d postgres >/dev/null
        wait_postgres || fail "The database does not start: ./manage.sh logs postgres"
        say "Backups in $(get_env PORTAL_BACKUP_DIR)"
        backup_cli list
        echo
        warn "Restoring replaces every account, run, schedule and setting of this portal with the backup's ($file)."
        if [[ -z "$yes" ]]; then
            [[ -t 0 ]] || fail "Add --yes to restore without being asked."
            read -rp "Type yes to go on: " answer
            [[ "$answer" == yes ]] || fail "Nothing restored."
        fi
        say "Stopping the portal"
        "${C[@]}" stop frontend cube worker backend
        say "Restoring"
        if ! backup_cli restore "$file"; then
            "${C[@]}" start >/dev/null 2>&1 || true
            fail "The restore failed (see above). The portal is starting again; restore another backup if its data is incomplete."
        fi
        say "Starting the portal"
        # start, not up: it keeps the number of workers.
        "${C[@]}" start
        wait_healthy "$PORT" || fail "Not up after 5 minutes. See: ./manage.sh logs backend"
        ok "Restored. Sign in with the accounts of the backup: http://localhost:$PORT"
        ;;
    services)
        cat <<'EOF'
  frontend    the web app and the gateway to the API (the only published port)
  backend     the portal API: sign-in, dbt runs and logs, schedules, editor,
              reports, Ask AI, the semantic layer, Airflow/Airbyte, modules
  worker      runs the dbt jobs the backend queues (scale: setup.sh --workers N)
  cube        the semantic layer engine (Cube)
  postgres    the portal's database
  redis       job queue and live logs
  upgrade     one-off at start: moves data from a portal before 2026.11
EOF
        ;;
    reset-password)
        need_runtime
        say "A new password for ${1:-admin}"
        "${C[@]}" exec -T backend python -m app.reset_password "${1:-admin}"
        ;;
    help|-h|--help) sed -n '2,15p' "$0" ;;
    *) fail "Unknown command '$cmd'. Run ./manage.sh help" ;;
esac
