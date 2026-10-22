#!/usr/bin/env bash
# Manage the Capgemini dbt Portal from this repo: Docker/Podman Compose and Helm.
#
#   scripts/portal.sh [options] <command> [service]
#
# Compose commands
#   init            create .env from .env.example, generate the empty secrets, write the
#                   local compose override if this machine needs one
#   check           validate tools, settings, project source, image tags and the Compose
#                   rendering (add --helm to check the Helm prerequisites too)
#   build [svc]     build the images from the sibling repos (implies --build)
#   pull [svc]      pull the published images
#   up              start the stack in the background
#   down            stop it and remove the containers (data is kept)
#   restart [svc]   restart the stack, or one service
#   status          containers and the portal's own health/version
#   logs [svc]      follow the logs (--no-follow: print and exit)
#   clean           remove containers, networks and locally built images (data is kept)
#   release         print the image tags of a release from releases.yml (--release NAME)
#
# Helm commands (chart: deploy/helm/dbt-portal; release and namespace: dbt-portal)
#   helm-template   render the chart (default values: values-dev.yaml)
#   helm-install    install            helm-upgrade   upgrade an installed release
#   helm-status     status             helm-rollback  [revision] roll back
#   helm-uninstall  uninstall (persistent volume claims are kept unless --volumes)
#
# Options
#   --single             the single-node stack (compose.single.yaml): SQLite, no Redis, no worker
#   --build              build the images from the sibling repos (compose.build.yaml)
#   --cube-sql           also publish Cube's SQL API (compose.cube-sql.yaml)
#   --engine docker|podman   the Compose provider (default: PORTAL_ENGINE, else the first of
#                        docker compose, podman compose that works)
#   --env-file FILE      the env file (default: .env in this repo)
#   --values FILE        a Helm values file (repeatable; later files win)
#   --release NAME       the portal release for image tags (default: latest in releases.yml)
#   --set KEY=VALUE      extra Helm value (repeatable; prefer a values file for secrets)
#   --name NAME          Helm release name (default: dbt-portal; PORTAL_HELM_RELEASE)
#   --namespace NS       Helm namespace (default: dbt-portal; PORTAL_HELM_NAMESPACE)
#   --volumes            with down/clean/helm-uninstall: ALSO delete the data (asks first)
#   --yes, -y            do not ask for confirmation (needed when there is no terminal)
#   --no-follow          logs: print the recent lines and exit
#   --helm               check: include the Helm prerequisites
#   --chart REF          the chart: a folder, or oci://ghcr.io/<owner>/charts/dbt-portal (default: the
#                        chart in this checkout / kit). OCI: the version defaults to the release (--chart-version)
#   --chart-version V    the chart version to fetch from a registry
#   --pull-secret        helm-install/upgrade: make the registry pull Secret ghcr-pull from the token in
#                        PORTAL_TOKEN (private images) and use it; the token is never printed
#   -h, --help           this text
#
# Secrets are never printed: init reports which keys it generated, check reports
# which are missing, and neither shows a value. Nothing is deleted without --volumes.
# Works from any directory. Needs bash 3.2+.
set -euo pipefail

ORIG_PWD="$PWD"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# In the repo this script is scripts/portal.sh; in the client kit it sits next to compose.yaml.
if [[ -f "$SCRIPT_DIR/compose.yaml" ]]; then ROOT="$SCRIPT_DIR"; else ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"; fi
CHART_DIR="$ROOT/deploy/helm/dbt-portal"

# ── output ───────────────────────────────────────────────────────────────────
if [[ -t 2 ]]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'; C_CYN=$'\033[1;36m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_OFF=""
fi
say()  { printf '%s==>%s %s\n' "$C_CYN" "$C_OFF" "$*" >&2; }
ok()   { printf '  %sok%s    %s\n' "$C_GRN" "$C_OFF" "$*" >&2; }
warn() { printf '  %sWARN%s  %s\n' "$C_YEL" "$C_OFF" "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
bad()  { printf '  %sFAIL%s  %s\n' "$C_RED" "$C_OFF" "$*" >&2; FAILURES=$((FAILURES + 1)); }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
usage_error() { printf '%sERROR:%s %s\n(see: %s --help)\n' "$C_RED" "$C_OFF" "$*" "$0" >&2; exit 2; }
WARNINGS=0
FAILURES=0

# ── temp files ───────────────────────────────────────────────────────────────
# Created up front, in this shell (not inside $(...)), and removed on exit.
TMP_DIR=""
cleanup() { [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
TMP_DIR="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/portal.XXXXXX")" || die "cannot create a temporary directory"
tmp_dir() { printf '%s' "$TMP_DIR"; }

# ── arguments ────────────────────────────────────────────────────────────────
MODE=full
BUILD=0
CUBE_SQL=0
ENGINE="${PORTAL_ENGINE:-}"
ENV_FILE="$ROOT/.env"
ENV_FILE_CUSTOM=0
RELEASE=""
VOLUMES=0
YES=0
FOLLOW=1
CHECK_HELM=0
PULL_SECRET=0
CHART_REF=""
CHART_VERSION=""
HELM_NAME="${PORTAL_HELM_RELEASE:-dbt-portal}"
HELM_NAMESPACE="${PORTAL_HELM_NAMESPACE:-dbt-portal}"
VALUES_FILES=()
HELM_SETS=()
POSITIONAL=()
COMMAND=""

abs_from_invocation() {
    case "$1" in
        /* | [A-Za-z]:[\\/]*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$ORIG_PWD" "$1" ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --single) MODE=single; shift ;;
        --build) BUILD=1; shift ;;
        --cube-sql) CUBE_SQL=1; shift ;;
        --engine) [[ $# -ge 2 ]] || usage_error "--engine needs docker or podman"; ENGINE="$2"; shift 2 ;;
        --env-file) [[ $# -ge 2 ]] || usage_error "--env-file needs a path"; ENV_FILE="$(abs_from_invocation "$2")"; ENV_FILE_CUSTOM=1; shift 2 ;;
        --values | -f) [[ $# -ge 2 ]] || usage_error "--values needs a path"; VALUES_FILES+=("$(abs_from_invocation "$2")"); shift 2 ;;
        --release) [[ $# -ge 2 ]] || usage_error "--release needs a name or 'latest'"; RELEASE="$2"; shift 2 ;;
        --set) [[ $# -ge 2 ]] || usage_error "--set needs KEY=VALUE"; HELM_SETS+=("$2"); shift 2 ;;
        --name) [[ $# -ge 2 ]] || usage_error "--name needs a Helm release name"; HELM_NAME="$2"; shift 2 ;;
        --namespace | -n) [[ $# -ge 2 ]] || usage_error "--namespace needs a name"; HELM_NAMESPACE="$2"; shift 2 ;;
        --volumes) VOLUMES=1; shift ;;
        --yes | -y) YES=1; shift ;;
        --no-follow) FOLLOW=0; shift ;;
        --helm) CHECK_HELM=1; shift ;;
        --pull-secret) PULL_SECRET=1; shift ;;
        --chart) [[ $# -ge 2 ]] || usage_error "--chart needs a folder or an oci:// reference"; CHART_REF="$2"; shift 2 ;;
        --chart-version) [[ $# -ge 2 ]] || usage_error "--chart-version needs a version"; CHART_VERSION="$2"; shift 2 ;;
        -h | --help | help) sed -n '2,51p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --) shift; while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
        -*) usage_error "unknown option: $1" ;;
        *) if [[ -z "$COMMAND" ]]; then COMMAND="$1"; else POSITIONAL+=("$1"); fi; shift ;;
    esac
done
[[ -n "$COMMAND" ]] || usage_error "no command given"
case "$ENGINE" in "" | docker | podman) ;; *) usage_error "--engine must be docker or podman (got '$ENGINE')" ;; esac
[[ "$HELM_NAME" =~ ^[a-z0-9]([a-z0-9.-]{0,51}[a-z0-9])?$ ]] || usage_error "invalid Helm release name '$HELM_NAME'"
[[ "$HELM_NAMESPACE" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || usage_error "invalid namespace '$HELM_NAMESPACE'"

[[ -f "$ROOT/compose.yaml" ]] || die "compose.yaml not found in $ROOT: is scripts/ inside the deploy repo?"
cd "$ROOT"

# ── helpers ──────────────────────────────────────────────────────────────────
# Windows (Git Bash, Cygwin): docker.exe and helm.exe want native paths.
native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# env_get KEY [FILE]: the value of the last "KEY=value" line, without sourcing the
# file: surrounding whitespace and one layer of quotes dropped, and an unquoted
# trailing " # comment" removed (what Compose's own dotenv reader does).
env_get() {
    local key="$1" file="${2:-$ENV_FILE}" value=""
    [[ -f "$file" ]] || return 0
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "internal error: bad variable name '$key'"
    # One awk pass (a bash loop per lookup is slow): the raw text after the last "KEY=".
    value="$(awk -v k="$key" '
        { line = $0; sub(/\r$/, "", line)
          if (match(line, "^[ \t]*(export[ \t]+)?" k "[ \t]*=")) { found = 1; val = substr(line, RLENGTH + 1) } }
        END { if (found) printf "%s", val }' "$file")"
    [[ -n "$value" ]] || return 0
    value="${value#"${value%%[![:space:]]*}"}"
    if [[ "$value" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then value="${BASH_REMATCH[1]}"
    else
        value="${value%%[[:space:]]#*}"
        value="${value%"${value##*[![:space:]]}"}"
    fi
    printf '%s' "$value"
}

# cfg KEY: the process environment wins over the env file, as it does for Compose.
cfg() {
    if [[ -n "${!1+x}" ]]; then printf '%s' "${!1}"; else env_get "$1"; fi
}

# env_set KEY VALUE FILE: replace the last KEY= line in place, or append one. The value
# travels in the environment, so awk does not interpret backslashes in it.
env_set() {
    local key="$1" value="$2" file="$3" tmp
    tmp="$(tmp_dir)/envset.$$"
    KEY="$key" VAL="$value" awk '
        BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VAL"] }
        { lines[NR] = $0; line = $0; sub(/\r$/, "", line)
          if (match(line, "^[ \t]*(export[ \t]+)?" k "[ \t]*=")) last = NR }
        END {
            for (i = 1; i <= NR; i++) { if (i == last) print k "=" v; else print lines[i] }
            if (!last) print k "=" v
        }' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

is_placeholder() {  # empty, or an obvious "fill me in" value
    local v="$1" lower
    [[ -n "${v// /}" ]] || return 0
    lower="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
    [[ "$lower" =~ (change[-_ ]?me|replace[-_ ]?me|todo|placeholder|^x{1,3}$|^<.*>$|^your[-_]) ]]
}

gen_secret() {  # 48 URL-safe characters (letters and digits): fit in a database URL unescaped
    local s=""
    if command -v openssl >/dev/null 2>&1; then s="$(openssl rand -base64 64 2>/dev/null | tr -d '/+=\n' | cut -c1-48)" || s=""; fi
    if [[ ${#s} -lt 40 ]]; then s="$(head -c 96 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-48)"; fi
    [[ ${#s} -ge 40 ]] || die "could not generate a random secret (need openssl, or /dev/urandom and base64)"
    printf '%s' "$s"
}

file_mode() {  # octal permissions, empty if unknown
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}

confirm() {  # confirm "question" expected-answer
    local question="$1" expected="$2" answer=""
    if [[ "$YES" == 1 ]]; then return 0; fi
    [[ -t 0 ]] || die "refusing to continue without a terminal: pass --yes to confirm"
    printf '%s ' "$question" >&2
    read -r answer || true
    [[ "$answer" == "$expected" ]] || die "cancelled"
}

yaml_str() {  # a double-quoted YAML scalar
    local s="$1"
    case "$s" in *$'\n'* | *$'\r'*) die "a path contains a line break and cannot be used" ;; esac
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

# ── Compose provider ─────────────────────────────────────────────────────────
COMPOSE=()
ENGINE_SEL=""

# select_engine NEED_DAEMON: sets COMPOSE and ENGINE_SEL; docker compose first, then
# podman compose (or only --engine / PORTAL_ENGINE). Returns 1 with a reason on stderr.
select_engine() {
    local need_daemon="$1" cand reasons=""
    local -a order=()
    if [[ -n "$ENGINE" ]]; then order=("$ENGINE"); else order=(docker podman); fi
    for cand in "${order[@]}"; do
        if ! command -v "$cand" >/dev/null 2>&1; then reasons="$reasons"$'\n'"  $cand: not installed"; continue; fi
        if ! "$cand" compose version >/dev/null 2>&1; then reasons="$reasons"$'\n'"  $cand: no 'compose' subcommand or provider"; continue; fi
        if [[ "$need_daemon" == 1 ]] && ! "$cand" info >/dev/null 2>&1; then
            reasons="$reasons"$'\n'"  $cand: installed, but its engine does not answer (start it: Docker Desktop, 'podman machine start', or the docker service)"
            continue
        fi
        ENGINE_SEL="$cand"
        COMPOSE=("$cand" compose)
        return 0
    done
    printf '%s' "$reasons" > "$(tmp_dir)/engine.reasons"
    return 1
}

require_engine() {  # require_engine NEED_DAEMON
    if ! select_engine "$1"; then
        printf '%sERROR:%s no usable Compose provider%s:\n' "$C_RED" "$C_OFF" "${ENGINE:+ (--engine $ENGINE)}" >&2
        cat "$(tmp_dir)/engine.reasons" >&2
        printf '\nInstall Docker (with the compose plugin) or Podman (with podman-compose or docker-compose).\n' >&2
        exit 1
    fi
}

# ── project source ───────────────────────────────────────────────────────────
PROJECT_SOURCE_RESOLVED=""
PROJECT_PATH_ABS=""
OVERRIDE_FILE="$ROOT/compose.override.yaml"
OVERRIDE_MARK="# Generated by scripts/portal.sh"

# export_compose_env gives Compose its own DBT_PROJECT_PATH (the mount, or empty), which
# is not what the user wrote. The user's setting is saved first and read from here.
project_path_setting() {
    if [[ -n "${DBT_PATH_SAVED+x}" ]]; then printf '%s' "$DBT_PATH_SAVED"; else cfg DBT_PROJECT_PATH; fi
}

resolve_project_source() {
    local src git path
    src="$(cfg PROJECT_SOURCE)"
    git="$(cfg DBT_PROJECT_GIT_URL)"
    path="$(project_path_setting)"
    if [[ -z "$src" ]]; then
        if [[ -n "$git" ]]; then src=git
        elif [[ -n "$path" ]]; then src=local
        else src=volume; fi
    fi
    case "$src" in local | git | volume) ;; *) die "PROJECT_SOURCE must be local, git or volume (got '$src')" ;; esac
    PROJECT_SOURCE_RESOLVED="$src"
    PROJECT_PATH_ABS=""
    if [[ "$src" == local && -n "$path" ]]; then
        # A literal "~" typed in the env file: the shell never expanded it.
        # shellcheck disable=SC2088
        case "$path" in
            '~') path="$HOME" ;;
            '~/'*) path="$HOME/${path#'~/'}" ;;
        esac
        case "$path" in
            /* | [A-Za-z]:[\\/]*) PROJECT_PATH_ABS="$path" ;;
            *) PROJECT_PATH_ABS="$ROOT/$path" ;;
        esac
    fi
}

# A path Compose's short "host:container" volume syntax reads unambiguously. Not on
# Windows shells, where the engine needs a native path (the override writes one).
safe_short_path() {
    [[ "$1" =~ ^[A-Za-z0-9._/@+-]+$ ]] && ! command -v cygpath >/dev/null 2>&1
}

# Compose resolves interpolation from the process environment before the env file, so
# the project source picked here (PROJECT_SOURCE) wins for the mounts.
export_compose_env() {
    resolve_project_source
    if [[ -z "${DBT_PATH_SAVED+x}" ]]; then DBT_PATH_SAVED="$(cfg DBT_PROJECT_PATH)"; fi
    case "$PROJECT_SOURCE_RESOLVED" in
        local)
            if [[ -n "$PROJECT_PATH_ABS" ]]; then
                if safe_short_path "$PROJECT_PATH_ABS"; then DBT_PROJECT_PATH="$PROJECT_PATH_ABS"; else DBT_PROJECT_PATH=""; fi
            else
                DBT_PROJECT_PATH=""
            fi
            ;;
        *) DBT_PROJECT_PATH="" ;;
    esac
    export DBT_PROJECT_PATH
    if [[ "$ENV_FILE_CUSTOM" == 1 ]]; then PORTAL_ENV_FILE="$(native_path "$ENV_FILE")"; export PORTAL_ENV_FILE; fi
    return 0
}

# ── the local override ───────────────────────────────────────────────────────
# What this machine needs on top of the shared Compose files:
#   - a project path the short volume syntax cannot carry (spaces, a Windows shell)
#   - an existing named volume as the workspace (DBT_WORKSPACE_VOLUME)
#   - the user's ~/.dbt/profiles.yml, when the project has none of its own
# Returns the YAML on stdout; empty when nothing is needed.
override_services() {  # prints the services that run dbt in this mode
    if [[ "$MODE" == single ]]; then printf 'backend\n'; else printf 'backend\nworker\n'; fi
}

build_override() {
    local path src subdir svc workspace_volume proj
    local long_workspace=0 external_volume=0 mount_profiles=0
    local body="" vols=""
    resolve_project_source
    src="$PROJECT_SOURCE_RESOLVED"
    path="$PROJECT_PATH_ABS"
    workspace_volume="$(cfg DBT_WORKSPACE_VOLUME)"
    subdir="$(cfg DBT_PROJECT_SUBDIR)"

    if [[ "$src" == local && -n "$path" ]] && ! safe_short_path "$path"; then long_workspace=1; fi
    if [[ "$src" == volume && -n "$workspace_volume" ]]; then external_volume=1; fi
    # The user's ~/.dbt/profiles.yml, when the project brings none (what setup.sh does).
    if [[ "$src" == local && -n "$path" && -z "$(cfg DBT_PROFILES_DIR)" && -f "$HOME/.dbt/profiles.yml" ]]; then
        proj="$path"
        [[ -z "$subdir" ]] || proj="$path/$subdir"
        if [[ ! -f "$proj/profiles.yml" && ! -f "$path/profiles.yml" && ! -f "$proj/profiles/profiles.yml" && ! -f "$path/profiles/profiles.yml" ]]; then
            mount_profiles=1
        fi
    fi
    [[ "$long_workspace$external_volume$mount_profiles" != 000 ]] || return 0

    body="services:"$'\n'
    while IFS= read -r svc; do
        vols=""
        if [[ "$long_workspace" == 1 ]]; then
            vols="${vols}      - type: bind"$'\n'"        source: $(yaml_str "$(native_path "$path")")"$'\n'"        target: /workspace"$'\n'
        fi
        if [[ "$mount_profiles" == 1 ]]; then
            vols="${vols}      - type: bind"$'\n'"        source: $(yaml_str "$(native_path "$HOME/.dbt")")"$'\n'"        target: /profiles"$'\n'"        read_only: true"$'\n'
        fi
        [[ -n "$vols" ]] || continue
        body="${body}  ${svc}:"$'\n'
        [[ "$mount_profiles" == 0 ]] || body="${body}    environment:"$'\n'"      DBT_PROFILES_DIR: /profiles"$'\n'
        body="${body}    volumes:"$'\n'"${vols}"
    done < <(override_services)
    if [[ "$external_volume" == 1 ]]; then
        [[ "$body" != "services:"$'\n' ]] || body=""
        body="${body}volumes:"$'\n'"  workspace:"$'\n'"    external: true"$'\n'"    name: $(yaml_str "$workspace_volume")"$'\n'
    fi
    printf '%s' "$body"
}

override_is_ours() {
    [[ -f "$OVERRIDE_FILE" ]] && head -n 1 "$OVERRIDE_FILE" | grep -q "^$OVERRIDE_MARK"
}
override_mode() {
    sed -n 's/^# mode: \([a-z]*\).*$/\1/p' "$OVERRIDE_FILE" | head -n 1
}

# Writes, refreshes or removes compose.override.yaml. Never touches a file this script
# did not write (users keep their own, e.g. an external DATABASE_URL).
OVERRIDE_STATE=""
FOREIGN_OVERRIDE_MESSAGE="compose.override.yaml exists and was not written by scripts/portal.sh, but this machine needs one (a project path with spaces, an external workspace volume, or ~/.dbt/profiles.yml). Move it aside or merge these settings into it, then run again."

override_file_text() {  # override_file_text YAML
    printf '%s (mode: %s). Local to this machine and ignored by git; rewritten by init/up.\n# mode: %s\n%s\n' \
        "$OVERRIDE_MARK" "$MODE" "$MODE" "$1"
}

sync_override() {
    local yaml
    yaml="$(build_override)"
    OVERRIDE_STATE="none"
    if [[ -n "$yaml" ]]; then
        if [[ -f "$OVERRIDE_FILE" ]] && ! override_is_ours; then die "$FOREIGN_OVERRIDE_MESSAGE"; fi
        ( umask 077; override_file_text "$yaml" > "$OVERRIDE_FILE" )
        OVERRIDE_STATE="written"
    elif override_is_ours; then
        rm -f "$OVERRIDE_FILE"
        OVERRIDE_STATE="removed"
    elif [[ -f "$OVERRIDE_FILE" ]]; then
        OVERRIDE_STATE="foreign"
    fi
}

# ── Compose files and invocation ─────────────────────────────────────────────
FILES=()
# build_files [OVERRIDE]: the -f arguments for this mode. OVERRIDE (a path) replaces
# compose.override.yaml: `check` renders with a temporary one instead of writing the real file.
build_files() {
    FILES=()
    if [[ "$MODE" == single ]]; then
        FILES+=(-f compose.single.yaml)
        [[ "$BUILD" == 0 ]] || FILES+=(-f compose.single.build.yaml)
    else
        FILES+=(-f compose.yaml)
        [[ "$BUILD" == 0 ]] || FILES+=(-f compose.build.yaml)
    fi
    [[ "$CUBE_SQL" == 0 ]] || FILES+=(-f compose.cube-sql.yaml)
    if [[ -n "${1:-}" ]]; then
        FILES+=(-f "$(native_path "$1")")
    elif [[ -f "$OVERRIDE_FILE" ]]; then
        if override_is_ours; then
            if [[ "$(override_mode)" == "$MODE" ]]; then FILES+=(-f compose.override.yaml); fi
        elif [[ "$MODE" == full ]]; then
            FILES+=(-f compose.override.yaml)
        fi
    fi
}

compose() {
    local -a envopt=()
    [[ "$ENV_FILE_CUSTOM" == 0 ]] || envopt=(--env-file "$(native_path "$ENV_FILE")")
    "${COMPOSE[@]}" ${envopt[@]+"${envopt[@]}"} "${FILES[@]}" "$@"
}

need_env_file() {
    [[ -f "$ENV_FILE" ]] || die "$ENV_FILE does not exist: run 'scripts/portal.sh init' first"
}

prepare_compose() {  # prepare_compose NEED_DAEMON
    need_env_file
    require_engine "$1"
    export_compose_env
    sync_override
    build_files
}

# ── init ─────────────────────────────────────────────────────────────────────
cmd_init() {
    local created=() generated=() key value mode
    [[ -f "$ROOT/.env.example" ]] || die ".env.example not found in $ROOT"
    if [[ ! -f "$ENV_FILE" ]]; then
        ( umask 077; cat "$ROOT/.env.example" > "$ENV_FILE" ) || die "cannot create $ENV_FILE"
        created+=("$ENV_FILE")
    fi
    for key in JWT_SECRET CUBE_API_SECRET POSTGRES_PASSWORD REDIS_PASSWORD; do
        value="$(env_get "$key")"
        if is_placeholder "$value"; then
            env_set "$key" "$(gen_secret)" "$ENV_FILE"
            generated+=("$key")
        fi
    done
    if [[ -n "$RELEASE" ]]; then
        bash "$SCRIPT_DIR/release-tags.sh" --release "$RELEASE" --write-env "$ENV_FILE" 2>&1 | sed 's/^/  /' >&2 || die "could not apply release '$RELEASE'"
    fi
    chmod 600 "$ENV_FILE" 2>/dev/null || warn "could not set permission 600 on $ENV_FILE (this file system has no such permission)"

    # Bind mounts on macOS and under Podman show root-owned files: dbt deps needs 0:0 there
    # (what deploy/client/setup.sh does). Only set when the user has not chosen.
    resolve_project_source
    select_engine 0 || true
    if [[ "$PROJECT_SOURCE_RESOLVED" == local && -z "$(cfg PORTAL_USER)" ]]; then
        if [[ "$(uname -s)" == Darwin || "$ENGINE_SEL" == podman ]]; then
            env_set PORTAL_USER "0:0" "$ENV_FILE"
            echo "  PORTAL_USER=0:0 set (bind mounts on macOS/Podman); remove it to run as 10001:10001" >&2
        fi
    fi
    # Podman does not create a missing backup folder.
    local backup; backup="$(cfg PORTAL_BACKUP_DIR)"
    if [[ -n "$backup" ]]; then
        case "$backup" in /* | [A-Za-z]:[\\/]*) ;; *) backup="$ROOT/$backup" ;; esac
        [[ -d "$backup" ]] || { mkdir -p "$backup" && created+=("$backup/"); }
    fi

    export_compose_env
    sync_override
    case "$OVERRIDE_STATE" in
        written) created+=("$OVERRIDE_FILE") ;;
        foreign) echo "  compose.override.yaml exists (not written by this script): left as it is" >&2 ;;
    esac

    say "init"
    if [[ ${#created[@]} -gt 0 ]]; then
        local f; for f in "${created[@]}"; do printf '  created   %s\n' "$f" >&2; done
    else
        printf '  created   nothing: %s already exists\n' "$ENV_FILE" >&2
    fi
    if [[ ${#generated[@]} -gt 0 ]]; then
        printf '  generated random values for: %s (not shown; they are in %s)\n' "${generated[*]}" "$ENV_FILE" >&2
    else
        printf '  generated nothing: every secret already has a value\n' >&2
    fi
    mode="$(file_mode "$ENV_FILE")"
    [[ -z "$mode" ]] || printf '  permission %s on %s\n' "$mode" "$ENV_FILE" >&2
    printf '\nNext: edit the project source in %s (DBT_PROJECT_PATH, or git), then:\n  scripts/portal.sh check && scripts/portal.sh%s up\n' \
        "$ENV_FILE" "$([[ "$MODE" == single ]] && echo ' --single')" >&2
}

# ── check ────────────────────────────────────────────────────────────────────
check_tools() {
    say "Tools"
    if [[ "${BASH_VERSINFO[0]}" -ge 3 ]]; then ok "bash ${BASH_VERSION%%[!0-9.]*}"; else bad "bash 3.2 or newer is required"; fi
    local t
    for t in awk sed grep; do
        if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t is missing"; fi
    done
    if select_engine 0; then
        local ver; ver="$("${COMPOSE[@]}" version --short 2>/dev/null || "${COMPOSE[@]}" version 2>/dev/null | head -n 1)" || ver=""
        ok "${ENGINE_SEL} compose ${ver:+($ver)}"
        if select_engine 1; then ok "${ENGINE_SEL} engine answers"; else warn "the $ENGINE_SEL engine does not answer: fine for 'check', needed for up/build/pull"; fi
        select_engine 0 || true
    else
        bad "no Compose provider$([[ -z "$ENGINE" ]] || echo " ($ENGINE)")"
        sed 's/^/        /' "$(tmp_dir)/engine.reasons" >&2
    fi
    if command -v curl >/dev/null 2>&1; then ok "curl"; else warn "curl is missing: status and the post-start health wait are skipped"; fi
}

check_env() {
    say "Settings ($ENV_FILE)"
    if [[ ! -f "$ENV_FILE" ]]; then bad "$ENV_FILE does not exist: run 'scripts/portal.sh init'"; return; fi
    ok "env file present"
    local mode; mode="$(file_mode "$ENV_FILE")"
    if [[ -n "$mode" && "$mode" != "600" && "$mode" != "400" ]] && ! command -v cygpath >/dev/null 2>&1; then
        warn "permission $mode on the env file: run chmod 600 on it (it holds secrets)"
    fi
    local key req=(CUBE_API_SECRET)
    [[ "$MODE" == single ]] || req+=(JWT_SECRET POSTGRES_PASSWORD REDIS_PASSWORD)
    for key in "${req[@]}"; do
        if is_placeholder "$(cfg "$key")"; then bad "$key is empty or a placeholder: run 'scripts/portal.sh init' to generate it"; else ok "$key is set"; fi
    done
    if [[ "$MODE" == single ]] && is_placeholder "$(cfg JWT_SECRET)"; then
        warn "JWT_SECRET is empty: the backend generates one on first start and keeps it on its data volume"
    fi
    local port; port="$(cfg PORTAL_PORT)"
    if [[ -n "$port" ]] && ! { [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 && "$port" -le 65535 ]]; }; then bad "PORTAL_PORT must be a port number"; fi
}

check_tags() {
    say "Image tags"
    if [[ "$BUILD" == 1 ]]; then ok "images are built from source: tags are not used"; return; fi
    local part tag reg
    reg="$(cfg IMAGE_REGISTRY)"; ok "registry ${reg:-ghcr.io/omaryehia015}"
    for part in BACKEND FRONTEND CUBE; do
        tag="$(cfg "${part}_TAG")"
        if [[ -z "$tag" ]]; then warn "${part}_TAG is empty: Compose falls back to 'latest' (use ./scripts/release-tags.sh --write-env .env)"
        elif [[ "$tag" == latest ]]; then warn "${part}_TAG=latest is not a pinned release"
        elif [[ ! "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]]; then bad "${part}_TAG is not a valid image tag"
        else ok "${part}_TAG=$tag"; fi
    done
}

check_project() {
    say "dbt project source"
    resolve_project_source
    local git path subdir token
    git="$(cfg DBT_PROJECT_GIT_URL)"; path="$(project_path_setting)"; subdir="$(cfg DBT_PROJECT_SUBDIR)"; token="$(cfg DBT_PROJECT_GIT_TOKEN)"
    ok "mode: $PROJECT_SOURCE_RESOLVED"
    case "$PROJECT_SOURCE_RESOLVED" in
        local)
            if [[ -z "$path" ]]; then bad "PROJECT_SOURCE=local but DBT_PROJECT_PATH is empty"
            elif [[ ! -d "$PROJECT_PATH_ABS" ]]; then bad "DBT_PROJECT_PATH is not a directory: $PROJECT_PATH_ABS"
            else
                ok "directory exists: $PROJECT_PATH_ABS"
                local proj="$PROJECT_PATH_ABS"; [[ -z "$subdir" ]] || proj="$PROJECT_PATH_ABS/$subdir"
                if [[ -f "$proj/dbt_project.yml" ]]; then ok "dbt_project.yml found"; else warn "no dbt_project.yml in $proj (the Setup Assistant can still point the portal at a project)"; fi
                if [[ -f "$proj/profiles.yml" || -f "$PROJECT_PATH_ABS/profiles.yml" || -f "$proj/profiles/profiles.yml" || -f "$HOME/.dbt/profiles.yml" || -n "$(cfg DBT_PROFILES_DIR)" ]]; then
                    ok "a profiles.yml is available"
                else warn "no profiles.yml in the project or ~/.dbt (set DBT_PROFILES_DIR or add one)"; fi
            fi
            [[ -z "$git" ]] || bad "DBT_PROJECT_GIT_URL is set but PROJECT_SOURCE is local: the backend would refuse to clone into a mounted project"
            ;;
        git)
            if [[ -z "$git" ]]; then bad "PROJECT_SOURCE=git but DBT_PROJECT_GIT_URL is empty"
            elif [[ "$git" =~ ^https?://[^/@]*@ ]]; then bad "DBT_PROJECT_GIT_URL embeds credentials: use DBT_PROJECT_GIT_TOKEN (the URL is not shown)"
            elif [[ ! "$git" =~ ^(https?://|ssh://|git@) ]]; then bad "DBT_PROJECT_GIT_URL must start with https://, ssh:// or git@"
            else
                ok "DBT_PROJECT_GIT_URL is set"
                [[ "$git" =~ ^http:// ]] && warn "DBT_PROJECT_GIT_URL uses plain http"
                [[ "$git" =~ ^https:// && -z "$token" ]] && warn "no DBT_PROJECT_GIT_TOKEN: only a public repository can be cloned"
            fi
            [[ -z "$path" ]] || warn "DBT_PROJECT_PATH is set and ignored in git mode (portal.sh passes it empty to Compose; a plain 'docker compose' would mount it)"
            ;;
        volume)
            [[ -z "$git" ]] || bad "DBT_PROJECT_GIT_URL is set but PROJECT_SOURCE is volume"
            [[ -z "$path" ]] || warn "DBT_PROJECT_PATH is set and ignored in volume mode"
            local vol; vol="$(cfg DBT_WORKSPACE_VOLUME)"
            if [[ -n "$vol" ]]; then
                ok "workspace is the existing volume $vol (must exist; declared external in the override)"
                if [[ -n "$ENGINE_SEL" ]] && "$ENGINE_SEL" volume inspect "$vol" >/dev/null 2>&1; then ok "volume $vol exists"
                elif [[ -n "$ENGINE_SEL" ]]; then warn "volume $vol was not found by $ENGINE_SEL (create it, or the engine is not running)"; fi
            else ok "workspace is the Compose volume 'workspace'"; fi
            ;;
    esac
}

check_build() {
    [[ "$BUILD" == 1 ]] || return 0
    say "Source repositories (build mode)"
    local entry var dir default
    for entry in "BACKEND_SRC:../capgemini-dbt-portal-backend" "FRONTEND_SRC:../capgemini-dbt-portal-frontend" "CUBE_SRC:../capgemini-dbt-portal-cube"; do
        var="${entry%%:*}"; default="${entry#*:}"
        dir="$(cfg "$var")"; dir="${dir:-$default}"
        case "$dir" in /* | [A-Za-z]:[\\/]*) ;; *) dir="$ROOT/$dir" ;; esac
        if [[ -f "$dir/Dockerfile" ]]; then ok "$var: $dir (Dockerfile found)"; else bad "$var: no Dockerfile in $dir (check out the repo next to this one, or set $var)"; fi
    done
}

check_render() {
    say "Compose rendering"
    [[ ${#COMPOSE[@]} -gt 0 ]] || { bad "skipped: no Compose provider"; return; }
    [[ -f "$ENV_FILE" ]] || { bad "skipped: no env file"; return; }
    export_compose_env
    # `check` never writes compose.override.yaml: it renders with a temporary copy of what
    # init/up would write.
    local yaml tmp_override=""
    yaml="$(build_override)"
    if [[ -n "$yaml" ]]; then
        if [[ -f "$OVERRIDE_FILE" ]] && ! override_is_ours; then bad "$FOREIGN_OVERRIDE_MESSAGE"; return; fi
        tmp_override="$(tmp_dir)/compose.override.yaml"
        override_file_text "$yaml" > "$tmp_override"
        ok "this machine needs a compose.override.yaml (written by init/up; rendering with a temporary copy)"
    fi
    build_files "$tmp_override"
    local out; out="$(tmp_dir)/render.out"
    if compose config > "$out" 2> "$(tmp_dir)/render.err"; then
        ok "$MODE stack renders"
        # Nothing may publish a host port for the backend, worker, PostgreSQL or Redis.
        if awk '
            /^[a-z]/ { section = $1 }
            section == "services:" && /^  [A-Za-z0-9_-]+:$/ { svc = $1 }
            section == "services:" && /^    ports:/ && svc ~ /^(postgres|redis|backend|worker|upgrade|backup-folder):$/ { found = 1 }
            END { exit !found }' "$out"; then
            bad "backend, worker, postgres or redis publishes a host port"
        else ok "no host port for backend, worker, postgres or redis"; fi
    else
        bad "'compose config' failed:"
        sed 's/^/        /' "$(tmp_dir)/render.err" | head -n 15 >&2
    fi
}

check_helm() {
    say "Helm prerequisites"
    if command -v helm >/dev/null 2>&1; then ok "helm $(helm version --short 2>/dev/null | head -n 1)"; else bad "helm is not installed (https://helm.sh/docs/intro/install/)"; fi
    if command -v kubectl >/dev/null 2>&1; then
        ok "kubectl present"
        local ctx; ctx="$(kubectl config current-context 2>/dev/null || true)"
        if [[ -n "$ctx" ]]; then ok "kubectl context: $ctx"; else warn "no kubectl context: helm-template works, install/upgrade need a cluster"; fi
    else warn "kubectl is not installed (helm-install/upgrade talk to the cluster through your kubeconfig; kubectl is only used to show the context)"; fi
    if chart_is_oci; then ok "chart: $CHART_REF (fetched from the registry when used)"
    elif [[ -f "${CHART_REF:-$CHART_DIR}/Chart.yaml" ]]; then ok "chart: ${CHART_REF:-$CHART_DIR}"; else bad "chart not found: ${CHART_REF:-$CHART_DIR}"; fi
    local f
    for f in ${VALUES_FILES[@]+"${VALUES_FILES[@]}"}; do
        if [[ -f "$f" ]]; then ok "values file: $f"; else bad "values file not found: $f"; fi
    done
    if bash "$SCRIPT_DIR/release-tags.sh" ${RELEASE:+--release "$RELEASE"} --format json >/dev/null 2>"$(tmp_dir)/rel.err"; then ok "releases.yml: ${RELEASE:-latest} resolves to three tags"
    else bad "releases.yml: $(cat "$(tmp_dir)/rel.err")"; fi
}

cmd_check() {
    check_tools
    check_env
    check_tags
    check_project
    check_build
    check_render
    if [[ "$CHECK_HELM" == 1 ]]; then check_helm; fi
    echo >&2
    if [[ "$FAILURES" -gt 0 ]]; then
        printf '%s%d check(s) failed%s, %d warning(s).\n' "$C_RED" "$FAILURES" "$C_OFF" "$WARNINGS" >&2
        exit 1
    fi
    printf '%sAll checks passed%s (%d warning(s)).\n' "$C_GRN" "$C_OFF" "$WARNINGS" >&2
}

# A quick gate before commands that start things: the failures `check` would report.
preflight() {
    local before="$FAILURES"
    check_env
    check_project
    check_build
    [[ "$FAILURES" -eq "$before" ]] || die "fix the failures above first (scripts/portal.sh check shows everything)"
}

# ── Compose commands ─────────────────────────────────────────────────────────
portal_port() { local p; p="$(cfg PORTAL_PORT)"; printf '%s' "${p:-8080}"; }

wait_for_portal() {
    command -v curl >/dev/null 2>&1 || return 0
    local url i timeout="${PORTAL_WAIT_TIMEOUT:-600}"
    url="http://localhost:$(portal_port)/api/health"
    say "Waiting for $url (up to ${timeout}s)"
    for ((i = 0; i < timeout; i += 5)); do
        if curl -fsS --max-time 4 "$url" >/dev/null 2>&1; then return 0; fi
        sleep 5
    done
    return 1
}

cmd_up() {
    prepare_compose 1
    preflight
    if [[ "$BUILD" == 1 ]]; then say "Starting the $MODE stack with $ENGINE_SEL compose, building from source"
    else say "Starting the $MODE stack with $ENGINE_SEL compose"; fi
    local -a opts=(up -d)
    [[ "$BUILD" == 0 ]] || build_images
    if [[ "$ENGINE_SEL" == docker ]]; then opts+=(--remove-orphans --wait --wait-timeout "${PORTAL_WAIT_TIMEOUT:-600}"); fi
    compose "${opts[@]}"
    if [[ "$ENGINE_SEL" != docker ]]; then wait_for_portal || die "the portal did not answer in time: scripts/portal.sh logs backend"; fi
    local bind port; port="$(portal_port)"; bind="$(cfg PORTAL_BIND)"
    echo >&2
    ok "portal: http://localhost:$port${bind:+  (bound to $bind)}"
    echo "  first sign-in passwords are printed once in the backend log:" >&2
    echo "    scripts/portal.sh logs backend --no-follow | grep -A6 'GENERATED INITIAL CREDENTIALS'" >&2
}

cmd_down() {
    prepare_compose 1
    local -a opts=(down)
    [[ "$ENGINE_SEL" != docker ]] || opts+=(--remove-orphans)
    if [[ "$VOLUMES" == 1 ]]; then
        say "This DELETES the named volumes of the $MODE stack: the database, the portal data, the workspace."
        compose config --volumes 2>/dev/null | sed 's/^/    /' >&2 || true
        echo "  A host backup folder (PORTAL_BACKUP_DIR) and a mounted project (DBT_PROJECT_PATH) are not touched." >&2
        confirm "Type 'delete data' to continue:" "delete data"
        opts+=(--volumes)
    fi
    compose "${opts[@]}"
}

cmd_restart() { prepare_compose 1; compose restart ${POSITIONAL[@]+"${POSITIONAL[@]}"}; }

cmd_status() {
    prepare_compose 1
    compose ps
    if command -v curl >/dev/null 2>&1; then
        local port; port="$(portal_port)"
        say "Portal at http://localhost:$port"
        if curl -fsS --max-time 5 "http://localhost:$port/api/version"; then echo; else warn "no answer from /api/version"; fi
    fi
}

cmd_logs() {
    prepare_compose 1
    local -a opts=(logs --tail 200)
    [[ "$FOLLOW" == 0 ]] || opts+=(-f)
    compose "${opts[@]}" ${POSITIONAL[@]+"${POSITIONAL[@]}"}
}

cmd_pull() {
    prepare_compose 1
    if [[ "$BUILD" == 1 ]]; then
        say "Build mode: the application images are built, not pulled; pulling the data services only"
        if [[ "$MODE" == single ]]; then echo "  nothing to pull (single node has no data services)" >&2; return 0; fi
        compose pull postgres redis
        return 0
    fi
    compose pull ${POSITIONAL[@]+"${POSITIONAL[@]}"}
}

# One image at a time (backend, Cube, frontend): all three in parallel can exhaust a small
# Podman machine. The backend is built once; the worker and the one-off jobs reuse its image.
build_images() {
    local svc
    if [[ ${#POSITIONAL[@]} -gt 0 ]]; then
        for svc in "${POSITIONAL[@]}"; do compose build "$svc"; done
    else
        for svc in backend cube frontend; do compose build "$svc"; done
    fi
}

cmd_build() {
    BUILD=1
    prepare_compose 1
    preflight
    say "Building from the sibling repositories (the backend image is built once for the API and the worker)"
    build_images
}

cmd_clean() {
    prepare_compose 1
    say "Removing containers, networks and locally built images of the $MODE stack (data is kept)"
    local -a opts=(down --rmi local)
    [[ "$ENGINE_SEL" != docker ]] || opts+=(--remove-orphans)
    if [[ "$VOLUMES" == 1 ]]; then
        say "--volumes: this DELETES the named volumes too: the database, the portal data, the workspace."
        compose config --volumes 2>/dev/null | sed 's/^/    /' >&2 || true
        confirm "Type 'delete data' to continue:" "delete data"
        opts+=(--volumes)
    fi
    compose "${opts[@]}"
    if override_is_ours; then rm -f "$OVERRIDE_FILE"; echo "  removed the generated compose.override.yaml" >&2; fi
    echo "  kept: $ENV_FILE, the backup folder, and any mounted project" >&2
}

cmd_release() {
    bash "$SCRIPT_DIR/release-tags.sh" ${RELEASE:+--release "$RELEASE"} --format env
}

# ── Helm ─────────────────────────────────────────────────────────────────────
helm_bin() { command -v helm >/dev/null 2>&1 || die "helm is not installed (https://helm.sh/docs/intro/install/)"; }
HELM_ARGS=()
chart_is_oci() { [[ "$CHART_REF" == oci://* ]]; }

# CHART_ARGS: what `helm template|install|upgrade NAME` takes as the chart: a folder, or an OCI
# reference with its version (the release's name unless --chart-version: the chart is published
# under the release it belongs to). For a registry that needs a login, the token in PORTAL_TOKEN
# is given to `helm registry login` on stdin: never in an argument, never printed.
CHART_ARGS=()
prepare_chart() {
    CHART_ARGS=()
    if chart_is_oci; then
        local version="$CHART_VERSION" host token user
        if [[ -z "$version" ]]; then
            version="$(bash "$SCRIPT_DIR/release-tags.sh" ${RELEASE:+--release "$RELEASE"} --format env | sed -n 's/^PORTAL_RELEASE=//p')"
            [[ -n "$version" ]] || die "could not work out the chart version: pass --chart-version"
        fi
        token="${PORTAL_TOKEN:-${GITHUB_TOKEN:-}}"
        if [[ -n "$token" ]]; then
            host="${CHART_REF#oci://}"; host="${host%%/*}"
            user="$(registry_user "$token")"
            printf '%s' "$token" | helm registry login "$host" --username "$user" --password-stdin >/dev/null \
                || die "helm could not sign in to $host with the token"
        fi
        CHART_ARGS=("$CHART_REF" --version "$version")
    else
        local dir="${CHART_REF:-$CHART_DIR}"
        [[ -f "$dir/Chart.yaml" ]] || die "chart not found: $dir"
        CHART_ARGS=("$(native_path "$dir")")
    fi
}


# The chart's image tags come from releases.yml (default: latest) as the FIRST values
# file, so any values file or --set the user passes still wins.
build_helm_args() {
    helm_bin
    prepare_chart
    HELM_ARGS=()
    local tags f
    tags="$(tmp_dir)/release-tags.yaml"
    bash "$SCRIPT_DIR/release-tags.sh" ${RELEASE:+--release "$RELEASE"} --format helm-values > "$tags" || die "could not resolve the release tags"
    HELM_ARGS+=(-f "$(native_path "$tags")")
    if [[ "$PULL_SECRET" == 1 ]]; then
        # After the tags and before the user's files: a values file of yours can still replace it.
        printf 'imagePullSecrets:\n  - name: %s\n' "$PULL_SECRET_NAME" > "$(tmp_dir)/pull-secret.yaml"
        HELM_ARGS+=(-f "$(native_path "$(tmp_dir)/pull-secret.yaml")")
    fi
    for f in ${VALUES_FILES[@]+"${VALUES_FILES[@]}"}; do
        [[ -f "$f" ]] || die "values file not found: $f"
        HELM_ARGS+=(-f "$(native_path "$f")")
    done
    for f in ${HELM_SETS[@]+"${HELM_SETS[@]}"}; do HELM_ARGS+=(--set "$f"); done
}

PULL_SECRET_NAME=ghcr-pull

# The name GitHub's registry wants with a token: the token's owner. PORTAL_USER_NAME overrides.
registry_user() {  # registry_user TOKEN
    local login=""
    if [[ -n "${PORTAL_USER_NAME:-}" ]]; then printf '%s' "$PORTAL_USER_NAME"; return; fi
    if command -v curl >/dev/null 2>&1; then
        # The token goes to curl on stdin, not on its command line.
        login="$(printf 'header = "Authorization: Bearer %s"\n' "$1" | curl -fsS --max-time 15 -K - https://api.github.com/user 2>/dev/null \
            | sed -n 's/^ *"login": *"\([^"]*\)".*/\1/p' | head -n 1 || true)"
    fi
    printf '%s' "${login:-portal}"
}

# Creates (or updates) the namespace and the registry pull Secret from PORTAL_TOKEN, so a private
# registry's images can be pulled. The Secret travels to kubectl on stdin: never in an argument list, never printed.
ensure_pull_secret() {
    [[ "$PULL_SECRET" == 1 ]] || return 0
    local token user host auth json
    token="${PORTAL_TOKEN:-${GITHUB_TOKEN:-}}"
    [[ -n "$token" ]] || die "--pull-secret needs the access token in the environment: PORTAL_TOKEN=<token> $0 $COMMAND ..."
    command -v kubectl >/dev/null 2>&1 || die "--pull-secret needs kubectl"
    host="${PORTAL_REGISTRY_HOST:-ghcr.io}"
    user="$(registry_user "$token")"
    auth="$(printf '%s:%s' "$user" "$token" | base64 | tr -d '\n')"
    json="{\"auths\":{\"$host\":{\"username\":\"$user\",\"password\":\"$token\",\"auth\":\"$auth\"}}}"
    kubectl create namespace "$HELM_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null || die "could not create the namespace $HELM_NAMESPACE"
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: kubernetes.io/dockerconfigjson\nstringData:\n  .dockerconfigjson: %s\n' \
        "$PULL_SECRET_NAME" "$HELM_NAMESPACE" "$(yaml_str "$json")" | kubectl apply -f - >/dev/null || die "could not create the pull Secret"
    echo "  registry pull Secret $PULL_SECRET_NAME is in place in namespace $HELM_NAMESPACE (host $host, user $user)" >&2
}

helm_target_note() {
    local ctx=""
    command -v kubectl >/dev/null 2>&1 && ctx="$(kubectl config current-context 2>/dev/null || true)"
    printf '  release %s, namespace %s, cluster context %s\n' "$HELM_NAME" "$HELM_NAMESPACE" "${ctx:-<none: using the default kubeconfig>}" >&2
}

cmd_helm_template() {
    if [[ ${#VALUES_FILES[@]} -eq 0 ]] && chart_is_oci; then
        die "helm-template with an oci:// chart needs --values (the chart's own values-dev.yaml is not in your checkout)"
    elif [[ ${#VALUES_FILES[@]} -eq 0 ]]; then
        VALUES_FILES=("$CHART_DIR/values-dev.yaml")
        echo "  no --values given: rendering with values-dev.yaml" >&2
    fi
    build_helm_args
    helm template "$HELM_NAME" "${CHART_ARGS[@]}" --namespace "$HELM_NAMESPACE" "${HELM_ARGS[@]}"
}

need_values() {
    [[ ${#VALUES_FILES[@]} -gt 0 ]] || die "$COMMAND needs --values (for example deploy/helm/dbt-portal/values-dev.yaml, or your own file): nothing is assumed for a cluster"
}

cmd_helm_install() {
    need_values
    build_helm_args
    say "helm install"
    helm_target_note
    confirm "Install into this cluster? Type 'yes':" "yes"
    ensure_pull_secret
    helm install "$HELM_NAME" "${CHART_ARGS[@]}" --namespace "$HELM_NAMESPACE" --create-namespace \
        --wait --timeout "${PORTAL_HELM_TIMEOUT:-10m}" "${HELM_ARGS[@]}"
}

cmd_helm_upgrade() {
    need_values
    build_helm_args
    say "helm upgrade"
    helm_target_note
    confirm "Upgrade this release? Type 'yes':" "yes"
    ensure_pull_secret
    helm upgrade "$HELM_NAME" "${CHART_ARGS[@]}" --namespace "$HELM_NAMESPACE" \
        --wait --timeout "${PORTAL_HELM_TIMEOUT:-10m}" "${HELM_ARGS[@]}"
}

cmd_helm_status() { helm_bin; helm status "$HELM_NAME" --namespace "$HELM_NAMESPACE"; }

cmd_helm_rollback() {
    helm_bin
    say "helm rollback"
    helm_target_note
    helm history "$HELM_NAME" --namespace "$HELM_NAMESPACE" | tail -n 8 >&2
    confirm "Roll back? Type 'yes':" "yes"
    helm rollback "$HELM_NAME" ${POSITIONAL[@]+"${POSITIONAL[@]}"} --namespace "$HELM_NAMESPACE" --wait --timeout "${PORTAL_HELM_TIMEOUT:-10m}"
}

cmd_helm_uninstall() {
    helm_bin
    say "helm uninstall"
    helm_target_note
    echo "  The persistent volume claims (workspace, data, backups, bundled PostgreSQL) are kept unless --volumes is given." >&2
    confirm "Uninstall? Type 'yes':" "yes"
    helm uninstall "$HELM_NAME" --namespace "$HELM_NAMESPACE"
    if [[ "$VOLUMES" == 1 ]]; then
        command -v kubectl >/dev/null 2>&1 || die "kubectl is needed to delete the claims"
        say "--volumes: this DELETES every persistent volume claim of the release (the data is gone for good)"
        kubectl get pvc --namespace "$HELM_NAMESPACE" -l "app.kubernetes.io/instance=$HELM_NAME" >&2 || true
        confirm "Type 'delete data' to continue:" "delete data"
        kubectl delete pvc --namespace "$HELM_NAMESPACE" -l "app.kubernetes.io/instance=$HELM_NAME"
    fi
}

# ── dispatch ─────────────────────────────────────────────────────────────────
case "$COMMAND" in
    init) cmd_init ;;
    check) cmd_check ;;
    build) cmd_build ;;
    pull) cmd_pull ;;
    up) cmd_up ;;
    down) cmd_down ;;
    restart) cmd_restart ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    clean) cmd_clean ;;
    release) cmd_release ;;
    helm-template) cmd_helm_template ;;
    helm-install) cmd_helm_install ;;
    helm-upgrade) cmd_helm_upgrade ;;
    helm-status) cmd_helm_status ;;
    helm-rollback) cmd_helm_rollback ;;
    helm-uninstall) cmd_helm_uninstall ;;
    *) usage_error "unknown command '$COMMAND'" ;;
esac
