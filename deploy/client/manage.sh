#!/usr/bin/env bash
# Day-to-day operations for a portal installed with setup.sh.
#
#   ./manage.sh status                 what is running, health, modules
#   ./manage.sh start|stop|restart [service...]
#   ./manage.sh logs [service]         follow logs (all services without one)
#   ./manage.sh doctor                 check this machine and the stack
#   ./manage.sh upgrade [release]      move to a release from releases.yml (default: latest)
#   ./manage.sh backup                 dump the portal databases to backups/
#   ./manage.sh services               the service names, and what each does
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
        else bad "http://localhost:$PORT does not answer (./manage.sh logs frontend execution)"; fi
        say "Modules (from .env)"
        modules
        ;;
    start)
        need_runtime
        if [[ $# -gt 0 ]]; then "${C[@]}" start "$@"; else "${C[@]}" up -d; fi
        ;;
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
        [[ -n "$project" ]] || fail "DBT_PROJECT_PATH is not set in .env."
        say "Upgrading to $release (accounts, history and settings are kept)"
        exec "$here/setup.sh" "$project" --release "$release" --non-interactive
        ;;
    backup)
        need_runtime
        mkdir -p backups
        file="backups/portal-$(date +%Y%m%d-%H%M%S).sql.gz"
        say "Dumping the portal databases to $file"
        "${C[@]}" exec -T postgres pg_dumpall -U portal | gzip > "$file"
        ok "$(du -h "$file" | cut -f1) written. Restore: gunzip -c $file | ${C[*]} exec -T postgres psql -U portal -d postgres"
        ;;
    services)
        cat <<'EOF'
  frontend    the web app and the gateway to every API (the only published port)
  identity    sign-in, users, roles, audit trail
  execution   dbt runs and their logs, schedules, onboarding, Airflow/Airbyte, modules
  worker      runs the dbt jobs the execution service queues (scale: setup.sh --workers N)
  insights    Elementary, SQLFluff, profiler, assets, FinOps, Ask AI
  semantic    the managed Cube semantic layer
  cube        Cube itself
  postgres    the portal's databases
  redis       job queue and live logs
EOF
        ;;
    help|-h|--help) sed -n '2,12p' "$0" ;;
    *) fail "Unknown command '$cmd'. Run ./manage.sh help" ;;
esac
