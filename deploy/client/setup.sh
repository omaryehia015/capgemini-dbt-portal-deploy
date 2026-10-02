#!/usr/bin/env bash
# Runs the dbt Portal (microservices stack) for one dbt project, from the
# pre-built images. Needs Docker or Podman with compose; no build, no
# Python/Node/dbt on this machine.
#
#   ./setup.sh /path/to/my-dbt-project
#   ./setup.sh /path/to/my-dbt-project --port 8081 --release 2026.10.0
#   ./setup.sh /path/to/my-dbt-project --skip-pull     # images already here (docker load)
#   ./setup.sh /path/to/my-dbt-project --workers 3     # run more dbt jobs at once
#
# The first run writes .env next to compose.yaml with generated secrets; later
# runs keep it (accounts, history and sessions survive upgrades). Optional
# portal settings (LDAP, SMTP, AI keys...) go in that .env too.
# Warehouse credentials stay in the project's own .env.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# Works from the repo (deploy/client/) and from the unpacked client kit (flat).
if [[ -f "$here/compose.yaml" ]]; then ROOT="$here"; else ROOT="$(cd "$here/../.." && pwd)"; fi
cd "$ROOT"

PORT=""
PROJECT=""
RELEASE=""
SKIP_PULL=""
WORKERS=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --release) RELEASE="$2"; shift 2 ;;
        --workers) WORKERS="$2"; shift 2 ;;
        --skip-pull) SKIP_PULL=1; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) PROJECT="$1"; shift ;;
    esac
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# -- 1. Docker or Podman, with compose -----------------------------------------
if docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then C=(docker compose); E=docker
elif podman info >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then C=(podman compose); E=podman
else fail "Start Docker (or Podman with a compose provider: pip install podman-compose) first."; fi
say "Using ${C[*]}"

# -- 2. The dbt project --------------------------------------------------------
[[ -n "$PROJECT" ]] || read -rp "Path to your dbt project (the folder with dbt_project.yml): " PROJECT
PROJECT="${PROJECT/#\~/$HOME}"
[[ -f "$PROJECT/dbt_project.yml" ]] || fail "No dbt_project.yml in '$PROJECT'."
PROJECT="$(cd "$PROJECT" && pwd)"
[[ -f "$PROJECT/.env" ]] || echo "WARNING: $PROJECT/.env is missing. The portal reads the warehouse credentials from it."

# -- 3. .env: secrets once, project / port / versions every run ----------------
secret() { head -c 36 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-40; }
set_env() {  # set_env KEY VALUE: replace or append, keep everything else
    local key="$1" value="$2"
    if grep -q "^$key=" .env 2>/dev/null; then
        sed -i.bak "s|^$key=.*|$key=$value|" .env && rm -f .env.bak
    else
        printf '%s=%s\n' "$key" "$value" >> .env
    fi
}
get_env() { grep "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- || true; }

if [[ ! -f .env ]]; then
    say "Writing .env with generated secrets"
    cp .env.example .env
fi
for key in JWT_SECRET CUBE_API_SECRET POSTGRES_PASSWORD REDIS_PASSWORD; do
    [[ -n "$(get_env "$key")" ]] || set_env "$key" "$(secret)"
done
set_env DBT_PROJECT_PATH "$PROJECT"
[[ -n "$PORT" ]] && set_env PORTAL_PORT "$PORT"
PORT="$(get_env PORTAL_PORT)"; PORT="${PORT:-8080}"

if [[ -n "$RELEASE" ]]; then
    [[ "$RELEASE" == latest ]] && RELEASE="$(sed -n 's/^latest: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' releases.yml)"
    block="$(awk -v r="  \"$RELEASE\":" '$0==r{f=1;next} f&&/^  "/{f=0} f' releases.yml)"
    [[ -n "$block" ]] || fail "Release '$RELEASE' is not in releases.yml."
    for part in backend frontend cube; do
        tag="$(printf '%s\n' "$block" | sed -n "s/^ *$part: *\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p")"
        set_env "$(echo "$part" | tr '[:lower:]' '[:upper:]')_TAG" "$tag"
    done
    say "Release $RELEASE: backend $(get_env BACKEND_TAG), frontend $(get_env FRONTEND_TAG), cube $(get_env CUBE_TAG)"
fi

# Where profiles.yml is: in the project (seen as /workspace), or ~/.dbt.
rm -f compose.override.yaml
if [[ -f "$PROJECT/profiles.yml" ]]; then :
elif [[ -f "$PROJECT/profiles/profiles.yml" ]]; then set_env DBT_PROFILES_DIR /workspace/profiles
elif [[ -f "$HOME/.dbt/profiles.yml" ]]; then
    set_env DBT_PROFILES_DIR /profiles
    {
        echo "# Written by setup.sh: profiles.yml comes from ~/.dbt on this machine."
        echo "services:"
        for svc in execution worker insights semantic; do
            echo "  $svc:"
            echo "    volumes: [\"$HOME/.dbt:/profiles:ro\"]"
        done
    } > compose.override.yaml
else echo "WARNING: no profiles.yml found in the project or ~/.dbt."; fi
# Bind mounts on macOS / rootless Podman: root inside the container, so `dbt deps` can write.
[[ "$(uname -s)" == Darwin || "$E" == podman ]] && set_env PORTAL_USER 0:0

# -- 4. Pull and start ---------------------------------------------------------
if [[ -z "$SKIP_PULL" ]]; then
    say "Pulling images"
    if ! "${C[@]}" pull --quiet 2>/dev/null; then
        registry="$(get_env IMAGE_REGISTRY)"; registry="${registry:-ghcr.io/omaryehia015}"
        echo "The images need a sign-in. Use the registry username and read-only token you were given."
        read -rp "Registry username: " user
        read -rsp "Token (hidden): " token && echo
        printf '%s' "$token" | "$E" login "${registry%%/*}" -u "$user" --password-stdin
        "${C[@]}" pull --quiet
    fi
fi
say "Starting (this takes a minute on first start: databases, migrations)"
"${C[@]}" up -d --remove-orphans --scale worker="$WORKERS"

printf 'Waiting for the portal'
for _ in $(seq 1 60); do
    curl -fs "http://localhost:$PORT/api/health" >/dev/null 2>&1 && ready=1 && break
    printf '.'; sleep 5
done
echo
[[ "${ready:-}" == 1 ]] || fail "Not up after 5 minutes. See: ${C[*]} ps; ${C[*]} logs identity execution"

# -- 5. First sign-in ----------------------------------------------------------
say "Portal is up: http://localhost:$PORT"
"${C[@]}" logs identity 2>&1 | grep -A5 "GENERATED INITIAL CREDENTIALS" \
    || echo "No new passwords printed: the accounts already exist from an earlier run."
cat <<EOF

Next:
  1. Open http://localhost:$PORT and sign in as 'admin' (password printed on the first run).
  2. Change it under My account.
  3. Open Onboarding and run the steps (install packages, provision, build, reports).

Manage (from $ROOT):
  ${C[*]} ps                          # what is running
  ${C[*]} logs -f execution worker    # dbt runs
  ${C[*]} up -d --scale worker=3      # more dbt jobs at once
  ${C[*]} stop / ${C[*]} start        # stop, start again
  ${C[*]} down -v                     # uninstall (deletes accounts and history)
EOF
