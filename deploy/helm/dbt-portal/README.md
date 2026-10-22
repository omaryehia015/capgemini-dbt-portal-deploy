# dbt-portal Helm chart

The Capgemini dbt Portal on Kubernetes: the frontend gateway, the backend API, the dbt workers
and the Cube semantic engine, with optional bundled PostgreSQL and Redis for development.
Release `dbt-portal`, namespace `dbt-portal`.

The full guide, with the production checklist, the Secret keys, storage, ingress, security, upgrade and
the migration from the old Kustomize install, is [docs/KUBERNETES.md](../../../docs/KUBERNETES.md).

```bash
# from the repo root: image tags are added from releases.yml (latest, or --release NAME)
scripts/portal.sh helm-template --values deploy/helm/dbt-portal/values-dev.yaml
scripts/portal.sh helm-install  --values deploy/helm/dbt-portal/values-dev.yaml

# plain helm: the image tags are REQUIRED (there is no default, and `latest` is refused)
helm install dbt-portal deploy/helm/dbt-portal -n dbt-portal --create-namespace \
  -f <(scripts/release-tags.sh --format helm-values) -f deploy/helm/dbt-portal/values-dev.yaml
```

| File | |
|---|---|
| `values.yaml` | Every setting, documented, with locked-down defaults |
| `values.schema.json` | Rejects typos, public Service types for the backend and Cube, a missing Secret name |
| `values-dev.yaml` | Trial: bundled PostgreSQL/Redis, chart-created Secret, nothing kept on uninstall |
| `values-test.yaml` | Shared test: external services, existing Secret |
| `values-prod.yaml` | Production starting point: external services, existing Secret, no secret value |
| `ci/*.yaml` | Value sets CI renders to cover every template branch (not examples) |
| `files/upgrade.sh` | A copy of [postgres/upgrade.sh](../../../postgres/upgrade.sh), run by the optional `legacyMigration` hook Job (`validate.sh helm` fails if they differ) |
| `templates/` | One file per component, plus `_helpers.tpl` and `NOTES.txt` |

Each release's chart is also published at `oci://ghcr.io/<owner>/charts/dbt-portal`, version = the release's
name (`--chart oci://... [--chart-version V]` in `portal.sh`; [docs/KUBERNETES.md](../../../docs/KUBERNETES.md#installing-the-chart-from-the-registry-no-zip-no-checkout)).
`legacyMigration.enabled=true` adds a pre-install/pre-upgrade hook Job that moves a pre-2026.11 database
into one ([docs/KUBERNETES.md](../../../docs/KUBERNETES.md#upgrade-rollback-uninstall)).

No `kubeVersion` is declared: the supported Kubernetes versions are not decided yet.
`scripts/validate.sh helm` lints, renders every value set, asserts on the result and validates it with
kubeconform.
