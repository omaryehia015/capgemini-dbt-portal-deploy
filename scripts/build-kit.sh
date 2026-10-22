#!/usr/bin/env bash
# Assemble the client kit of a portal release into a folder (the client-kit workflow zips it;
# scripts/validate.sh builds one to check it). Everything a client needs to run the portal, and
# nothing else: no source, no build overlay, so the default everywhere is to PULL the images.
#
#   scripts/build-kit.sh <release> [<out dir>]      default out dir: .
#
# Creates <out dir>/dbt-portal-client-kit-<release>/ and prints its path. The release must be in
# releases.yml (the file is read, never changed). In the kit:
#   compose.yaml compose.single.yaml .env.example releases.yml postgres/upgrade.sh
#   setup.sh setup.ps1 manage.sh manage.ps1 lib.sh lib.ps1 install.sh install.ps1 portal.answers.example README.md
#   portal.sh release-tags.sh                       Helm commands and release tags (Kubernetes)
#   deploy/helm/dbt-portal/                         the Helm chart of this release (no CI value sets)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
release="${1:-}"
out="${2:-.}"
[[ -n "$release" ]] || { echo "usage: build-kit.sh <release> [<out dir>]" >&2; exit 2; }

bash "$here/release-tags.sh" --release "$release" --format env >/dev/null || exit 1   # fails if the release or a tag is missing
kit="$out/dbt-portal-client-kit-$release"
[[ ! -e "$kit" ]] || { echo "build-kit: $kit already exists" >&2; exit 1; }

mkdir -p "$kit/postgres" "$kit/deploy/helm"
cp "$root/compose.yaml" "$root/compose.single.yaml" "$root/.env.example" "$root/releases.yml" "$kit/"
cp "$root/postgres/upgrade.sh" "$kit/postgres/"
for f in setup.sh setup.ps1 manage.sh manage.ps1 lib.sh lib.ps1 install.sh install.ps1 portal.answers.example README.md; do
    cp "$root/deploy/client/$f" "$kit/"
done
cp "$root/scripts/portal.sh" "$root/scripts/release-tags.sh" "$kit/"
cp -R "$root/deploy/helm/dbt-portal" "$kit/deploy/helm/dbt-portal"
rm -rf "$kit/deploy/helm/dbt-portal/ci"
chmod +x "$kit"/*.sh "$kit/postgres/upgrade.sh"

# The kit's .env.example starts on this release's images, and its chart is labelled with the release.
bash "$here/release-tags.sh" --release "$release" --write-env "$kit/.env.example" >/dev/null
sed -i.bak "s/^appVersion: .*/appVersion: \"$release\"/" "$kit/deploy/helm/dbt-portal/Chart.yaml" && rm -f "$kit/deploy/helm/dbt-portal/Chart.yaml.bak"

echo "$kit"
