#!/usr/bin/env bash
# Resolve a portal release from releases.yml into image tags.
#
#   scripts/release-tags.sh                       latest release, as KEY=VALUE lines
#   scripts/release-tags.sh 2026.10.19            a named release
#   scripts/release-tags.sh --list                every release name, newest first, latest marked
#   scripts/release-tags.sh --format helm-set     --set arguments for helm
#   scripts/release-tags.sh --format helm-values  a values file (YAML) with the three tags
#   scripts/release-tags.sh --write-env .env      set the three *_TAG keys in an env file
#
# Formats (--format): env (default), helm-set, helm-values, json.
# Options:
#   --release NAME     the release (default: latest; same as the positional argument)
#   --releases-file F  another releases.yml (default: the one next to this script's repo root)
#   --write-env FILE   replace or append BACKEND_TAG, FRONTEND_TAG and CUBE_TAG in FILE
#
# Reads releases.yml only; never changes it. Prints tags, never secrets. Fails
# (non-zero, message on stderr) if the release or one of its three tags is
# missing, or if a tag is not a valid image tag.
#
# Schema it relies on (see the comment at the top of releases.yml):
#   latest: "<name>"
#   releases:
#     "<name>":
#       backend: "<tag>"
#       frontend: "<tag>"
#       cube: "<tag>"
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# In the repo this script is scripts/release-tags.sh; in the client kit it sits next to releases.yml.
if [[ -f "$here/releases.yml" ]]; then root="$here"; else root="$(cd "$here/.." && pwd)"; fi

die() { printf 'release-tags: %s\n' "$*" >&2; exit 1; }

release=""
file="$root/releases.yml"
format="env"
list=""
write_env=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) [[ $# -ge 2 ]] || die "--release needs a value"; release="$2"; shift 2 ;;
        --releases-file) [[ $# -ge 2 ]] || die "--releases-file needs a value"; file="$2"; shift 2 ;;
        --format) [[ $# -ge 2 ]] || die "--format needs a value"; format="$2"; shift 2 ;;
        --write-env) [[ $# -ge 2 ]] || die "--write-env needs a file"; write_env="$2"; shift 2 ;;
        --list) list=1; shift ;;
        -h | --help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) [[ -z "$release" ]] || die "more than one release given"; release="$1"; shift ;;
    esac
done

[[ -f "$file" ]] || die "releases file not found: $file"
case "$format" in env | helm-set | helm-values | json) ;; *) die "unknown format '$format' (env, helm-set, helm-values, json)" ;; esac

# The release named by `latest:`.
latest_name() {
    awk '
        /^latest:/ {
            v = $0; sub(/^latest:[ \t]*/, "", v); sub(/[ \t]*(#.*)?$/, "", v)
            gsub(/^["\047]|["\047]$/, "", v); print v; exit
        }' "$file"
}

# Release names in file order (the file lists the newest first).
release_names() {
    awk '
        /^releases:[ \t]*$/ { in_releases = 1; next }
        in_releases && /^[^ \t#]/ { in_releases = 0 }
        in_releases && /^  ["\047]?[A-Za-z0-9._-]+["\047]?:[ \t]*(#.*)?$/ {
            v = $0; sub(/^  /, "", v); sub(/:[ \t]*(#.*)?$/, "", v); gsub(/["\047]/, "", v); print v
        }' "$file"
}

# component_tag RELEASE COMPONENT: the 4-space-indented "component:" key inside
# that release's block (the deeper-indented notes text is never matched).
component_tag() {
    awk -v rel="$1" -v comp="$2" '
        /^releases:[ \t]*$/ { in_releases = 1; next }
        in_releases && /^[^ \t#]/ { in_releases = 0 }
        !in_releases { next }
        /^  ["\047]?[A-Za-z0-9._-]+["\047]?:[ \t]*(#.*)?$/ {
            n = $0; sub(/^  /, "", n); sub(/:[ \t]*(#.*)?$/, "", n); gsub(/["\047]/, "", n)
            in_block = (n == rel); next
        }
        in_block && $0 ~ "^    " comp ":[ \t]*" {
            v = $0; sub("^    " comp ":[ \t]*", "", v)
            if (v ~ /^["\047]/) { q = substr(v, 1, 1); v = substr(v, 2); sub(q ".*$", "", v) }
            else { sub(/[ \t]*(#.*)?$/, "", v) }
            print v; exit
        }' "$file"
}

if [[ -n "$list" ]]; then
    latest="$(latest_name)"
    while IFS= read -r name; do
        if [[ "$name" == "$latest" ]]; then printf '%s (latest)\n' "$name"; else printf '%s\n' "$name"; fi
    done < <(release_names)
    exit 0
fi

if [[ -z "$release" || "$release" == latest ]]; then
    release="$(latest_name)"
    [[ -n "$release" ]] || die "$file has no 'latest:' entry; name a release explicitly"
fi

release_names | grep -Fxq -- "$release" || die "release '$release' is not in $file (see: $0 --list)"

tag_re='^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$'
backend="$(component_tag "$release" backend)"
frontend="$(component_tag "$release" frontend)"
cube="$(component_tag "$release" cube)"
for pair in "backend:$backend" "frontend:$frontend" "cube:$cube"; do
    name="${pair%%:*}"; value="${pair#*:}"
    [[ -n "$value" ]] || die "release '$release' has no '$name' tag in $file"
    [[ "$value" =~ $tag_re ]] || die "release '$release': '$name' tag is not a valid image tag"
    [[ "$value" != latest ]] || die "release '$release': '$name' is 'latest', which is not a pinned tag"
done

if [[ -n "$write_env" ]]; then
    # Replace each key in place (or append it), keep every other line and the file mode.
    touch "$write_env" || die "cannot write $write_env"
    tmp="$(mktemp "${write_env}.XXXXXX")" || die "cannot create a temporary file next to $write_env"
    trap 'rm -f "$tmp"' EXIT
    awk -v b="$backend" -v f="$frontend" -v c="$cube" '
        BEGIN { want["BACKEND_TAG"] = b; want["FRONTEND_TAG"] = f; want["CUBE_TAG"] = c }
        {
            line = $0; key = line; sub(/=.*/, "", key)
            if (key in want) { print key "=" want[key]; seen[key] = 1 } else { print line }
        }
        END { for (k in want) if (!(k in seen)) print k "=" want[k] }' "$write_env" > "$tmp"
    cat "$tmp" > "$write_env"   # keeps the target's permissions (a 600 .env stays 600)
    printf 'release-tags: %s: backend %s, frontend %s, cube %s\n' "$release" "$backend" "$frontend" "$cube" >&2
    exit 0
fi

case "$format" in
    env)
        printf 'PORTAL_RELEASE=%s\nBACKEND_TAG=%s\nFRONTEND_TAG=%s\nCUBE_TAG=%s\n' "$release" "$backend" "$frontend" "$cube"
        ;;
    helm-set)
        printf -- '--set backend.image.tag=%s --set frontend.image.tag=%s --set cube.image.tag=%s\n' "$backend" "$frontend" "$cube"
        ;;
    helm-values)
        printf '# Image tags of portal release %s, from releases.yml.\nbackend:\n  image:\n    tag: "%s"\nfrontend:\n  image:\n    tag: "%s"\ncube:\n  image:\n    tag: "%s"\n' \
            "$release" "$backend" "$frontend" "$cube"
        ;;
    json)
        printf '{"release":"%s","backend":"%s","frontend":"%s","cube":"%s"}\n' "$release" "$backend" "$frontend" "$cube"
        ;;
esac
