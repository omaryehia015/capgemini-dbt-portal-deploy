#!/usr/bin/env bash
# One-line install: downloads the client kit of a portal release and runs the portal from
# it. macOS, Linux, WSL and Linux VMs (Windows: install.ps1). The images are PULLED from the
# registry; nothing is built.
#
#   curl -fsSL https://raw.githubusercontent.com/omaryehia015/capgemini-dbt-portal-deploy/main/deploy/client/install.sh \
#     | PORTAL_TOKEN=<token you were sent> bash
#
# Where to run it (PORTAL_MODE, or `--mode <m>` as the first argument after `bash -s --`):
#   local        (default) this computer, Docker or Podman, Compose. Opens the portal.
#   server       a Linux server, Docker or Podman Compose, started now; no browser.
#   service      a Linux server: the same, run as a systemd service that starts at boot
#                (root; rootless Podman as a user service). Docker needs root.
#   kubernetes   a Kubernetes cluster, with the Helm chart of the kit (needs helm and kubectl
#                pointed at the cluster). Without --values it is a TRIAL install (bundled
#                PostgreSQL and Redis); production: your own values and Secret, see the kit's README.
#
# Add `-s -- /path/to/my-dbt-project` after `bash` to use a folder on this machine;
# without one you connect a Git repository in the portal.
#
# Anything after `--` goes to setup.sh (--port, --answers, --workers ...); in kubernetes mode,
# to `portal.sh helm-install` (--values, --namespace, --set ...).
# Environment:
#   PORTAL_MODE      local | server | service | kubernetes (default: local)
#   PORTAL_RELEASE   release to install (default: latest)
#   PORTAL_DIR       where to unpack the kit (default: ~/dbt-portal; a server: /opt/dbt-portal)
#   PORTAL_TOKEN     the access token you were sent (signs in to the private images)
#   GITHUB_TOKEN     same as PORTAL_TOKEN (older name)
set -euo pipefail

REPO="omaryehia015/capgemini-dbt-portal-deploy"
RELEASE="${PORTAL_RELEASE:-latest}"
DIR="${PORTAL_DIR:-$HOME/dbt-portal}"

fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

MODE="${PORTAL_MODE:-local}"
if [[ "${1:-}" == --mode ]]; then [[ $# -ge 2 ]] || fail "--mode needs local, server, service or kubernetes."; MODE="$2"; shift 2; fi
case "$MODE" in
    local | server | service | kubernetes) ;;
    *) fail "Unknown mode '$MODE': use local, server, service or kubernetes." ;;
esac
if [[ "$MODE" != local && "$MODE" != kubernetes && "$(uname -s)" != Linux ]]; then
    fail "Mode '$MODE' is for Linux servers. On this computer use the default (local) mode."
fi
# A server install run as root lives in /opt, not in root's home.
if [[ -z "${PORTAL_DIR:-}" && ( "$MODE" == server || "$MODE" == service ) && "$EUID" -eq 0 ]]; then DIR=/opt/dbt-portal; fi
# Mode kubernetes needs no container engine, but helm and kubectl, before anything is downloaded.
if [[ "$MODE" == kubernetes ]]; then
    command -v helm >/dev/null 2>&1 || fail "helm is required (https://helm.sh/docs/intro/install/), pointed at your cluster."
    command -v kubectl >/dev/null 2>&1 || fail "kubectl is required, pointed at your cluster."
fi
command -v curl >/dev/null 2>&1 || fail "curl is required."
command -v unzip >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || fail "unzip (or python3) is required."

export PORTAL_TOKEN="${PORTAL_TOKEN:-${GITHUB_TOKEN:-}}"
auth=()
[[ -n "$PORTAL_TOKEN" ]] && auth=(-H "Authorization: Bearer $PORTAL_TOKEN")

if [[ "$RELEASE" == latest ]]; then
    RELEASE="$(curl -fsSL "${auth[@]+"${auth[@]}"}" "https://raw.githubusercontent.com/$REPO/main/releases.yml" \
        | sed -n 's/^latest: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p')" \
        || fail "Could not read releases.yml (set PORTAL_TOKEN if the repository is private)."
fi
[[ -n "$RELEASE" ]] || fail "Could not work out the latest release."

kit="dbt-portal-client-kit-$RELEASE"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
say "Downloading $kit"
if [[ -n "$PORTAL_TOKEN" ]]; then
    # A private repository's assets come through the API.
    asset="$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/$REPO/releases/tags/portal-$RELEASE" \
        | grep -o "\"url\": *\"[^\"]*/releases/assets/[0-9]*\"" | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
    [[ -n "$asset" ]] || fail "Release portal-$RELEASE has no client kit."
    curl -fsSL "${auth[@]}" -H "Accept: application/octet-stream" -o "$tmp/kit.zip" "$asset"
else
    curl -fsSL -o "$tmp/kit.zip" "https://github.com/$REPO/releases/download/portal-$RELEASE/$kit.zip" \
        || fail "Download failed. For a private repository set PORTAL_TOKEN."
fi

if command -v unzip >/dev/null 2>&1; then unzip -q "$tmp/kit.zip" -d "$tmp"
else python3 -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$tmp/kit.zip" "$tmp"; fi

mkdir -p "$DIR"
# An existing install keeps its .env (secrets, settings) and override file.
cp -R "$tmp/$kit/." "$DIR/"
chmod +x "$DIR"/*.sh
say "Kit unpacked in $DIR"

cd "$DIR"
# Piped into bash, stdin is the script itself: questions read from the terminal.
run() { if [[ -t 0 ]] || [[ ! -r /dev/tty ]]; then "$@"; else "$@" < /dev/tty; fi; }

case "$MODE" in
    local) run ./setup.sh "$@" ;;
    server) run ./setup.sh --no-browser "$@" ;;
    service)
        run ./setup.sh --no-browser "$@"
        say "Installing the systemd service"
        # Root: a system service (Docker, or rootful Podman). Not root: a user service, which is rootless Podman only.
        if [[ "$EUID" -eq 0 ]]; then service_args=(); else service_args=(--user); fi
        ./manage.sh service install ${service_args[@]+"${service_args[@]}"} \
            || fail "The portal is running, but the service was not installed. As root: sudo $DIR/manage.sh service install"
        ;;
    kubernetes)
        kube_args=(--release "$RELEASE")
        [[ -z "$PORTAL_TOKEN" ]] || kube_args+=(--pull-secret)
        have_values=""
        for arg in "$@"; do [[ "$arg" == --values || "$arg" == -f ]] && have_values=1; done
        if [[ -z "$have_values" ]]; then
            kube_args+=(--values deploy/helm/dbt-portal/values-dev.yaml)
            say "TRIAL install: bundled PostgreSQL and Redis, one disk each. For production pass your own --values (see README.md, 'Kubernetes')."
        fi
        # Run again, it upgrades: the chart in this (newer) kit and its tags replace the installed ones.
        kube_name=dbt-portal; kube_ns=dbt-portal; prev=""
        for arg in "$@"; do
            case "$prev" in --name) kube_name="$arg" ;; --namespace | -n) kube_ns="$arg" ;; esac
            prev="$arg"
        done
        if helm status "$kube_name" --namespace "$kube_ns" >/dev/null 2>&1; then helm_cmd=helm-upgrade; say "Release $kube_name exists in $kube_ns: upgrading it to $RELEASE"
        else helm_cmd=helm-install; fi
        run ./portal.sh "$helm_cmd" "${kube_args[@]}" "$@"
        printf '\nOpen it:  kubectl -n dbt-portal port-forward svc/dbt-portal-frontend 8080:8080   then http://localhost:8080\n'
        printf 'Sign in:  kubectl -n dbt-portal logs deploy/dbt-portal-backend | grep -A6 "GENERATED INITIAL CREDENTIALS"\n'
        ;;
esac
