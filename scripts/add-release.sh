#!/usr/bin/env bash
# Add a portal release to releases.yml, make it the latest, and bring what repeats it into line.
#
#   scripts/add-release.sh --name 2026.11.0 --from-images --notes "What changed"
#   scripts/add-release.sh --name 2026.11.0 --backend prod-<sha> --frontend prod-<sha> --cube prod-<sha>
#
#   --name NAME        the release, YEAR.MONTH.N (e.g. 2026.11.0); must not exist yet
#   --backend TAG      image tags to pin; each one given wins over --from-images
#   --frontend TAG
#   --cube TAG
#   --from-images [FILE]
#                      fill the tags that are not given from the newest prod images the component
#                      pipelines recorded (images/prod.yaml, or FILE)
#   --notes TEXT       what changed, which components must be upgraded together (optional)
#   --root DIR         another checkout of this repo (default: the one this script is in)
#
# The entry goes at the top of `releases:`, `latest:` points at it, and scripts/sync-release.sh updates
# .env.example and the chart's appVersion. Nothing else in releases.yml is touched; if anything fails,
# releases.yml is put back as it was. The combination is NOT tested here: open the change as a pull
# request, whose e2e-smoke run starts the stack from exactly these tags.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
name="" notes="" images="" from_images=0
declare -a tags=("" "" "")   # backend frontend cube
die() { echo "add-release: $*" >&2; exit 1; }

# Keep a file's line endings (a Windows checkout is CRLF): awk and sed may change them.
had_cr() { [[ "$(head -c 20000 "$1" | tr -cd '\r' | wc -c)" -gt 0 ]]; }
set_eol() {  # set_eol FILE 1|0 : 1 = CRLF
    local t; t="$(mktemp)"
    tr -d '\r' < "$1" > "$t"
    if [[ "$2" == 1 ]]; then sed 's/$/\r/' "$t" > "$1"; else cat "$t" > "$1"; fi
    rm -f "$t"
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) [[ $# -ge 2 ]] || die "--name needs a value"; name="$2"; shift 2 ;;
        --backend) [[ $# -ge 2 ]] || die "--backend needs a tag"; tags[0]="$2"; shift 2 ;;
        --frontend) [[ $# -ge 2 ]] || die "--frontend needs a tag"; tags[1]="$2"; shift 2 ;;
        --cube) [[ $# -ge 2 ]] || die "--cube needs a tag"; tags[2]="$2"; shift 2 ;;
        --notes) [[ $# -ge 2 ]] || die "--notes needs text"; notes="$2"; shift 2 ;;
        --from-images)
            from_images=1; shift
            if [[ $# -gt 0 && "$1" != -* ]]; then images="$1"; shift; fi ;;
        --root) [[ $# -ge 2 ]] || die "--root needs a directory"; root="$(cd "$2" && pwd)"; shift 2 ;;
        -h | --help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

file="$root/releases.yml"
[[ -f "$file" ]] || die "$file not found"
[[ "$name" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,3}$ ]] || die "--name must look like 2026.11.0 (year.month.number)"
if bash "$here/release-tags.sh" --releases-file "$file" --list | sed 's/ (latest)$//' | grep -Fxq -- "$name"; then die "release $name already exists"; fi

# Tags not given come from the recorded prod images: `component:` blocks with a `tag:` line (scripts/record_image.py's format).
if [[ "$from_images" == 1 ]]; then
    images="${images:-$root/images/prod.yaml}"
    [[ -f "$images" ]] || die "$images not found"
    i=0
    for c in backend frontend cube; do
        if [[ -z "${tags[$i]}" ]]; then
            tags[$i]="$(awk -v c="$c" '/^  [a-z]+:$/ { cur = $1; sub(/:$/, "", cur) } cur == c && /^    tag:/ { print $2; exit }' "$images")"
            [[ -n "${tags[$i]}" ]] || die "no $c image is recorded in $images: pass --$c <tag>"
        fi
        i=$((i + 1))
    done
fi
tag_re='^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'
i=0
for c in backend frontend cube; do
    [[ -n "${tags[$i]}" ]] || die "no $c tag: pass --$c <tag> or --from-images"
    [[ "${tags[$i]}" =~ $tag_re ]] || die "the $c tag is not a valid image tag"
    [[ "${tags[$i]}" != latest ]] || die "the $c tag is 'latest', which is not a pinned release"
    i=$((i + 1))
done

# The entry.
entry="  \"$name\":
    backend: \"${tags[0]}\"
    frontend: \"${tags[1]}\"
    cube: \"${tags[2]}\""
if [[ -n "$notes" ]]; then
    folded="$(printf '%s' "$notes" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//' | fold -s -w 74 | sed 's/ *$//; s/^/      /')"
    entry="$entry
    notes: >-
$folded"
fi

backup="$(mktemp)"
trap 'rm -f "$backup" "$backup.new"' EXIT
cp "$file" "$backup"
restore() { cat "$backup" > "$file"; }   # byte for byte: the copy is of the original, line endings included

# Insert right after `releases:` (newest first) and move `latest:`.
ENTRY="$entry" NAME="$name" awk '
    /^latest:/ && !done_latest { print "latest: \"" ENVIRON["NAME"] "\""; done_latest = 1; next }
    { print }
    /^releases:[ \t]*$/ && !done_entry { print ENVIRON["ENTRY"]; done_entry = 1 }
    END { if (!done_latest || !done_entry) exit 3 }' "$backup" > "$backup.new" || { die "releases.yml has no 'latest:' or 'releases:' line to edit"; }
cr=0; had_cr "$backup" && cr=1
cat "$backup.new" > "$file"
set_eol "$file" "$cr"

# It must read back as exactly what was asked for.
if ! got="$(bash "$here/release-tags.sh" --releases-file "$file" --release "$name" --format env)" \
    || [[ "$(printf '%s\n' "$got" | sed -n 's/^BACKEND_TAG=//p')" != "${tags[0]}" ]] \
    || [[ "$(printf '%s\n' "$got" | sed -n 's/^FRONTEND_TAG=//p')" != "${tags[1]}" ]] \
    || [[ "$(printf '%s\n' "$got" | sed -n 's/^CUBE_TAG=//p')" != "${tags[2]}" ]] \
    || [[ "$(bash "$here/release-tags.sh" --releases-file "$file" --format env | sed -n 's/^PORTAL_RELEASE=//p')" != "$name" ]]; then
    restore
    die "the new entry did not read back correctly: releases.yml was put back as it was"
fi

if ! bash "$here/sync-release.sh" --root "$root" --release "$name"; then
    restore
    die "sync-release failed: releases.yml was put back as it was"
fi
echo "add-release: release $name added (backend ${tags[0]}, frontend ${tags[1]}, cube ${tags[2]}) and is now the latest"
