#!/usr/bin/env bash
# One-line install: downloads the client kit of a portal release and runs its
# setup.sh. macOS, Linux, WSL and Linux VMs.
#
#   curl -fsSL https://raw.githubusercontent.com/omaryehia015/capgemini-dbt-portal-deploy/main/deploy/client/install.sh \
#     | PORTAL_TOKEN=<token you were sent> bash
#
# Add `-s -- /path/to/my-dbt-project` after `bash` to use a folder on this machine;
# without one you connect a Git repository in the portal.
#
# Anything after `--` goes to setup.sh (--port, --answers, --workers ...).
# Environment:
#   PORTAL_RELEASE   release to install (default: latest)
#   PORTAL_DIR       where to unpack the kit (default: ~/dbt-portal)
#   PORTAL_TOKEN     the access token you were sent (signs in to the private images)
#   GITHUB_TOKEN     same as PORTAL_TOKEN (older name)
set -euo pipefail

REPO="omaryehia015/capgemini-dbt-portal-deploy"
RELEASE="${PORTAL_RELEASE:-latest}"
DIR="${PORTAL_DIR:-$HOME/dbt-portal}"

fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
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
if [[ -t 0 ]] || [[ ! -r /dev/tty ]]; then exec ./setup.sh "$@"; else exec ./setup.sh "$@" < /dev/tty; fi
