#!/usr/bin/env bash
# Runs the dbt Portal (microservices stack) for one dbt project, from the
# pre-built images. Needs Docker or Podman with compose; no build, no
# Python/Node/dbt on this machine. macOS, Linux, WSL and Linux VMs.
#
#   ./setup.sh                                         # connect the dbt project (Git) in the portal
#   ./setup.sh --projects-root ~/work                  # share a folder; pick the project in the portal
#   ./setup.sh /path/to/my-dbt-project
#   ./setup.sh /path/to/my-dbt-project --port 8081 --release 2026.10.0
#   ./setup.sh /path/to/my-dbt-project --skip-pull     # images already here (docker load)
#   ./setup.sh /path/to/my-dbt-project --workers 3     # run more dbt jobs at once
#   ./setup.sh --answers portal.answers                # zero-touch: no questions asked
#   ./setup.sh --check                                 # only check this machine
#
# The first run writes .env next to compose.yaml with generated secrets; later
# runs keep it (accounts, history and sessions survive upgrades). Optional
# portal settings (LDAP, SMTP, AI keys, AIRFLOW_URL...) go in that .env too.
# Warehouse credentials stay in the project's own .env.
#
# Private images: export PORTAL_TOKEN (a read-only registry token, with
# PORTAL_USER_NAME to override the user name the token belongs to) and the
# script signs in for you.
#
# An answers file is KEY=VALUE lines: PROJECT, PORT, RELEASE and WORKERS set
# the options above; any other key (AIRFLOW_URL, AIRBYTE_MODE=off, ...) is
# written to .env. See portal.answers.example.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# Works from the repo (deploy/client/) and from the unpacked client kit (flat).
if [[ -f "$here/compose.yaml" ]]; then ROOT="$here"; else ROOT="$(cd "$here/../.." && pwd)"; fi
# shellcheck source=lib.sh
source "$here/lib.sh"
cd "$ROOT"

PORT=""
PROJECT=""
PROJECTS_ROOT=""
RELEASE=""
SKIP_PULL=""
WORKERS=1
ANSWERS=""
CHECK_ONLY=""
NON_INTERACTIVE=""
NO_BROWSER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --release) RELEASE="$2"; shift 2 ;;
        --projects-root) PROJECTS_ROOT="$2"; shift 2 ;;
        --workers) WORKERS="$2"; shift 2 ;;
        --answers) ANSWERS="$2"; NON_INTERACTIVE=1; shift 2 ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        --skip-pull) SKIP_PULL=1; shift ;;
        --check) CHECK_ONLY=1; shift ;;
        --no-browser) NO_BROWSER=1; shift ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) PROJECT="$1"; shift ;;
    esac
done

# -- 0. This machine -----------------------------------------------------------
host_check "$ROOT" || fail "Fix the items marked ✖ above, then run this again."
[[ -n "$CHECK_ONLY" ]] && exit 0
say "Using ${C[*]}"

# -- 1. Answers file -----------------------------------------------------------
declare -a EXTRA_ENV=()
if [[ -n "$ANSWERS" ]]; then
    [[ -f "$ANSWERS" ]] || fail "Answers file '$ANSWERS' not found."
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"; line="${line%"${line##*[![:space:]]}"}"
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"; value="${line#*=}"
        case "$key" in
            PROJECT) [[ -n "$PROJECT" ]] || PROJECT="$value" ;;
            PROJECTS_ROOT) [[ -n "$PROJECTS_ROOT" ]] || PROJECTS_ROOT="$value" ;;
            PORT) [[ -n "$PORT" ]] || PORT="$value" ;;
            RELEASE) [[ -n "$RELEASE" ]] || RELEASE="$value" ;;
            WORKERS) WORKERS="$value" ;;
            *) EXTRA_ENV+=("$key=$value") ;;
        esac
    done < "$ANSWERS"
fi

# -- 2. The dbt project --------------------------------------------------------
# No folder given: the portal gets the project from a Git repository you connect
# in its Setup Assistant (the portal keeps its own copy). A folder is mounted live.
if [[ -z "$PROJECT" && -z "$PROJECTS_ROOT" && -z "$NON_INTERACTIVE" ]]; then
    say "Your dbt project"
    echo "  1) A Git repository (you connect it in the portal; recommended)"
    echo "  2) A folder on this machine (you pick the project in the portal)"
    read -rp "Choose 1 or 2 [1]: " choice
    if [[ "$choice" == 2 ]]; then
        read -rp "Folder that holds your dbt project (or several; a parent folder is fine): " PROJECTS_ROOT
    fi
fi
if [[ -n "$PROJECTS_ROOT" ]]; then
    PROJECTS_ROOT="${PROJECTS_ROOT/#\~/$HOME}"
    [[ -d "$PROJECTS_ROOT" ]] || fail "The folder '$PROJECTS_ROOT' does not exist."
    PROJECTS_ROOT="$(cd "$PROJECTS_ROOT" && pwd)"
    ok "Sharing $PROJECTS_ROOT with the portal: you pick the project in the Setup Assistant"
    [[ -z "$PROJECT" ]] || warn "A project folder is used as a fixed project; --projects-root only adds the shared folder."
fi
GIT_MODE=""
if [[ -z "$PROJECT" ]]; then
    GIT_MODE=1
    [[ -n "$PROJECTS_ROOT" ]] || ok "The project is connected in the portal (Setup Assistant)"
else
    PROJECT="${PROJECT/#\~/$HOME}"
    [[ -f "$PROJECT/dbt_project.yml" ]] || fail "No dbt_project.yml in '$PROJECT'."
    PROJECT="$(cd "$PROJECT" && pwd)"
    [[ -f "$PROJECT/.env" ]] || warn "$PROJECT/.env is missing. The portal reads the warehouse credentials from it."
fi

# -- 3. .env: secrets once, project / port / versions every run ----------------
secret() { head -c 36 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-40; }

if [[ ! -f .env ]]; then
    say "Writing .env with generated secrets"
    cp .env.example .env
    chmod 600 .env
fi
for key in JWT_SECRET CUBE_API_SECRET POSTGRES_PASSWORD REDIS_PASSWORD; do
    [[ -n "$(get_env "$key")" ]] || set_env "$key" "$(secret)"
done
# Empty: compose falls back to its own workspace volume, where the portal clones the repository.
if [[ -n "$GIT_MODE" ]]; then set_env DBT_PROJECT_PATH ""; else set_env DBT_PROJECT_PATH "$PROJECT"; fi
# The host folder shared with the portal; empty falls back to an unused volume.
set_env DBT_PROJECTS_ROOT "$PROJECTS_ROOT"
set_env PORTAL_PROJECTS_HOST "$PROJECTS_ROOT"
[[ -n "$PORT" ]] && set_env PORTAL_PORT "$PORT"
PORT="$(get_env PORTAL_PORT)"; PORT="${PORT:-8080}"
for pair in "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}"; do set_env "${pair%%=*}" "${pair#*=}"; done
[[ ${#EXTRA_ENV[@]} -gt 0 ]] && say "Applied ${#EXTRA_ENV[@]} setting(s) from $ANSWERS"

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
if [[ -n "$GIT_MODE" ]]; then :
elif [[ -f "$PROJECT/profiles.yml" ]]; then :
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
else warn "No profiles.yml found in the project or ~/.dbt."; fi
# Bind mounts on macOS / rootless Podman: root inside the container, so `dbt deps` can write.
[[ ( -z "$GIT_MODE" || -n "$PROJECTS_ROOT" ) && ( "$(uname -s)" == Darwin || "$E" == podman ) ]] && set_env PORTAL_USER 0:0

# -- 4. Pull and start ---------------------------------------------------------
# GHCR accepts a token only with the GitHub name of its owner: ask GitHub whose it is.
registry_user() {  # registry_user TOKEN
    local login=""
    if [[ -n "${PORTAL_USER_NAME:-}" ]]; then echo "$PORTAL_USER_NAME"; return; fi
    login="$(curl -fsS --max-time 15 -H "Authorization: Bearer $1" https://api.github.com/user 2>/dev/null \
        | sed -n 's/^ *"login": *"\([^"]*\)".*/\1/p' | head -1)" || true
    echo "${login:-portal}"
}
registry_login() {  # registry_login USER TOKEN
    local registry; registry="$(get_env IMAGE_REGISTRY)"; registry="${registry:-ghcr.io/omaryehia015}"
    printf '%s' "$2" | "$E" login "${registry%%/*}" -u "$1" --password-stdin >/dev/null 2>&1 \
        || fail "The registry did not accept that token."
    ok "Signed in to ${registry%%/*}"
}
# Podman with an external compose provider (docker-compose) pulls without the
# login podman keeps, so podman pulls the images itself and compose finds them.
pull_images() {
    local images image
    if [[ "$E" == podman ]]; then
        images="$("${C[@]}" config --images 2>/dev/null | grep -v '^>>>>' | sort -u)" || true
        if [[ -n "$images" ]]; then
            for image in $images; do echo "  $image"; podman pull "$image" || return 1; done
            return 0
        fi
    fi
    "${C[@]}" pull
}
if [[ -z "$SKIP_PULL" ]]; then
    if [[ -n "${PORTAL_TOKEN:-}" ]]; then
        say "Signing in to the image registry"
        registry_login "$(registry_user "$PORTAL_TOKEN")" "$PORTAL_TOKEN"
    fi
    say "Downloading the portal images (a few minutes the first time)"
    if ! pull_images; then
        [[ -z "$NON_INTERACTIVE" ]] || fail "Pulling the images failed. Set PORTAL_TOKEN, or sign in first: $E login ghcr.io"
        echo
        echo "The images are private. Paste the access token you were sent."
        read -rsp "Token (hidden): " token && echo
        registry_login "$(registry_user "$token")" "$token"
        pull_images || fail "Pulling the images failed with that token."
    fi
fi
say "Starting (this takes a minute on first start: databases, migrations)"
"${C[@]}" up -d --remove-orphans --scale worker="$WORKERS"
wait_healthy "$PORT" || fail "Not up after 5 minutes. See: ./manage.sh status; ./manage.sh logs identity"

# -- 5. First sign-in ----------------------------------------------------------
say "Portal is up: http://localhost:$PORT"
"${C[@]}" logs identity 2>&1 | grep -A5 "GENERATED INITIAL CREDENTIALS" \
    || echo "No new passwords printed: the accounts already exist from an earlier run."
url="http://localhost:$PORT/setup"
if [[ -n "$PROJECTS_ROOT" ]]; then next="Step 2 of the Setup Assistant: pick your project from the folder you shared (or use Git)."
elif [[ -n "$GIT_MODE" ]]; then next="Step 2 of the Setup Assistant connects your dbt project (Git)."
else next="Setup Assistant: workspace, warehouse, dbt project, team."; fi
printf '\n\033[1;36m  +----------------------------------------------------------+\n  |  The portal is running                                   |\n  +----------------------------------------------------------+\033[0m\n'
echo "    Open:    $url"
echo "    Sign in: admin (password above; change it under My account)"
echo "    Then:    $next"
cat <<EOF

Day to day (from $ROOT):
  ./manage.sh status            # what is running, and whether it is healthy
  ./manage.sh logs execution    # follow a service's log
  ./manage.sh doctor            # check this machine and the stack
  ./manage.sh help              # everything else
EOF
if [[ -z "$NO_BROWSER" && -z "$NON_INTERACTIVE" ]]; then
    { command -v open >/dev/null && open "$url"; } || { command -v xdg-open >/dev/null && xdg-open "$url"; } >/dev/null 2>&1 || true
fi
