#!/usr/bin/env bash
# Bring what repeats a release of releases.yml into line with it: the image tags in .env.example and
# the chart's appVersion. releases.yml is the source; it is read, never changed.
#
#   scripts/sync-release.sh                   the latest release
#   scripts/sync-release.sh 2026.10.19        a named release
#   scripts/sync-release.sh --check           change nothing; exit 1 and list what is out of date
#
# Options:
#   --release NAME   the release (same as the positional argument; default: latest)
#   --root DIR       another checkout of this repo (default: the one this script is in)
#   --check          only report
#
# Prints one line per file it changed (or, with --check, per file that is out of date). scripts/add-release.sh
# runs it after adding an entry; scripts/validate.sh releases fails until it has been run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
release=""
check=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) [[ $# -ge 2 ]] || { echo "sync-release: --release needs a name" >&2; exit 2; }; release="$2"; shift 2 ;;
        --root) [[ $# -ge 2 ]] || { echo "sync-release: --root needs a directory" >&2; exit 2; }; root="$(cd "$2" && pwd)"; shift 2 ;;
        --check) check=1; shift ;;
        -h | --help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "sync-release: unknown option $1" >&2; exit 2 ;;
        *) [[ -z "$release" ]] || { echo "sync-release: more than one release given" >&2; exit 2; }; release="$1"; shift ;;
    esac
done


# Keep a file's line endings (a Windows checkout is CRLF): awk and sed may change them.
had_cr() { [[ "$(head -c 20000 "$1" | tr -cd '\r' | wc -c)" -gt 0 ]]; }
set_eol() {  # set_eol FILE 1|0 : 1 = CRLF
    local t; t="$(mktemp)"
    tr -d '\r' < "$1" > "$t"
    if [[ "$2" == 1 ]]; then sed 's/$/\r/' "$t" > "$1"; else cat "$t" > "$1"; fi
    rm -f "$t"
}
tags_args=(--releases-file "$root/releases.yml")
[[ -z "$release" ]] || tags_args+=(--release "$release")
env_out="$(bash "$here/release-tags.sh" "${tags_args[@]}" --format env)" || exit 1
want() { printf '%s\n' "$env_out" | sed -n "s/^$1=//p"; }
release="$(want PORTAL_RELEASE)"

# Every file this script edits must exist before it edits any of them, so a failure leaves nothing
# half-synced (and a checkout that is behind the branch carrying the Helm chart is named as such).
env_file="$root/.env.example"
chart="$root/deploy/helm/dbt-portal/Chart.yaml"
for f in "$env_file" "$chart"; do
    [[ -f "$f" ]] || { echo "sync-release: $f not found (is this checkout behind the branch that carries the Helm chart?)" >&2; exit 1; }
done

stale=()

# .env.example: BACKEND_TAG, FRONTEND_TAG, CUBE_TAG.
env_stale=0
for key in BACKEND FRONTEND CUBE; do
    current="$(sed -n "s/^${key}_TAG=//p" "$env_file" | head -n 1 | tr -d '\r')"
    [[ "$current" == "$(want "${key}_TAG")" ]] || env_stale=1
done
if [[ "$env_stale" == 1 ]]; then
    stale+=(".env.example")
    if [[ "$check" == 0 ]]; then
        cr=0; had_cr "$env_file" && cr=1
        bash "$here/release-tags.sh" --releases-file "$root/releases.yml" --release "$release" --write-env "$env_file" 2>/dev/null
        set_eol "$env_file" "$cr"
    fi
fi

# Chart.yaml: appVersion is the portal release the chart was last aligned with.
app="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$chart" | head -n 1 | tr -d '\r')"
if [[ "$app" != "$release" ]]; then
    stale+=("deploy/helm/dbt-portal/Chart.yaml")
    if [[ "$check" == 0 ]]; then
        cr=0; had_cr "$chart" && cr=1
        sed -i.bak "s/^appVersion: .*/appVersion: \"$release\"/" "$chart" && rm -f "$chart.bak"
        set_eol "$chart" "$cr"
    fi
fi

if [[ ${#stale[@]} -eq 0 ]]; then
    echo "sync-release: everything matches release $release"
    exit 0
fi
for f in "${stale[@]}"; do
    if [[ "$check" == 1 ]]; then echo "out of date: $f (release $release)"; else echo "updated: $f (release $release)"; fi
done
[[ "$check" == 0 ]] || exit 1
