#!/usr/bin/env bash
# Validate the deployment assets of this repo: run locally, and by CI (.github/workflows/validate.yml).
#
#   scripts/validate.sh [--strict] [group...]
#
# Groups (default: all)
#   yaml      every YAML and JSON file parses (Helm templates are Go templates and are rendered instead)
#   shell     bash -n and ShellCheck on every shell script
#   compose   full, single, build and single-build stacks render and pass the assertions
#             (docker compose; podman compose when installed); scripts/portal.sh init and check
#   helm      helm lint, helm template for dev/test/prod and the CI value sets, the assertions,
#             the validation guards, kubeconform
#   releases  releases.yml is consistent with .env.example, the chart and the image names
#   secrets   no secret file is tracked, the right files are ignored, Gitleaks
#   stale     nothing refers to the removed Kustomize install
#   images    the image records (images/<env>.yaml) follow the pipelines' convention; record_image.py
#             writes only what is valid and is idempotent
#   kit       the client kit (what a client downloads): contents, no build overlay, the systemd unit,
#             the Kubernetes pull-secret flow, install modes
#
# Every check ends PASSED, FAILED or NOT RUN (a tool is missing): a NOT RUN is never reported as
# a pass, and the line says what to run later. --strict makes NOT RUN fail too (CI).
# Needs bash 3.2+, git for the file lists, python3 with PyYAML for the assertions.
# Reads and renders only; it never installs anything and never touches the cluster or the engine.
#   KUBE_VERSIONS="1.28.0 1.31.0"   Kubernetes versions kubeconform checks the manifests against
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
cd "$ROOT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/validate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

STRICT=0
GROUPS_WANTED=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict) STRICT=1; shift ;;
        -h | --help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        yaml | shell | compose | helm | kit | images | releases | secrets | stale) GROUPS_WANTED+=("$1"); shift ;;
        all) shift ;;
        *) echo "validate: unknown argument '$1' (see --help)" >&2; exit 2 ;;
    esac
done
[[ ${#GROUPS_WANTED[@]} -gt 0 ]] || GROUPS_WANTED=(yaml shell compose helm kit images releases secrets stale)

# ── results ──────────────────────────────────────────────────────────────────
NAMES=(); STATES=(); NOTES=()
record() { NAMES+=("$1"); STATES+=("$2"); NOTES+=("$3"); }
FAILED=0
step() {  # step NAME "command shown in the report" cmd args...
    local name="$1" shown="$2"
    shift 2
    if "$@" > "$TMP/step.out" 2>&1; then
        record "$name" PASSED "$shown"
    else
        record "$name" FAILED "$shown"
        FAILED=$((FAILED + 1))
        sed 's/^/      | /' "$TMP/step.out" | head -n 40 >&2
    fi
}
not_run() { record "$1" "NOT RUN" "$2. To run it: $3"; }

native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# Files of the repo: tracked, plus new files that are not ignored (so a change is checked before it is committed).
repo_files() {
    local f
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        # A file deleted from the work tree but not yet from the index is still listed: skip it.
        git -C "$ROOT" ls-files -co --exclude-standard | sort -u | while IFS= read -r f; do [[ ! -f "$f" ]] || printf '%s\n' "$f"; done
    else
        find . -type f -not -path './.git/*' -not -path '*/node_modules/*' | sed 's|^\./||' | sort
    fi
}

PY=""
for candidate in python3 python py; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import yaml' >/dev/null 2>&1; then PY="$candidate"; break; fi
done

want() { local g; for g in "${GROUPS_WANTED[@]}"; do [[ "$g" == "$1" ]] && return 0; done; return 1; }

# The release the checks use: the three tags of the latest release (releases.yml is read, never changed).
LATEST_ENV="$(bash "$SCRIPT_DIR/release-tags.sh" --format env 2>/dev/null || true)"
latest_value() { printf '%s\n' "$LATEST_ENV" | sed -n "s/^$1=//p"; }
LATEST_RELEASE="$(latest_value PORTAL_RELEASE)"
LATEST_BACKEND="$(latest_value BACKEND_TAG)"
LATEST_FRONTEND="$(latest_value FRONTEND_TAG)"
LATEST_CUBE="$(latest_value CUBE_TAG)"

# ── yaml ─────────────────────────────────────────────────────────────────────
group_yaml() {
    if [[ -z "$PY" ]]; then
        not_run "yaml: every YAML file parses" "python3 with PyYAML is missing" "pip install pyyaml && scripts/validate.sh yaml"
        return
    fi
    local yamls=() jsons=() f
    while IFS= read -r f; do
        case "$f" in
            deploy/helm/*/templates/*) ;;                     # Go templates: rendered by the helm group
            *.yml | *.yaml) yamls+=("$f") ;;
            *.json) case "$f" in e2e/package*.json | */package-lock.json) ;; *) jsons+=("$f") ;; esac ;;
        esac
    done < <(repo_files)
    step "yaml: ${#yamls[@]} YAML files parse" "$PY scripts/check_manifests.py yaml <every .yml/.yaml outside Helm templates>" "$PY" scripts/check_manifests.py yaml "${yamls[@]}"
    if [[ ${#jsons[@]} -gt 0 ]]; then
        step "yaml: ${#jsons[@]} JSON files parse (incl. values.schema.json)" "$PY scripts/check_manifests.py json ${jsons[*]}" "$PY" scripts/check_manifests.py json "${jsons[@]}"
    fi
}

# ── shell ────────────────────────────────────────────────────────────────────
group_shell() {
    local scripts=() f
    while IFS= read -r f; do
        case "$f" in *.sh) scripts+=("$f") ;; esac
    done < <(repo_files)
    step "shell: bash -n on ${#scripts[@]} scripts" "bash -n <each tracked *.sh>" bash -c 'for f in "$@"; do bash -n "$f" || exit 1; done' _ "${scripts[@]}"
    if command -v shellcheck >/dev/null 2>&1; then
        step "shell: ShellCheck (-x -S warning) on ${#scripts[@]} scripts" "shellcheck -x -S warning <each tracked *.sh>" shellcheck -x -S warning "${scripts[@]}"
    else
        not_run "shell: ShellCheck" "shellcheck is not installed" "shellcheck -x -S warning \$(git ls-files '*.sh')"
    fi
}

# ── compose ──────────────────────────────────────────────────────────────────
COMPOSE_TEST_TAGS=(--backend-tag prod-0000000000000000000000000000000000000001 --frontend-tag prod-0000000000000000000000000000000000000002 --cube-tag 9.9.9)

compose_env_file() {  # placeholders only: nothing here is a secret
    ( umask 077
      {
        echo "JWT_SECRET=validate-only"
        echo "CUBE_API_SECRET=validate-only"
        echo "POSTGRES_PASSWORD=validate-only"
        echo "REDIS_PASSWORD=validate-only"
        echo "DBT_PROJECT_PATH="
        echo "BACKEND_TAG=prod-0000000000000000000000000000000000000001"
        echo "FRONTEND_TAG=prod-0000000000000000000000000000000000000002"
        echo "CUBE_TAG=9.9.9"
      } > "$TMP/compose.env" )
}

# render_compose KIND FILE... : docker compose config as JSON, then the assertions.
render_compose() {
    local kind="$1"; shift
    docker compose --env-file "$(native_path "$TMP/compose.env")" "$@" config --format json > "$TMP/$kind.json"
    "$PY" "$SCRIPT_DIR/check_manifests.py" "$kind" "$TMP/$kind.json" "${COMPOSE_TEST_TAGS[@]}"
}

portal_script_checks() {
    local env="$TMP/portal.env" before after key value
    # PROJECT_SOURCE=volume: nothing machine-specific, so no compose.override.yaml is written here.
    PROJECT_SOURCE=volume bash "$SCRIPT_DIR/portal.sh" --env-file "$env" init
    for key in JWT_SECRET CUBE_API_SECRET POSTGRES_PASSWORD REDIS_PASSWORD; do
        value="$(sed -n "s/^$key=//p" "$env" | head -n 1)"
        [[ ${#value} -ge 32 ]] || { echo "init did not generate $key"; return 1; }
    done
    # The env file holds secrets: owner-only. (Windows file systems have no such permission.)
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*) ;;
        *) [[ "$(stat -c '%a' "$env" 2>/dev/null || stat -f '%Lp' "$env")" == 600 ]] || { echo "init left the env file with permission other than 600"; return 1; } ;;
    esac
    before="$(cksum < "$env")"
    PROJECT_SOURCE=volume bash "$SCRIPT_DIR/portal.sh" --env-file "$env" init
    after="$(cksum < "$env")"
    [[ "$before" == "$after" ]] || { echo "a second init changed the env file"; return 1; }
    # The values generated are never printed.
    if PROJECT_SOURCE=volume bash "$SCRIPT_DIR/portal.sh" --env-file "$env" init 2>&1 | grep -F -f <(sed -n 's/^\(JWT_SECRET\|CUBE_API_SECRET\|POSTGRES_PASSWORD\|REDIS_PASSWORD\)=//p' "$env"); then
        echo "init printed a secret"; return 1
    fi
    PROJECT_SOURCE=volume bash "$SCRIPT_DIR/portal.sh" --env-file "$env" check
    PROJECT_SOURCE=volume bash "$SCRIPT_DIR/portal.sh" --env-file "$env" --single check
    # --build needs the three source repos: stand-ins with a Dockerfile each.
    local src
    for src in backend frontend cube; do mkdir -p "$TMP/src/$src" && : > "$TMP/src/$src/Dockerfile"; done
    PROJECT_SOURCE=volume BACKEND_SRC="$TMP/src/backend" FRONTEND_SRC="$TMP/src/frontend" CUBE_SRC="$TMP/src/cube" \
        bash "$SCRIPT_DIR/portal.sh" --env-file "$env" --build check
    PROJECT_SOURCE=volume BACKEND_SRC="$TMP/src/backend" FRONTEND_SRC="$TMP/src/frontend" CUBE_SRC="$TMP/src/cube" \
        bash "$SCRIPT_DIR/portal.sh" --env-file "$env" --single --build check
    # An empty secret must fail the check, with the key named.
    sed -i.bak 's/^JWT_SECRET=.*/JWT_SECRET=/' "$env" && rm -f "$env.bak"
    if PROJECT_SOURCE=volume bash "$SCRIPT_DIR/portal.sh" --env-file "$env" check > "$TMP/check.out" 2>&1; then echo "check passed with an empty JWT_SECRET"; return 1; fi
    grep -q "JWT_SECRET" "$TMP/check.out" || { echo "check did not name JWT_SECRET"; return 1; }
}

group_compose() {
    compose_env_file
    if ! docker compose version >/dev/null 2>&1; then
        not_run "compose: docker compose renders" "docker compose is not installed" "docker compose -f compose.yaml config -q (and compose.single.yaml, +compose.build.yaml, +compose.single.build.yaml)"
    elif [[ -z "$PY" ]]; then
        not_run "compose: assertions" "python3 with PyYAML is missing" "pip install pyyaml && scripts/validate.sh compose"
    else
        step "compose: full stack renders and passes the assertions" "docker compose -f compose.yaml config --format json | check_manifests.py compose-full" render_compose compose-full -f compose.yaml
        step "compose: single-node stack" "docker compose -f compose.single.yaml config --format json | check_manifests.py compose-single" render_compose compose-single -f compose.single.yaml
        step "compose: source-build overlay on the full stack (no build run)" "docker compose -f compose.yaml -f compose.build.yaml config --format json | check_manifests.py compose-build" render_compose compose-build -f compose.yaml -f compose.build.yaml
        step "compose: source-build overlay on the single-node stack (no build run)" "docker compose -f compose.single.yaml -f compose.single.build.yaml config --format json | check_manifests.py compose-single-build" render_compose compose-single-build -f compose.single.yaml -f compose.single.build.yaml
        step "compose: Cube SQL overlay renders" "docker compose -f compose.single.yaml -f compose.cube-sql.yaml config -q" docker compose --env-file "$(native_path "$TMP/compose.env")" -f compose.single.yaml -f compose.cube-sql.yaml config -q
        step "compose: portal.sh init is idempotent and silent about secrets; check passes and fails when it should" "scripts/portal.sh --env-file <tmp> init|check [--single|--build]" portal_script_checks
    fi
    if podman compose version >/dev/null 2>&1; then
        step "compose: podman compose renders the full stack" "podman compose --env-file <tmp> -f compose.yaml config" podman compose --env-file "$(native_path "$TMP/compose.env")" -f compose.yaml config
        step "compose: podman compose renders the single-node stack" "podman compose --env-file <tmp> -f compose.single.yaml config" podman compose --env-file "$(native_path "$TMP/compose.env")" -f compose.single.yaml config
        step "compose: podman compose renders the source-build overlay" "podman compose --env-file <tmp> -f compose.yaml -f compose.build.yaml config" podman compose --env-file "$(native_path "$TMP/compose.env")" -f compose.yaml -f compose.build.yaml config
    else
        not_run "compose: podman compose renders" "podman compose is not installed" "podman compose -f compose.yaml config -q   (and compose.single.yaml, +compose.build.yaml)"
    fi
}

# ── helm ─────────────────────────────────────────────────────────────────────
CHART="deploy/helm/dbt-portal"
HELM_TAGS=(--backend-tag "" --frontend-tag "" --cube-tag "")
helm_tags_file() { bash "$SCRIPT_DIR/release-tags.sh" --format helm-values > "$TMP/tags.yaml"; }

hr() {  # hr NAME values-args... : render to $TMP/NAME.yaml
    local name="$1"; shift
    helm template dbt-portal "$CHART" --namespace dbt-portal -f "$(native_path "$TMP/tags.yaml")" "$@" > "$TMP/$name.yaml"
}
hlint() { helm lint --strict "$CHART" -f "$(native_path "$TMP/tags.yaml")" "$@"; }
hcase() {  # hcase NAME "assertion args" values-args... : render, then assert
    local name="$1" assertions="$2"
    shift 2
    hr "$name" "$@" || return 1
    # shellcheck disable=SC2086
    "$PY" "$SCRIPT_DIR/check_manifests.py" helm "$TMP/$name.yaml" "${HELM_TAGS[@]}" $assertions
}
expect_helm_failure() {  # expect_helm_failure "message fragment" values-args... : the render must fail with that message
    local fragment="$1" out
    shift
    if out="$(helm template dbt-portal "$CHART" --namespace dbt-portal -f "$(native_path "$TMP/tags.yaml")" "$@" 2>&1)"; then
        echo "rendered, but it should have been refused ($fragment)"
        return 1
    fi
    printf '%s\n' "$out" | grep -q -- "$fragment" || { echo "refused, but without the message '$fragment'"; return 1; }
}
helm_extra_checks() {
    local pinned="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    hr digest -f "$CHART/values-dev.yaml" --set "backend.image.digest=$pinned"
    [[ "$(grep -c "capgemini-dbt-portal-backend@$pinned" "$TMP/digest.yaml")" == 2 ]] || { echo "an image digest is not used by both the backend and the worker"; return 1; }
    hr probes -f "$CHART/values-dev.yaml" --set backend.probes.readiness.enabled=false
    hr dev-again -f "$CHART/values-dev.yaml"
    [[ "$(grep -c readinessProbe "$TMP/probes.yaml")" == "$(($(grep -c readinessProbe "$TMP/dev-again.yaml") - 1))" ]] || { echo "backend.probes.readiness.enabled=false did not remove exactly one readinessProbe"; return 1; }
    hr nodata -f "$CHART/values-dev.yaml" --set backups.persistence.enabled=false
    ! grep -q "claimName: dbt-portal-backups" "$TMP/nodata.yaml" || { echo "the backups claim is mounted although backups.persistence.enabled=false"; return 1; }
    ! grep -q "name: dbt-portal-backups" "$TMP/nodata.yaml" || { echo "a backups claim is created although backups.persistence.enabled=false"; return 1; }
    hr existing -f "$CHART/values-dev.yaml" --set workspace.persistence.existingClaim=my-ws
    ! grep -q "name: dbt-portal-workspace" "$TMP/existing.yaml" || { echo "a workspace claim is created although existingClaim is set"; return 1; }
    [[ "$(grep -c "claimName: my-ws" "$TMP/existing.yaml")" == 2 ]] || { echo "backend and worker do not both use the existing workspace claim"; return 1; }
    hr workerdata -f "$CHART/values-dev.yaml" --set worker.mountData=true
    [[ "$(grep -c "claimName: dbt-portal-data" "$TMP/workerdata.yaml")" == 2 ]] || { echo "worker.mountData=true does not give the worker the data claim"; return 1; }
    hr noingress -f "$CHART/values-prod.yaml" --set project.git.url=https://git.example.invalid/o/r.git
    ! grep -q "^kind: Ingress" "$TMP/noingress.yaml" || { echo "an Ingress is rendered by default"; return 1; }
    hr pdb1 -f "$CHART/values-dev.yaml" --set podDisruptionBudget.enabled=true
    ! grep -q "^kind: PodDisruptionBudget" "$TMP/pdb1.yaml" || { echo "a PodDisruptionBudget is rendered for single replicas"; return 1; }
}
helm_guards() {
    local base=(-f "$CHART/values-dev.yaml")
    expect_helm_failure "image tag is required" -f "$CHART/values-dev.yaml" --set backend.image.tag= || return 1
    expect_helm_failure "'latest'" "${base[@]}" --set backend.image.tag=latest || return 1
    expect_helm_failure "project.git.url is empty" "${base[@]}" --set project.source=git || return 1
    expect_helm_failure "embeds credentials" "${base[@]}" --set project.source=git --set project.git.url=https://user:pw@git.example.invalid/o/r.git || return 1
    expect_helm_failure "secrets.existingSecret" "${base[@]}" --set secrets.create=false || return 1
    expect_helm_failure "DATABASE_URL is required" --set secrets.create=true --set postgresql.enabled=false || return 1
    expect_helm_failure "backend.service.type" "${base[@]}" --set backend.service.type=LoadBalancer || return 1
    expect_helm_failure "cube.service.type" "${base[@]}" --set cube.service.type=NodePort || return 1
    expect_helm_failure "Additional property" "${base[@]}" --set unknownKey=1 || return 1
    expect_helm_failure "choose one" "${base[@]}" --set secrets.existingSecret=mine || return 1
}

# The optional pre-2026.11 database migration: a hook Job that runs a copy of postgres/upgrade.sh.
helm_legacy_migration() {
    local v="$CHART/values-dev.yaml" hooks
    cmp -s <(tr -d '\r' < postgres/upgrade.sh) <(tr -d '\r' < "$CHART/files/upgrade.sh") \
        || { echo "$CHART/files/upgrade.sh differs from postgres/upgrade.sh: copy it again"; return 1; }
    # Off by default: nothing of it in a normal render.
    hr legacy-off -f "$v"
    ! grep -q "legacy-migration" "$TMP/legacy-off.yaml" || { echo "the migration hook is rendered although legacyMigration.enabled is false"; return 1; }
    # Bundled PostgreSQL: only on upgrade (there is no database before the first install); the password is the chart's.
    hr legacy-bundled -f "$v" --set legacyMigration.enabled=true
    [[ "$(grep -c '"helm.sh/hook": pre-upgrade$' "$TMP/legacy-bundled.yaml")" == 2 ]] || { echo "bundled: the ConfigMap and the Job are not both pre-upgrade hooks"; return 1; }
    grep -q 'name: dbt-portal-secrets' "$TMP/legacy-bundled.yaml" || { echo "bundled: the Job does not use the chart's Secret"; return 1; }
    # External database: before the first install as well, with a Secret that exists already.
    hr legacy-external -f "$CHART/ci/legacy-migration-values.yaml"
    hooks="$(grep -c '"helm.sh/hook": pre-install,pre-upgrade$' "$TMP/legacy-external.yaml")"
    [[ "$hooks" == 2 ]] || { echo "external: the ConfigMap and the Job are not both pre-install,pre-upgrade hooks"; return 1; }
    grep -q 'value: "db.example.invalid"' "$TMP/legacy-external.yaml" && grep -q 'name: legacy-db-password' "$TMP/legacy-external.yaml" \
        || { echo "external: the Job does not use the given host and password Secret"; return 1; }
    # A failed Job stays (its log), a finished one goes.
    grep -q '"helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded' "$TMP/legacy-external.yaml" || { echo "the hook's delete policy is not before-hook-creation,hook-succeeded"; return 1; }
    expect_helm_failure "legacyMigration.database.host" -f "$CHART/ci/external-services-values.yaml" --set legacyMigration.enabled=true || return 1
    expect_helm_failure "legacyMigration.passwordSecret.name" -f "$CHART/ci/external-services-values.yaml" --set legacyMigration.enabled=true --set legacyMigration.database.host=db.example.invalid || return 1
    expect_helm_failure "postgresql.auth.database=portal" -f "$v" --set legacyMigration.enabled=true --set postgresql.auth.database=other || return 1
}

group_helm() {
    if ! command -v helm >/dev/null 2>&1; then
        not_run "helm: lint, template, assertions" "helm is not installed" "scripts/validate.sh helm   (helm 3: https://helm.sh/docs/intro/install/)"
        return
    fi
    if [[ -z "$PY" ]]; then
        not_run "helm: assertions" "python3 with PyYAML is missing" "pip install pyyaml && scripts/validate.sh helm"
        return
    fi
    helm_tags_file
    HELM_TAGS=(--backend-tag "$LATEST_BACKEND" --frontend-tag "$LATEST_FRONTEND" --cube-tag "$LATEST_CUBE")
    local git_url="https://git.example.invalid/org/repo.git"
    step "helm: lint --strict (dev)" "helm lint --strict $CHART -f tags.yaml -f $CHART/values-dev.yaml" hlint -f "$CHART/values-dev.yaml"
    step "helm: lint --strict (test)" "helm lint --strict $CHART -f tags.yaml -f $CHART/values-test.yaml" hlint -f "$CHART/values-test.yaml"
    step "helm: lint --strict (prod, existing Secret)" "helm lint --strict $CHART -f tags.yaml -f $CHART/values-prod.yaml --set project.git.url=<repo>" hlint -f "$CHART/values-prod.yaml" --set "project.git.url=$git_url"
    step "helm: lint --strict (every optional feature on)" "helm lint --strict $CHART -f tags.yaml -f $CHART/ci/all-features-values.yaml" hlint -f "$CHART/ci/all-features-values.yaml"

    step "helm: dev renders; bundled services, created Secret, assertions" "helm template dbt-portal $CHART -f tags.yaml -f values-dev.yaml | check_manifests.py helm --bundled --secret-created" \
        hcase dev "--bundled --secret-created" -f "$CHART/values-dev.yaml"
    step "helm: test renders; external services, existing Secret, assertions" "helm template dbt-portal $CHART -f tags.yaml -f values-test.yaml | check_manifests.py helm --external --secret-existing dbt-portal-secrets" \
        hcase test "--external --secret-existing dbt-portal-secrets" -f "$CHART/values-test.yaml"
    step "helm: prod renders with an existing Secret (+Ingress): no Secret rendered, only the frontend routed" "helm template dbt-portal $CHART -f tags.yaml -f values-prod.yaml --set project.git.url=<repo> --set ingress... | check_manifests.py helm --external --secret-existing dbt-portal-secrets --ingress" \
        hcase prod "--external --secret-existing dbt-portal-secrets --ingress" -f "$CHART/values-prod.yaml" --set "project.git.url=$git_url" \
            --set ingress.enabled=true --set ingress.className=ci-class --set "ingress.hosts[0].host=portal.example.invalid"
    step "helm: every optional feature renders and passes the assertions" "helm template dbt-portal $CHART -f tags.yaml -f ci/all-features-values.yaml | check_manifests.py helm --bundled --secret-created --ingress --cube-sql" \
        hcase all-features "--bundled --secret-created --ingress --cube-sql" -f "$CHART/ci/all-features-values.yaml"
    step "helm: external PostgreSQL/Redis with a created Secret" "helm template dbt-portal $CHART -f tags.yaml -f ci/external-services-values.yaml | check_manifests.py helm --external --secret-created" \
        hcase external "--external --secret-created" -f "$CHART/ci/external-services-values.yaml"
    step "helm: digests, optional claims, probes, ingress and PDB defaults" "helm template ... (digest, existingClaim, backups off, no Ingress by default, no PDB for one replica)" helm_extra_checks
    step "helm: legacy migration hook: off by default, bundled=pre-upgrade, external=pre-install+pre-upgrade, same script as postgres/upgrade.sh, guards" "helm template ... --set legacyMigration.enabled=true; cmp postgres/upgrade.sh files/upgrade.sh" helm_legacy_migration
    step "helm: the migration hook with an external database passes the assertions" "helm template dbt-portal $CHART -f tags.yaml -f ci/legacy-migration-values.yaml | check_manifests.py helm --external --secret-created" \
        hcase legacy "--external --secret-created" -f "$CHART/ci/legacy-migration-values.yaml"
    step "helm: invalid settings are refused with a clear message" "helm template ... with a missing tag, 'latest', no git URL, credentials in the URL, no Secret, a public Service type, an unknown key" helm_guards

    # Manifests against the Kubernetes API schemas, version by version (schema validation, not a cluster test).
    if command -v kubeconform >/dev/null 2>&1; then
        local v
        for v in ${KUBE_VERSIONS:-1.28.0 1.31.0}; do
            step "helm: kubeconform -strict, Kubernetes $v (dev, test, prod, all features)" "kubeconform -strict -summary -kubernetes-version $v <rendered manifests>" \
                kubeconform -strict -summary -kubernetes-version "$v" "$TMP/dev.yaml" "$TMP/test.yaml" "$TMP/prod.yaml" "$TMP/all-features.yaml" "$TMP/external.yaml" "$TMP/legacy.yaml" "$TMP/legacy-bundled.yaml"
        done
    else
        not_run "helm: kubeconform" "kubeconform is not installed" "helm template dbt-portal $CHART -f <tags> -f $CHART/values-dev.yaml | kubeconform -strict -summary -kubernetes-version 1.31.0   (https://github.com/yannh/kubeconform)"
    fi
    if [[ "${VALIDATE_KUBECTL_SERVER:-0}" == 1 ]] && command -v kubectl >/dev/null 2>&1; then
        step "helm: kubectl apply --dry-run=server (dev)" "kubectl apply --dry-run=server -f <rendered dev manifests>" kubectl apply --dry-run=server -f "$(native_path "$TMP/dev.yaml")"
    else
        not_run "helm: kubectl apply --dry-run=server" "it needs a cluster (set VALIDATE_KUBECTL_SERVER=1 against a test cluster only)" "helm template dbt-portal $CHART -f <tags> -f $CHART/values-dev.yaml | kubectl apply --dry-run=server -f -"
    fi
}

# ── releases ─────────────────────────────────────────────────────────────────
releases_checks() {
    local list name n=0 appversion
    list="$(bash "$SCRIPT_DIR/release-tags.sh" --list)" || return 1
    printf '%s\n' "$list" | grep -q "(latest)$" || { echo "releases.yml: 'latest' names no release"; return 1; }
    while IFS= read -r name; do
        name="${name% (latest)}"
        bash "$SCRIPT_DIR/release-tags.sh" --release "$name" --format env > /dev/null || { echo "release $name is incomplete"; return 1; }
        n=$((n + 1))
    done <<< "$list"
    [[ "$n" -ge 1 ]] || { echo "releases.yml lists no release"; return 1; }
    [[ -n "$LATEST_BACKEND$LATEST_FRONTEND$LATEST_CUBE" ]] || { echo "the latest release has no tags"; return 1; }
    # Everything that repeats the latest release agrees with it.
    appversion="$(sed -n 's/^appVersion: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$CHART/Chart.yaml")"
    [[ "$appversion" == "$LATEST_RELEASE" ]] || { echo "Chart.yaml appVersion '$appversion' is not releases.yml latest '$LATEST_RELEASE'"; return 1; }
    local key expected actual
    for key in BACKEND:$LATEST_BACKEND FRONTEND:$LATEST_FRONTEND CUBE:$LATEST_CUBE; do
        expected="${key#*:}"
        actual="$(sed -n "s/^${key%%:*}_TAG=//p" .env.example | head -n 1)"
        [[ "$actual" == "$expected" ]] || { echo ".env.example ${key%%:*}_TAG is '$actual', latest is '$expected' (scripts/release-tags.sh --write-env .env.example)"; return 1; }
    done
    echo "$n releases, latest $LATEST_RELEASE"
}
image_name_checks() {
    local repo
    for repo in capgemini-dbt-portal-backend capgemini-dbt-portal-frontend capgemini-dbt-portal-cube; do
        grep -q "image: \${IMAGE_REGISTRY:-ghcr.io/omaryehia015}/$repo:" compose.yaml || { echo "compose.yaml does not use $repo from the registry"; return 1; }
        grep -q "repository: $repo\$" "$CHART/values.yaml" || { echo "the chart does not use the repository $repo"; return 1; }
    done
    grep -q "^imageRegistry: ghcr.io/omaryehia015\$" "$CHART/values.yaml" || { echo "the chart's default registry is not ghcr.io/omaryehia015"; return 1; }
    ! grep -nE '^ +tag: *"?[A-Za-z0-9]' "$CHART/values.yaml" | grep -vE 'tag: *"(17-alpine|7-alpine)"' || { echo "values.yaml pins an image tag: tags come from releases.yml"; return 1; }
}
# add-release.sh and sync-release.sh, on a copy of the repo's release files: nothing in the repo is touched.
release_automation() (   # a subshell: it changes directory
    local w="$TMP/relwork" before b="prod-1111111111111111111111111111111111111111"
    mkdir -p "$w/deploy/helm" "$w/images"
    cp -R "$ROOT/scripts" "$w/scripts"
    cp "$ROOT/releases.yml" "$ROOT/.env.example" "$w/"
    cp -R "$ROOT/deploy/helm/dbt-portal" "$w/deploy/helm/"
    cp "$ROOT/images/prod.yaml" "$w/images/prod.yaml"
    cd "$w"
    bash scripts/sync-release.sh --check >/dev/null || { echo "a fresh copy is not in sync with its own latest release"; return 1; }
    # The newest prod images come from the records; a missing one is named, nothing is written.
    before="$(cksum < releases.yml)"
    if bash scripts/add-release.sh --name 2026.99.0 --from-images --notes x >/dev/null 2>&1; then echo "add-release accepted a release with no recorded images"; return 1; fi
    [[ "$(cksum < releases.yml)" == "$before" ]] || { echo "a refused add-release changed releases.yml"; return 1; }
    # An entry from recorded images plus an explicit Cube tag, with notes.
    "$PY" scripts/record_image.py record --file images/prod.yaml --environment prod --component backend --tag "$b" --commit "${b#prod-}" >/dev/null || return 1
    "$PY" scripts/record_image.py record --file images/prod.yaml --environment prod --component frontend --tag "prod-2222222222222222222222222222222222222222" --commit 2222222222222222222222222222222222222222 >/dev/null || return 1
    bash scripts/add-release.sh --name 2026.99.0 --from-images --cube prod-3333333 --notes "A long note that has to be folded onto several lines because it is longer than a single line of releases.yml should be." >/dev/null \
        || { echo "add-release failed with valid input"; return 1; }
    [[ "$(bash scripts/release-tags.sh --format env | sed -n 's/^PORTAL_RELEASE=//p')" == 2026.99.0 ]] || { echo "the new release is not the latest"; return 1; }
    [[ "$(bash scripts/release-tags.sh --format env | sed -n 's/^BACKEND_TAG=//p')" == "$b" ]] || { echo "the backend tag did not come from images/prod.yaml"; return 1; }
    bash scripts/sync-release.sh --check >/dev/null || { echo "add-release left .env.example or Chart.yaml out of date"; return 1; }
    grep -q '^CUBE_TAG=prod-3333333' .env.example || { echo ".env.example was not updated"; return 1; }
    grep -q '^appVersion: "2026.99.0"' deploy/helm/dbt-portal/Chart.yaml || { echo "the chart appVersion was not updated"; return 1; }
    "$PY" scripts/check_manifests.py yaml releases.yml >/dev/null || { echo "releases.yml no longer parses"; return 1; }
    [[ "$(bash scripts/release-tags.sh --list | wc -l)" == "$(($(bash "$ROOT/scripts/release-tags.sh" --list | wc -l) + 1))" ]] || { echo "add-release did not add exactly one release"; return 1; }
    # Refused, and nothing written: the same name, 'latest', a bad name, a bad tag.
    before="$(cksum < releases.yml)"
    local args
    for args in "--name 2026.99.0 --backend prod-a --frontend prod-b --cube prod-c" \
                "--name 2026.99.1 --backend latest --frontend prod-b --cube prod-c" \
                "--name nightly --backend prod-a --frontend prod-b --cube prod-c" \
                "--name 2026.99.1 --backend prod-a;rm --frontend prod-b --cube prod-c"; do
        # shellcheck disable=SC2086
        if bash scripts/add-release.sh $args >/dev/null 2>&1; then echo "add-release accepted: $args"; return 1; fi
    done
    [[ "$(cksum < releases.yml)" == "$before" ]] || { echo "a refused add-release changed releases.yml"; return 1; }
    # Drift is reported, and fixed by sync.
    sed -i 's/^appVersion: .*/appVersion: "2026.10.0"/' deploy/helm/dbt-portal/Chart.yaml
    if bash scripts/sync-release.sh --check >"$TMP/sync.out" 2>&1; then echo "sync --check did not see a stale chart"; return 1; fi
    grep -q 'Chart.yaml' "$TMP/sync.out" || { echo "sync --check did not name Chart.yaml"; return 1; }
    bash scripts/sync-release.sh >/dev/null && bash scripts/sync-release.sh --check >/dev/null || { echo "sync did not fix the drift"; return 1; }
)

group_releases() {
    if [[ -n "$PY" ]]; then
        step "releases: add-release.sh and sync-release.sh add one release, sync what repeats it, and refuse bad input (on a copy)" "scripts/add-release.sh / sync-release.sh on a temporary copy" release_automation
    else
        not_run "releases: add-release and sync-release" "python3 with PyYAML is missing" "pip install pyyaml && scripts/validate.sh releases"
    fi
    step "releases: releases.yml complete; .env.example and the chart's appVersion match latest" "scripts/release-tags.sh --list|--release <each>; compare .env.example, Chart.yaml" releases_checks
    step "releases: image names and registry; the chart pins no application tag" "grep compose.yaml and $CHART/values.yaml" image_name_checks
}

# ── secrets ──────────────────────────────────────────────────────────────────
secret_files_checks() {
    local bad=0 f
    while IFS= read -r f; do
        case "$f" in
            .env.example | */.env.example) ;;
            .env | */.env | .env.* | */.env.* | *.env.local) echo "tracked env file: $f"; bad=1 ;;
            compose.override.yaml | */compose.override.yaml) echo "tracked generated override: $f"; bad=1 ;;
            *.local.yaml | *.secret.yaml | */secrets.yaml | */secrets.*.yaml | *.rendered.yaml) echo "tracked local/rendered file: $f"; bad=1 ;;
            */secrets.env | secrets.env) echo "tracked secrets file: $f"; bad=1 ;;
            *.pem | *.key | *.pfx | *.p12 | kubeconfig | */kubeconfig | */kubeconfig.*) echo "tracked key or credential file: $f"; bad=1 ;;
        esac
    done < <(repo_files)
    return "$bad"
}
ignore_checks() {
    git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git work tree"; return 1; }
    local f bad=0
    for f in .env .env.prod .env.local compose.override.yaml deploy/helm/dbt-portal/values-prod.local.yaml deploy/helm/dbt-portal/my.secret.yaml deploy/helm/dbt-portal/secrets.yaml rendered/dev.yaml dev.rendered.yaml; do
        git -C "$ROOT" check-ignore -q -- "$f" || { echo "NOT ignored but must be: $f"; bad=1; }
    done
    for f in .env.example deploy/client/.env.example deploy/helm/dbt-portal/templates/secret.yaml deploy/helm/dbt-portal/values-prod.yaml compose.yaml; do
        if git -C "$ROOT" check-ignore -q -- "$f"; then echo "ignored but must be tracked: $f"; bad=1; fi
    done
    return "$bad"
}
committed_values_have_no_secrets() {
    # The committed example values name secrets only in comments: no secrets.values entry, no inline credential.
    local f bad=0
    for f in "$CHART"/values*.yaml "$CHART"/ci/*.yaml; do
        if grep -nE '^[^#]*(password|token|secret_?key|api_?key)[A-Za-z_]*: *["'"'"']?[A-Za-z0-9+/_.=-]{12,}' "$f" | grep -viE 'ci-not-a|existingSecret|secretName|existingClaim|PORTAL_SECRET_KEY: *$'; then bad=1; fi
    done
    return "$bad"
}
group_secrets() {
    step "secrets: no env file, override, local/rendered values or key is tracked" "git ls-files -co --exclude-standard | match secret-file patterns" secret_files_checks
    step "secrets: .env, compose.override.yaml, local Helm values and rendered manifests are git-ignored" "git check-ignore <each path>" ignore_checks
    step "secrets: committed values files carry no credential" "grep the values files" committed_values_have_no_secrets
    if command -v gitleaks >/dev/null 2>&1; then
        step "secrets: Gitleaks on the working tree" "gitleaks detect --no-git --source . --redact" gitleaks detect --no-git --source "$ROOT" --redact --no-banner
    else
        not_run "secrets: Gitleaks" "gitleaks is not installed" "gitleaks detect --no-git --source . --redact   (https://github.com/gitleaks/gitleaks; CI also scans the history)"
    fi
}

# ── stale ────────────────────────────────────────────────────────────────────
stale_checks() {
    local hits=0 f
    while IFS= read -r f; do
        case "$f" in
            docs/KUBERNETES.md | scripts/validate.sh | .github/workflows/validate.yml) continue ;;   # the migration guide and this check name the old paths
            deploy/client/download/* | *.png | *.exe) continue ;;
            *.drawio) continue ;;                                # diagram sources (one huge line each), regenerated by hand
        esac
        if grep -nIE 'deploy/kubernetes|kustomization\.ya?ml|kubectl kustomize|kubectl apply -k|kustomize\.config' -- "$f" > "$TMP/stale.out" 2>/dev/null; then
            cut -c1-200 "$TMP/stale.out" | sed "s|^|$f:|"
            hits=1
        fi
    done < <(repo_files)
    [[ ! -d deploy/kubernetes ]] || { echo "deploy/kubernetes still exists"; hits=1; }
    return "$hits"
}
group_stale() {
    step "stale: no reference to the removed Kustomize install outside the migration guide" "grep -rE 'deploy/kubernetes|kustomization|kubectl apply -k' (tracked files)" stale_checks
}

# ── kit: what a client downloads ─────────────────────────────────────────────
KIT=""
build_kit() {
    KIT="$(bash "$SCRIPT_DIR/build-kit.sh" "$LATEST_RELEASE" "$TMP" 2>/dev/null)" || return 1
    printf 'PORTAL_PORT=8080\n' > "$KIT/.env"   # manage.sh needs an install to talk about
}

kit_contents() {
    local f
    for f in compose.yaml compose.single.yaml .env.example releases.yml setup.sh setup.ps1 manage.sh manage.ps1 lib.sh lib.ps1 \
             install.sh install.ps1 portal.sh release-tags.sh README.md postgres/upgrade.sh deploy/helm/dbt-portal/Chart.yaml deploy/helm/dbt-portal/values.yaml; do
        [[ -f "$KIT/$f" ]] || { echo "the kit has no $f"; return 1; }
    done
    # The default everywhere is to pull: no build overlay, no build section, no source.
    for f in "$KIT"/*build*; do [[ ! -e "$f" ]] || { echo "the kit contains a build overlay: ${f##*/}"; return 1; }; done
    ! grep -nE '^ +build:' "$KIT/compose.yaml" "$KIT/compose.single.yaml" || { echo "a kit compose file builds an image"; return 1; }
    [[ ! -e "$KIT/deploy/helm/dbt-portal/ci" ]] || { echo "the kit carries the CI value sets"; return 1; }
    [[ -x "$KIT/manage.sh" && -x "$KIT/portal.sh" && -x "$KIT/install.sh" ]] || { echo "kit scripts are not executable"; return 1; }
    grep -q "^appVersion: \"$LATEST_RELEASE\"" "$KIT/deploy/helm/dbt-portal/Chart.yaml" || { echo "the kit chart is not labelled $LATEST_RELEASE"; return 1; }
    for f in BACKEND:$LATEST_BACKEND FRONTEND:$LATEST_FRONTEND CUBE:$LATEST_CUBE; do
        grep -q "^${f%%:*}_TAG=${f#*:}\$" "$KIT/.env.example" || { echo "the kit .env.example has another ${f%%:*}_TAG than release $LATEST_RELEASE"; return 1; }
    done
    # portal.sh and release-tags.sh work from the flat kit layout, not only from scripts/.
    [[ "$(cd "$KIT" && bash portal.sh release | sed -n 's/^BACKEND_TAG=//p')" == "$LATEST_BACKEND" ]] || { echo "portal.sh release does not read the kit's releases.yml"; return 1; }
}

kit_service_unit() {
    local unit
    unit="$(cd "$KIT" && PORTAL_ENGINE=docker bash manage.sh service print)" || return 1
    printf '%s\n' "$unit" | grep -q '^Type=oneshot$' || { echo "unit is not oneshot"; return 1; }
    printf '%s\n' "$unit" | grep -q '^RemainAfterExit=yes$' || { echo "unit does not stay active"; return 1; }
    printf '%s\n' "$unit" | grep -q '^Environment=PORTAL_ENGINE=docker$' || { echo "unit does not pin the engine"; return 1; }
    printf '%s\n' "$unit" | grep -q '^After=.*docker.service' || { echo "docker unit does not wait for docker.service"; return 1; }
    printf '%s\n' "$unit" | grep -q '^ExecStart=".*/manage.sh" start$' || { echo "unit does not run manage.sh start"; return 1; }
    printf '%s\n' "$unit" | grep -q '^ExecStop=".*/manage.sh" stop$' || { echo "unit does not run manage.sh stop"; return 1; }
    printf '%s\n' "$unit" | grep -q '^WantedBy=multi-user.target$' || { echo "system unit is not wanted by multi-user.target"; return 1; }
    unit="$(cd "$KIT" && PORTAL_ENGINE=podman bash manage.sh service print --user)" || return 1
    printf '%s\n' "$unit" | grep -q '^WantedBy=default.target$' || { echo "user unit is not wanted by default.target"; return 1; }
    ! printf '%s\n' "$unit" | grep -q 'docker.service' || { echo "podman unit depends on docker.service"; return 1; }
    # Refuses what cannot work: --user with Docker, a number that is not one.
    if (cd "$KIT" && PORTAL_ENGINE=docker bash manage.sh service print --workers x) >/dev/null 2>&1; then echo "--workers x was accepted"; return 1; fi
}

# The Kubernetes path of a client, with kubectl and helm replaced by recorders: what would be sent?
kit_kubernetes_flow() {
    local shims="$TMP/shims" log="$TMP/shim.log" token="validate-token-not-real"
    mkdir -p "$shims"; : > "$log"
    cat > "$shims/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$SHIM_LOG"
case "$*" in
  "config current-context") echo shim-context ;;
  create\ namespace*) printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: dbt-portal\n' ;;
  apply\ -f\ -) { echo "--- stdin:"; cat; } >> "$SHIM_LOG" ;;
esac
EOF
    cat > "$shims/helm" <<'EOF'
#!/usr/bin/env bash
echo "helm $*" >> "$SHIM_LOG"
EOF
    chmod +x "$shims/kubectl" "$shims/helm"
    (cd "$KIT" && SHIM_LOG="$log" PATH="$shims:$PATH" PORTAL_TOKEN="$token" PORTAL_USER_NAME=ci-user \
        bash portal.sh --yes helm-install --release "$LATEST_RELEASE" --pull-secret --values deploy/helm/dbt-portal/values-dev.yaml) >/dev/null 2>&1 \
        || { echo "helm-install --pull-secret failed"; return 1; }
    # The token reaches kubectl on stdin only: never in an argument of kubectl or helm.
    ! grep -E '^(kubectl|helm) ' "$log" | grep -q "$token" || { echo "the token is in a command line"; return 1; }
    grep -q "$token" "$log" || { echo "the pull Secret does not carry the token"; return 1; }
    grep -q 'name: ghcr-pull' "$log" && grep -q 'type: kubernetes.io/dockerconfigjson' "$log" || { echo "the pull Secret is not a dockerconfigjson named ghcr-pull"; return 1; }
    grep -E '^helm install ' "$log" | grep -q -- '--create-namespace' || { echo "helm install was not called"; return 1; }
    # Order of the values files: the release's tags, the pull secret, then the client's own.
    [[ "$(grep -E '^helm install ' "$log" | grep -o -- '-f [^ ]*' | sed 's|.*[/\\]||' | tr '\n' ' ')" == "release-tags.yaml pull-secret.yaml values-dev.yaml " ]] \
        || { echo "values files are not in the order tags, pull secret, client values"; return 1; }
    # Without --pull-secret nothing is created in the cluster.
    : > "$log"
    (cd "$KIT" && SHIM_LOG="$log" PATH="$shims:$PATH" bash portal.sh --yes helm-install --release "$LATEST_RELEASE" --values deploy/helm/dbt-portal/values-dev.yaml) >/dev/null 2>&1 || return 1
    ! grep -q 'apply' "$log" || { echo "a Secret was created without --pull-secret"; return 1; }
    # --pull-secret without a token stops before touching the cluster.
    : > "$log"
    if (cd "$KIT" && SHIM_LOG="$log" PATH="$shims:$PATH" PORTAL_TOKEN="" GITHUB_TOKEN="" bash portal.sh --yes helm-install --pull-secret --values deploy/helm/dbt-portal/values-dev.yaml) >/dev/null 2>&1; then
        echo "--pull-secret worked without a token"; return 1
    fi
    ! grep -qE '^helm install' "$log" || { echo "helm install ran without a token"; return 1; }
}

# The chart from a registry (--chart oci://...): which reference and version reach helm, and how the token does.
kit_oci_chart_flow() {
    local shims="$TMP/shims-oci" log="$TMP/shim-oci.log" token="validate-token-not-real" ref="oci://ghcr.io/example/charts/dbt-portal"
    mkdir -p "$shims"; : > "$log"
    cat > "$shims/helm" <<'EOF2'
#!/usr/bin/env bash
echo "helm $*" >> "$SHIM_LOG"
case "$*" in
  registry\ login*) { echo "--- login stdin:"; cat; } >> "$SHIM_LOG" ;;
esac
EOF2
    printf '#!/usr/bin/env bash\necho "kubectl $*" >> "$SHIM_LOG"\n' > "$shims/kubectl"
    chmod +x "$shims/helm" "$shims/kubectl"
    (cd "$KIT" && SHIM_LOG="$log" PATH="$shims:$PATH" PORTAL_TOKEN="$token" PORTAL_USER_NAME=ci-user \
        bash portal.sh --yes helm-install --release "$LATEST_RELEASE" --chart "$ref" --values my-values.yaml) >/dev/null 2>&1 \
        && { echo "a values file that does not exist was accepted"; return 1; }
    : > "$TMP/my-values.yaml"
    : > "$log"
    (cd "$TMP" && SHIM_LOG="$log" PATH="$shims:$PATH" PORTAL_TOKEN="$token" PORTAL_USER_NAME=ci-user \
        bash "$KIT/portal.sh" --yes helm-install --release "$LATEST_RELEASE" --chart "$ref" --values my-values.yaml) >/dev/null 2>&1 \
        || { echo "helm-install --chart oci:// failed"; return 1; }
    grep -qE "^helm install dbt-portal $ref --version $LATEST_RELEASE " "$log" || { echo "helm install did not get the reference and the release's version"; return 1; }
    grep -q '^helm registry login ghcr.io --username ci-user --password-stdin$' "$log" || { echo "helm was not signed in to ghcr.io on stdin"; return 1; }
    ! grep -E '^(kubectl|helm) ' "$log" | grep -q "$token" || { echo "the token is in a command line"; return 1; }
    grep -q "^$token" "$log" || { echo "the token did not reach helm registry login on stdin"; return 1; }
    # --chart-version wins over the release; no token: no login (a public chart).
    : > "$log"
    (cd "$TMP" && SHIM_LOG="$log" PATH="$shims:$PATH" PORTAL_TOKEN="" GITHUB_TOKEN="" \
        bash "$KIT/portal.sh" --yes helm-upgrade --chart "$ref" --chart-version 9.9.9 --values my-values.yaml) >/dev/null 2>&1 \
        || { echo "helm-upgrade --chart-version failed"; return 1; }
    grep -qE "^helm upgrade dbt-portal $ref --version 9.9.9 " "$log" || { echo "--chart-version was not used"; return 1; }
    ! grep -q 'registry login' "$log" || { echo "helm signed in without a token"; return 1; }
    # An OCI chart has no values-dev.yaml in the checkout: helm-template must be given values.
    if (cd "$TMP" && SHIM_LOG="$log" PATH="$shims:$PATH" bash "$KIT/portal.sh" helm-template --chart "$ref") >/dev/null 2>&1; then
        echo "helm-template --chart oci:// ran without --values"; return 1
    fi
}

# The package CI publishes: `helm package --version R --app-version R` of the chart, then it reads back as R.
chart_package() {
    local out="$TMP/chart-pkg" shown
    mkdir -p "$out"
    helm package "$CHART" --version "$LATEST_RELEASE" --app-version "$LATEST_RELEASE" --destination "$(native_path "$out")" >/dev/null || return 1
    [[ -f "$out/dbt-portal-$LATEST_RELEASE.tgz" ]] || { echo "no dbt-portal-$LATEST_RELEASE.tgz"; return 1; }
    shown="$(helm show chart "$(native_path "$out/dbt-portal-$LATEST_RELEASE.tgz")")"
    printf '%s\n' "$shown" | grep -q "^version: $LATEST_RELEASE\$" || { echo "the package is not version $LATEST_RELEASE"; return 1; }
    printf '%s\n' "$shown" | grep -q "^appVersion: \"\{0,1\}$LATEST_RELEASE\"\{0,1\}\$" || { echo "the package is not appVersion $LATEST_RELEASE"; return 1; }
    tar -tzf "$out/dbt-portal-$LATEST_RELEASE.tgz" | grep -q '/ci/' && { echo "the package carries the CI value sets"; return 1; }
    return 0
}

kit_install_modes() {
    local out
    out="$(bash "$SCRIPT_DIR/../deploy/client/install.sh" --mode nonsense 2>&1)" && { echo "an unknown mode was accepted"; return 1; }
    printf '%s' "$out" | grep -q "Unknown mode" || { echo "no message for an unknown mode"; return 1; }
    out="$(PORTAL_MODE=bogus bash "$SCRIPT_DIR/../deploy/client/install.sh" 2>&1)" && { echo "PORTAL_MODE=bogus was accepted"; return 1; }
    printf '%s' "$out" | grep -q "Unknown mode" || { echo "no message for PORTAL_MODE=bogus"; return 1; }
    # kubernetes mode asks for helm and kubectl before it downloads anything. An EMPTY PATH, so no helm,
    # kubectl or curl on this host can make it go further (it must stop at the first check).
    mkdir -p "$TMP/emptybin"
    out="$(env PATH="$TMP/emptybin" PORTAL_MODE=kubernetes "$BASH" "$SCRIPT_DIR/../deploy/client/install.sh" 2>&1)" && { echo "kubernetes mode ran without helm"; return 1; }
    [[ "$out" == *"helm is required"* ]] || { echo "kubernetes mode did not ask for helm first: $out"; return 1; }
    grep -q 'PORTAL_MODE' "$SCRIPT_DIR/../deploy/client/install.ps1" || { echo "install.ps1 does not guard PORTAL_MODE"; return 1; }
}

group_kit() {
    if [[ -z "$LATEST_RELEASE" ]]; then not_run "kit: client kit" "releases.yml has no latest release" "scripts/release-tags.sh"; return; fi
    if ! build_kit; then record "kit: scripts/build-kit.sh builds the kit of release $LATEST_RELEASE" FAILED "scripts/build-kit.sh $LATEST_RELEASE <dir>"; FAILED=$((FAILED + 1)); return; fi
    record "kit: scripts/build-kit.sh builds the kit of release $LATEST_RELEASE" PASSED "scripts/build-kit.sh $LATEST_RELEASE <dir>"
    step "kit: contents; pull-only (no build overlay or build section); tags and chart match the release; scripts run from the flat layout" "inspect the kit, run portal.sh release in it" kit_contents
    step "kit: systemd unit (docker: system, podman: user) wraps manage.sh start/stop at boot" "manage.sh service print [--user]" kit_service_unit
    step "kit: Kubernetes flow: pull secret via stdin only, values order, no cluster change without --pull-secret" "portal.sh helm-install --pull-secret (kubectl and helm replaced by recorders)" kit_kubernetes_flow
    step "kit: OCI chart (--chart oci://): reference and version reach helm, token on stdin only, --chart-version wins, no login without a token" "portal.sh helm-install --chart oci://... (helm replaced by a recorder)" kit_oci_chart_flow
    step "kit: install.sh modes are validated; install.ps1 guards PORTAL_MODE" "install.sh --mode nonsense; PORTAL_MODE=kubernetes without helm" kit_install_modes
    if command -v helm >/dev/null 2>&1; then
        step "chart: helm package --version R --app-version R (what the release publishes to GHCR) reads back as R, without CI value sets" "helm package; helm show chart" chart_package
        step "kit: helm template runs from the kit's own chart" "cd <kit> && portal.sh helm-template --values deploy/helm/dbt-portal/values-dev.yaml" \
            bash -c 'cd "$1" && bash portal.sh helm-template --values deploy/helm/dbt-portal/values-dev.yaml 2>/dev/null | grep -q "^kind: Deployment"' _ "$KIT"
    else
        not_run "kit: helm template from the kit" "helm is not installed" "cd <kit> && bash portal.sh helm-template --values deploy/helm/dbt-portal/values-dev.yaml"
    fi
}

# ── images: what the component pipelines record here ─────────────────────────
record_image_behaviour() {
    local rec="$SCRIPT_DIR/record_image.py" f="$TMP/images/dev.yaml" sha="0123456789abcdef0123456789abcdef01234567" sha2="fedcba9876543210fedcba9876543210fedcba98" out
    mkdir -p "$TMP/images"
    cp "$ROOT/images/dev.yaml" "$f"
    run() { "$PY" "$rec" record --file "$f" "$@"; }
    out="$(run --environment dev --component backend --tag "dev-$sha" --commit "$sha" --run-url https://github.com/o/capgemini-dbt-portal-backend/actions/runs/1 --published-at 2026-10-22T10:00:00Z)" || return 1
    [[ "$out" == recorded ]] || { echo "first record printed '$out'"; return 1; }
    out="$(run --environment dev --component backend --tag "dev-$sha" --commit "$sha")" || return 1
    [[ "$out" == unchanged ]] || { echo "the same image again printed '$out'"; return 1; }
    out="$(run --environment dev --component frontend --tag "dev-$sha2" --commit "$sha2")" || return 1
    [[ "$out" == recorded ]] || { echo "a second component printed '$out'"; return 1; }
    out="$(run --environment dev --component backend --tag "dev-$sha2" --commit "$sha2")" || return 1
    [[ "$out" == recorded ]] || { echo "a newer backend image printed '$out'"; return 1; }
    grep -q "tag: dev-$sha2" "$f" && ! grep -q "tag: dev-$sha\$" "$f" || { echo "the newer image did not replace the older one"; return 1; }
    "$PY" "$rec" check "$f" >/dev/null || { echo "the written file fails its own check"; return 1; }
    head -n 1 "$f" | grep -q '^# Images published for the dev environment' || { echo "the file lost its header"; return 1; }
    # What must be refused (exit 2, nothing written): another environment's tag, an unknown component,
    # a short or odd commit, a tag that tries to smuggle text, another registry's image, a foreign run URL.
    local before after
    before="$(cksum < "$f")"
    refuse() { local why="$1"; shift; if run "$@" >/dev/null 2>&1; then echo "accepted: $why"; return 1; fi; }
    refuse "a prod tag in the dev file" --environment dev --component backend --tag "prod-$sha" --commit "$sha" || return 1
    refuse "an unknown component" --environment dev --component database --tag "dev-$sha" --commit "$sha" || return 1
    refuse "a short commit" --environment dev --component backend --tag dev-abc --commit abc || return 1
    refuse "a tag that does not match its commit" --environment dev --component backend --tag "dev-$sha2" --commit "$sha" || return 1
    refuse "a tag with a command in it" --environment dev --component backend --tag 'dev-0123456; rm -rf /' --commit '0123456; rm -rf /' || return 1
    refuse "another registry's image" --environment dev --component backend --tag "dev-$sha" --commit "$sha" --image ghcr.io/someone-else/capgemini-dbt-portal-backend || return 1
    refuse "a run URL that is not GitHub Actions" --environment dev --component backend --tag "dev-$sha" --commit "$sha" --run-url https://evil.example/x || return 1
    refuse "an environment that does not match the file" --environment test --component backend --tag "test-$sha" --commit "$sha" || return 1
    after="$(cksum < "$f")"
    [[ "$before" == "$after" ]] || { echo "a refused record changed the file"; return 1; }
}

group_images() {
    if [[ -z "$PY" ]]; then
        not_run "images: image records" "python3 with PyYAML is missing" "pip install pyyaml && scripts/validate.sh images"
        return
    fi
    step "images: images/dev|test|prod.yaml follow the pipelines' tag convention" "$PY scripts/record_image.py check images/dev.yaml images/test.yaml images/prod.yaml" \
        "$PY" "$SCRIPT_DIR/record_image.py" check "$ROOT/images/dev.yaml" "$ROOT/images/test.yaml" "$ROOT/images/prod.yaml"
    step "images: record_image.py records, replaces, is idempotent and refuses malformed or hostile input" "scripts/record_image.py record ... (valid and invalid events, on a temporary copy)" record_image_behaviour
}

# ── run ──────────────────────────────────────────────────────────────────────
want yaml && group_yaml
want shell && group_shell
want compose && group_compose
want helm && group_helm
want releases && group_releases
want secrets && group_secrets
want stale && group_stale
want kit && group_kit
want images && group_images

echo
printf '%-8s %s\n' RESULT CHECK
passed=0; notrun=0
for i in "${!NAMES[@]}"; do
    printf '%-8s %s\n' "${STATES[$i]}" "${NAMES[$i]}"
    case "${STATES[$i]}" in
        PASSED) passed=$((passed + 1)); printf '         $ %s\n' "${NOTES[$i]}" ;;
        FAILED) printf '         $ %s\n' "${NOTES[$i]}" ;;
        *) notrun=$((notrun + 1)); printf '         %s\n' "${NOTES[$i]}" ;;
    esac
done
echo
echo "$passed passed, $FAILED failed, $notrun not run"
if [[ "$FAILED" -gt 0 ]]; then exit 1; fi
if [[ "$STRICT" == 1 && "$notrun" -gt 0 ]]; then echo "--strict: a NOT RUN counts as a failure" >&2; exit 1; fi
exit 0
