#!/usr/bin/env bash
# Runs the dbt Portal for one dbt project, from the pre-built images.
# Needs only Docker or Podman: no compose, no build, no Python/Node/dbt.
#
#   ./setup.sh /path/to/my-dbt-project
#   ./setup.sh /path/to/my-dbt-project --port 8081 --tag 1.2.0
#   ./setup.sh /path/to/my-dbt-project --skip-pull   # images already here (docker load)
#
# Run it again to upgrade or change the port: accounts and history are kept.
# Optional portal settings (LDAP, SMTP, AI keys...) go in a .env next to this
# script, see .env.example. Warehouse credentials stay in the project's own .env.
set -euo pipefail
cd "$(dirname "$0")"

REGISTRY="${IMAGE_REGISTRY:-ghcr.io/omaryehia015/capgemini-dbt-portal}"
TAG=latest
PORT=8080
PROJECT=""
SKIP_PULL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        --skip-pull) SKIP_PULL=1; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) PROJECT="$1"; shift ;;
    esac
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# -- 1. Docker or Podman -----------------------------------------------------
if docker info >/dev/null 2>&1; then E=docker
elif podman info >/dev/null 2>&1; then E=podman
else fail "Start Docker (or Podman) first."; fi
say "Using $E"

# -- 2. The dbt project --------------------------------------------------------
[[ -n "$PROJECT" ]] || read -rp "Path to your dbt project (the folder with dbt_project.yml): " PROJECT
PROJECT="${PROJECT/#\~/$HOME}"
[[ -f "$PROJECT/dbt_project.yml" ]] || fail "No dbt_project.yml in '$PROJECT'."
PROJECT="$(cd "$PROJECT" && pwd)"
[[ -f "$PROJECT/.env" ]] || echo "WARNING: $PROJECT/.env is missing. The portal reads the warehouse credentials from it."

# Where profiles.yml is: in the project (seen as /workspace), or ~/.dbt.
extra=()
if [[ -f "$PROJECT/profiles.yml" ]]; then :
elif [[ -f "$PROJECT/profiles/profiles.yml" ]]; then extra+=(-e DBT_PROFILES_DIR=/workspace/profiles)
elif [[ -f "$HOME/.dbt/profiles.yml" ]]; then extra+=(-v "$HOME/.dbt:/profiles:ro" -e DBT_PROFILES_DIR=/profiles)
else echo "WARNING: no profiles.yml found in the project or ~/.dbt."; fi
[[ -f .env ]] && extra+=(--env-file .env)
# SELinux (Fedora/RHEL) would otherwise block the project mount.
[[ "$E" == podman && "$(uname -s)" == Linux ]] && extra+=(--security-opt label=disable)

# One set of names per project, so several projects can run side by side.
slug="$(basename "$PROJECT" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-')"
NAME="dbt-portal-$slug"
say "Project $PROJECT -> containers $NAME-*"

# -- 3. Pull the images (sign in if they are private) --------------------------
BACKEND="$REGISTRY-backend:$TAG"
FRONTEND="$REGISTRY-frontend:$TAG"
if [[ -n "$SKIP_PULL" ]]; then
    "$E" image inspect "$BACKEND" >/dev/null 2>&1 && "$E" image inspect "$FRONTEND" >/dev/null 2>&1         || fail "$BACKEND / $FRONTEND are not on this machine."
    say "Using the images already on this machine"
elif ! { say "Pulling $BACKEND and $FRONTEND"; "$E" pull "$BACKEND" && "$E" pull "$FRONTEND"; }; then
    echo "The images need a sign-in. Use the registry username and read-only token you were given."
    read -rp "Registry username: " user
    read -rsp "Token (hidden): " token && echo
    printf '%s' "$token" | "$E" login "${REGISTRY%%/*}" -u "$user" --password-stdin
    "$E" pull "$BACKEND" && "$E" pull "$FRONTEND"
fi

# -- 4. Start (replaces old containers; the data volume is kept) ---------------
say "Starting"
"$E" rm -f "$NAME-frontend" "$NAME-backend" >/dev/null 2>&1 || true
"$E" network create "$NAME" >/dev/null 2>&1 || true
"$E" volume create "$NAME-data" >/dev/null 2>&1 || true
# Root inside the container: bind mounts on Windows/macOS and rootless Podman need it for `dbt deps`.
"$E" run -d --name "$NAME-backend" --network "$NAME" --network-alias backend --restart unless-stopped \
    --user 0:0 -e DBT_PROJECT_DIR=/workspace -e ENVIRONMENT=production \
    -v "$PROJECT:/workspace" -v "$NAME-data:/data" ${extra[@]+"${extra[@]}"} "$BACKEND" >/dev/null
"$E" run -d --name "$NAME-frontend" --network "$NAME" --restart unless-stopped \
    -p "$PORT:8080" -e BACKEND_UPSTREAM=backend:8000 "$FRONTEND" >/dev/null \
    || fail "Could not start the frontend (port $PORT taken?). Try: ./setup.sh '$PROJECT' --port 8081"

printf 'Waiting for the portal'
for _ in $(seq 1 60); do
    curl -fs "http://localhost:$PORT/api/health" >/dev/null 2>&1 && ready=1 && break
    printf '.'; sleep 5
done
echo
[[ "${ready:-}" == 1 ]] || fail "Not up after 5 minutes. See: $E logs $NAME-backend"

# -- 5. First sign-in ----------------------------------------------------------
say "Portal is up: http://localhost:$PORT"
"$E" logs "$NAME-backend" 2>&1 | grep -A5 "GENERATED INITIAL CREDENTIALS" \
    || echo "No new passwords printed: the accounts already exist from an earlier run."
cat <<EOF

Next:
  1. Open http://localhost:$PORT and sign in as 'admin' (password printed on the first run).
  2. Change it under My account.
  3. Open Onboarding and run the steps (install packages, provision, build, reports).

Manage:
  $E logs -f $NAME-backend   # what the backend is doing
  $E stop $NAME-frontend $NAME-backend   # stop
  $E start $NAME-backend $NAME-frontend   # start again
  $E rm -f $NAME-frontend $NAME-backend && $E volume rm $NAME-data   # uninstall (deletes accounts)
EOF
