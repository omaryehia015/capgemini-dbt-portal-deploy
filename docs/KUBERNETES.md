# Running the portal on Kubernetes (Helm)

The chart is [deploy/helm/dbt-portal](../deploy/helm/dbt-portal). Release name `dbt-portal`,
namespace `dbt-portal`. It replaces the Kustomize install that used to live in
`deploy/kubernetes` (see [Migrating from Kustomize](#migrating-from-kustomize-to-helm)).

> **Read this before you rely on it.** The chart is validated by rendering: `helm lint --strict`,
> `helm template` for the dev, test and prod value sets, assertions on what is rendered, and
> `kubeconform` against the Kubernetes API schemas (1.28 and 1.31 locally, plus 1.33 in CI; `scripts/validate.sh helm`). It has
> **not been installed on a cluster** as part of this work. No Kubernetes version, Helm version, storage
> class, ingress controller, CNI or secret manager is decided yet, so none is claimed:
> test on your target, then fill in [Supported versions](#supported-versions).

## What it installs

```mermaid
flowchart LR
  U["users"] -->|Ingress, optional| FE["frontend ×2<br/>nginx: SPA + /api gateway<br/>:8080"]
  FE -->|/api + WebSocket| BE["backend ×1<br/>EXECUTION_ROLE=api<br/>:8000"]
  BE <--> CU["cube ×1<br/>:4000"]
  BE --> PGX[("PostgreSQL<br/>managed, or bundled for dev")]
  BE --> RDX[("Redis<br/>managed, or bundled for dev")]
  WK["worker ×N<br/>python -m app.worker"] --> RDX
  WK --> PGX
  BE --- WS[/"workspace PVC<br/>(the dbt project)"/]
  WK --- WS
  BE --- DT[/"data PVC"/]
  BE --- BK[/"backups PVC"/]
```

| Resource | Kind | Reachable from |
|---|---|---|
| `dbt-portal-frontend` | Deployment, Service (ClusterIP :8080) | the Ingress, or `kubectl port-forward` |
| `dbt-portal-backend` | Deployment, Service (ClusterIP :8000) | the frontend and Cube only |
| `dbt-portal-worker` | Deployment, **no Service** | nobody |
| `dbt-portal-cube` | Deployment, Service (ClusterIP :4000) | the backend only |
| `dbt-portal-postgres` | StatefulSet + PVC, Service, **only if** `postgresql.enabled` | the backend and workers |
| `dbt-portal-redis` | Deployment, Service, **only if** `redis.enabled` | the backend and workers |
| `dbt-portal-config`, `dbt-portal-secrets` | ConfigMap; Secret (only with `secrets.create`) | backend and worker |
| `dbt-portal-workspace`, `-data`, `-backups` | PersistentVolumeClaims | see [Storage](#storage) |
| `dbt-portal` | Ingress, **only if** `ingress.enabled` | routes to the frontend only |
| `dbt-portal`, NetworkPolicies, PodDisruptionBudgets, ServiceAccount | optional / small | |

Only the frontend is meant to be reached. The Service types of the backend and Cube are fixed to
`ClusterIP` by the values schema; Cube's SQL port (15432) is not in its Service unless
`cube.service.sql.enabled`, and even then stays in the cluster. The chart creates no `Namespace`: use
`--create-namespace`.

## Prerequisites

* Helm 3 and `kubectl`, pointed at the cluster you mean (the script prints the context first).
* A storage class for the workspace: **ReadWriteMany** when the backend and workers can land on
  different nodes (see [Storage](#storage)).
* Access to `ghcr.io/omaryehia015/capgemini-dbt-portal-*` (private: an [image pull Secret](#image-pull-credentials)).
* For production: a managed PostgreSQL and Redis, an ingress controller, TLS, a way to create the
  Secret.

## Image tags (release selection)

The chart has **no default image tag**, so it can never silently run a stale or `latest` image
(`latest` is refused unless `allowLatestTag: true`). Tags come from
[releases.yml](../releases.yml), the tested compatibility map, or from your own pinned values:

```bash
scripts/release-tags.sh --list                       # releases, newest first
scripts/release-tags.sh --format helm-values         # latest release as a values file
scripts/release-tags.sh 2026.10.17 --format helm-set # --set arguments for a named release
```

`scripts/portal.sh helm-*` adds the release's tags (default: latest; `--release NAME`) as the *first*
values file, so a tag you set in your own values file or with `--set` wins. In your own file use
immutable tags, for example:

```yaml
backend:  {image: {tag: prod-4c8c4a9eaf6b2afb5b982e3fa8454da7236aed8e}}   # or a digest: {digest: sha256:...}
frontend: {image: {tag: prod-476c3a2a6e137c83c6f37bf824c6140841ef25d1}}
cube:     {image: {tag: prod-<commit-sha>}}                                 # same convention as the other two
```

All three images follow the same convention: `dev-<commit-sha>`, `test-<commit-sha>`, `prod-<commit-sha>`. The
`1.0.1` that `releases.yml` currently records for Cube predates it: the chart takes whatever the release
records, so a tested combination with a `prod-<sha>` Cube tag works unchanged once `releases.yml` lists one.

Backend, frontend and Cube each have their own registry/repository/tag/digest/pullPolicy. The worker
always uses the backend image: same image, `args: [python, -m, app.worker]`.

What each environment last published (`dev-<sha>`, `test-<sha>`, `prod-<sha>`) is recorded in `images/dev.yaml`,
`images/test.yaml` and `images/prod.yaml`; copy a `tag` from there into your values file to run that exact build.
It is a record of what was published, not a tested combination: `releases.yml` remains that list.

## Development install

Bundled PostgreSQL and Redis, a Secret the chart creates, one replica of everything, small volumes.
**For a trial or a one-node cluster (kind, minikube, k3d, Docker Desktop), never for shared data.**

```bash
# render first (nothing touches the cluster)
scripts/portal.sh helm-template --values deploy/helm/dbt-portal/values-dev.yaml

# install (shows the cluster context and asks first; --yes skips the question)
scripts/portal.sh helm-install --values deploy/helm/dbt-portal/values-dev.yaml

# the same with helm directly
helm install dbt-portal deploy/helm/dbt-portal -n dbt-portal --create-namespace \
  -f <(scripts/release-tags.sh --format helm-values) -f deploy/helm/dbt-portal/values-dev.yaml
```

Then:

```bash
kubectl -n dbt-portal get pods
kubectl -n dbt-portal port-forward svc/dbt-portal-frontend 8080:8080     # http://localhost:8080
kubectl -n dbt-portal logs deploy/dbt-portal-backend | grep -A6 "GENERATED INITIAL CREDENTIALS"
```

With `secrets.create=true`, the chart generates `JWT_SECRET`, `CUBE_API_SECRET`, `PORTAL_SECRET_KEY` and
the bundled services' passwords the first time, and reads them back from the live Secret on every
upgrade (`lookup`), so they do not change. Values pass through Helm: keep anything you supply
(`secrets.values`) in a file that is **not** committed: `*.local.yaml` and `*.secret.yaml` are
git-ignored. `helm template` has no cluster to look at and generates new values each run: do not
`kubectl apply` its output.

## Test rendering

```bash
scripts/portal.sh helm-template --values deploy/helm/dbt-portal/values-test.yaml
scripts/validate.sh helm            # lint, render every value set, assertions, kubeconform
```

`values-test.yaml` is for a shared test cluster: no bundled services, an existing Secret
`dbt-portal-secrets`, one frontend replica. It renders without a cluster because it only
*references* the Secret.

Rendering proves the manifests are valid, not that the pods run. For that,
[kubernetes-smoke.yml](../.github/workflows/kubernetes-smoke.yml) creates a throwaway
[kind](https://kind.sigs.k8s.io/) cluster inside a CI job, installs the chart with
`portal.sh helm-install` (the published images, the release's tags, a pull Secret made from
`GHCR_READ_TOKEN`) and runs the same Playwright smoke test as the Compose stacks (`e2e/`) through a
port-forward. It runs on pull requests that touch the chart or the scripts that drive it, and on demand
with any tags. It is validation: the cluster disappears with the job and nothing is deployed anywhere.

## Installing from the client kit (a client without this repo)

A client downloads one script and the kit it fetches already holds the chart and `portal.sh`
([deploy/client/README.md](../deploy/client/README.md#where-to-run-it-this-computer-a-server-a-service-kubernetes)):

```bash
curl -fsSL <install.sh url> | PORTAL_TOKEN=<token> PORTAL_MODE=kubernetes bash
```

Needs `helm` and `kubectl` pointed at the cluster. Images are pulled, never built. The script resolves
the release's tags, makes the registry pull Secret `ghcr-pull` from the token (sent to `kubectl` on stdin,
never on a command line or on screen) and runs `portal.sh helm-install`. With no `--values` it is a
**trial** (`values-dev.yaml`: bundled PostgreSQL and Redis); for production the client passes their own
values file after `bash -s --`. Running it again with `PORTAL_RELEASE=<newer>` upgrades, using the newer
kit's chart. The kit is built by [scripts/build-kit.sh](../scripts/build-kit.sh) and checked by
`scripts/validate.sh kit`.

## Installing the chart from the registry (no zip, no checkout)

Every release's chart is also published as an OCI artifact next to the client kit (the
`chart` job of [client-kit.yml](../.github/workflows/client-kit.yml)), at
`oci://ghcr.io/<owner>/charts/dbt-portal`. Its **version is the release's name** (`2026.10.19`), so the
version you ask for is the release you run:

```bash
# helm yourself: the image tags are required values; the kit's (or a checkout's) releases.yml has them
scripts/release-tags.sh --release 2026.10.19 --format helm-values > release-tags.yaml
helm registry login ghcr.io -u <user> --password-stdin <<< "$PORTAL_TOKEN"   # private package: the token with read:packages
helm install dbt-portal oci://ghcr.io/<owner>/charts/dbt-portal --version 2026.10.19 \
  -n dbt-portal --create-namespace -f release-tags.yaml -f my-values.yaml

# or through portal.sh (it signs in with PORTAL_TOKEN on stdin, adds the release's tags, makes the pull Secret)
PORTAL_TOKEN=<token> scripts/portal.sh helm-install --release 2026.10.19 --pull-secret \
  --chart oci://ghcr.io/<owner>/charts/dbt-portal --values my-values.yaml
```

`--chart-version` overrides the version (it defaults to the release's). The chart carries no values for
your cluster: with an OCI chart `--values` is required, and `helm show values oci://... --version <release>`
prints every setting. The package is private like the images until its visibility is changed in the
GitHub package settings. `scripts/validate.sh kit` checks the packaging (`helm package --version R
--app-version R` reads back as R) and what `portal.sh --chart oci://...` sends to helm.

## Production install

`values-prod.yaml` is a starting point, **not** a statement that your platform is ready. It sets:
no bundled PostgreSQL/Redis, the Secret `dbt-portal-secrets` that **you** manage, `project.source: git`,
2 frontend replicas and 2 workers, PodDisruptionBudget and NetworkPolicy on, volumes kept on uninstall.
It contains no secret and no hostname.

1. **Create the Secret** in the namespace (see [the keys](#the-secret)): with `kubectl`, External
   Secrets, Sealed Secrets, Vault... *before* installing.
   ```bash
   kubectl create namespace dbt-portal
   kubectl -n dbt-portal create secret generic dbt-portal-secrets \
     --from-literal=JWT_SECRET="$(openssl rand -base64 48 | tr -d '/+=\n')" \
     --from-literal=CUBE_API_SECRET="$(openssl rand -base64 48 | tr -d '/+=\n')" \
     --from-literal=PORTAL_SECRET_KEY="$(openssl rand -base64 32 | tr '+/' '-_')" \
     --from-literal=DATABASE_URL='postgresql+psycopg2://portal:<password>@<host>:5432/portal' \
     --from-literal=REDIS_URL='redis://:<password>@<host>:6379/0'
   ```
   Keep `PORTAL_SECRET_KEY` in your secret manager too: the portal's own backups do not contain it when
   you set it yourself, and losing it makes the stored warehouse logins unreadable.
2. **Write your own values file** (not committed, e.g. `my-prod.local.yaml`): the git URL, storage
   classes, ingress, image pull Secret, pinned image tags, sizes.
   ```yaml
   project: {git: {url: https://github.com/<org>/<repo>.git, ref: main}}
   workspace: {persistence: {storageClass: <a ReadWriteMany class>}}
   ingress:
     enabled: true
     className: <your ingress class>
     hosts: [{host: <portal hostname>}]
     tls: [{secretName: <tls secret>, hosts: [<portal hostname>]}]
   ```
3. **Render, read, install:**
   ```bash
   scripts/portal.sh helm-template --values deploy/helm/dbt-portal/values-prod.yaml --values my-prod.local.yaml
   scripts/portal.sh helm-install  --values deploy/helm/dbt-portal/values-prod.yaml --values my-prod.local.yaml
   ```
   (`--values` is repeatable; later files win.) The prod values render with nothing but an existing
   Secret: no Secret is created or printed.

## The Secret

One Secret holds every secret; the backend and worker read it with `envFrom`, so **any other
environment variable the backend understands is passed through** (listed in
[.env.example](../.env.example)). The frontend gets none of it; Cube gets only `CUBE_API_SECRET`.

| Key | Required | Notes |
|---|---|---|
| `JWT_SECRET` | always | Signs session tokens; the same for backend and workers. |
| `CUBE_API_SECRET` | always | Shared by the backend and Cube. |
| `PORTAL_SECRET_KEY` | always | A Fernet key (URL-safe base64 of 32 bytes). Encrypts stored warehouse/git logins. Required here (unlike Compose) because the workers do not mount the backend's data volume: without a shared key each pod would invent its own. |
| `DATABASE_URL` | unless `postgresql.enabled` | `postgresql+psycopg2://user:password@host:5432/database` |
| `REDIS_URL` | unless `redis.enabled` | `redis://:password@host:6379/0` (a `rediss://` URL for TLS) |
| `POSTGRES_PASSWORD` | if `postgresql.enabled` | URL-safe characters only; `DATABASE_URL` is built from it inside the pod. |
| `REDIS_PASSWORD` | if `redis.enabled` | Likewise. |
| `DBT_PROJECT_GIT_TOKEN` | private git repo | Read-only token; `project.git.username` (non-secret) is `oauth2` for GitLab. |
| `DBT_PKG_*`, `DATABRICKS_*`, `DBT_WH_TYPE` | optional | Warehouse logins read through `env_var()`. Simplest: enter the warehouse in the portal instead. |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `AI_API_KEY` | optional | AI assistants. |
| `SMTP_PASSWORD`, `AIRFLOW_PASSWORD`, `AIRBYTE_CLIENT_SECRET`, `SEED_ADMIN_PASSWORD` | optional | |

A missing required key fails the pod at start (`couldn't find key`), loudly, instead of the app
running half-configured. The chart never injects an empty `DATABASE_URL` or `REDIS_URL`.

**Development**: `secrets.create=true` builds this Secret from `secrets.values` (+ generated keys).
**Production**: `secrets.create=false`, `secrets.existingSecret=<name>`: nothing is created, nothing
printed, and `secrets.values` is refused. No production value belongs in `values-prod.yaml`.

## External PostgreSQL and Redis

Production leaves `postgresql.enabled` and `redis.enabled` false and supplies the connection strings in
the Secret.

* **PostgreSQL**: one empty database (e.g. `portal`) and a user that owns it; the backend creates and
  migrates its schema. Use `sslmode=require` in the URL for a managed service
  (`...@host:5432/portal?sslmode=require`).
* **Redis**: a password-protected instance reachable from the backend and workers. It holds the job queue,
  live logs and short-lived sign-in codes; nothing in it has to survive a restart.
* The pods need network access to both (egress is not restricted by this chart's NetworkPolicy).

The **bundled** services (`values-dev.yaml`) are one pod each with one disk: **not highly available, not
production-grade.** PostgreSQL always has a volume (`volumeClaimTemplates`, kept when the release is
uninstalled); Redis runs without persistence unless `redis.persistence.enabled` (the append-only file on a
volume). Both require a password and are `ClusterIP` only.

## Ingress and TLS

The Ingress is **disabled by default and sets no host**: nothing is published until you configure it
for your cluster, and the chart assumes no controller. It routes to the frontend only (the gateway
proxies `/api` and the job-log WebSocket to the backend).

```yaml
ingress:
  enabled: true
  className: <your ingress class>          # not assumed
  annotations: {}                          # what your controller needs
  hosts: [{host: <portal hostname>}]       # no hosts: the rule matches every host name
  tls: [{secretName: <tls secret>, hosts: [<portal hostname>]}]
```

The job-log WebSocket stays open for the whole dbt run, so most controllers need a long read timeout.
For ingress-nginx, for example:

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
```

**TLS** is terminated at the Ingress with a certificate Secret (`kubernetes.io/tls`) you create or that
cert-manager issues (`annotations: {cert-manager.io/cluster-issuer: <issuer>}`). Behind TLS the backend
trusts one proxy hop (`FORWARDED_HOPS=1`, automatic when the Ingress is enabled; set
`backend.forwardedHops` for more) and the session cookies become `Secure`. No Ingress yet? Use
`kubectl port-forward svc/dbt-portal-frontend 8080:8080`.

## Image pull credentials

For the private `ghcr.io` images, create a pull Secret and name it (a token with `read:packages`):

```bash
kubectl -n dbt-portal create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io --docker-username=<user> --docker-password=<token>
```

```yaml
imagePullSecrets: [{name: ghcr-pull}]
```

A mirrored registry: set `imageRegistry` (or `<component>.image.registry`). `imagePullPolicy`, a digest
(`<component>.image.digest`) and the per-component repository are all values.

## Storage

Three claims, deliberately independent (a class that suits one rarely suits all):

| Claim | Used by | Default | Notes |
|---|---|---|---|
| `workspace` | backend **and** every worker | RWX, 5Gi | The dbt project. The backend clones into it and the dbt editor saves files; workers run dbt in it and write `target/`, `logs/`, `dbt_packages/`. **The same claim for both.** |
| `data` | backend | RWO, 1Gi | The dbt editor's trash, Cube's state, the credentials key if `PORTAL_SECRET_KEY` were unset. |
| `backups` | backend | RWO, 5Gi | The portal's own backups; best on another class or one your cluster backs up elsewhere. `backups.persistence.enabled=false` removes it. |

The Compose worker also mounts the data volume; the chart's workers **do not by default**, because the data claim is
ReadWriteOnce and would tie every worker to the backend's node. The credentials key reaches the workers as
`PORTAL_SECRET_KEY` instead. If something the backend keeps in `/data` must be visible to the workers (a project
choice the Setup Assistant recorded there, a personal workspace in a development environment), give the data claim
a ReadWriteMany class and set `worker.mountData: true`.

Each takes `existingClaim`, `storageClass` (`""` = cluster default, `"-"` = no class), `accessModes`, `size`,
`annotations`. **ReadWriteMany is required for the workspace whenever the backend and workers can be
scheduled on different nodes** (Azure Files, EFS, Filestore, NFS...): with ReadWriteOnce they must all
share one node, which is only guaranteed on a one-node cluster. If you cannot offer RWX, run one node, or
pin the backend and workers to the same node with `nodeSelector`/`affinity`.

The claims carry `helm.sh/resource-policy: keep` (`persistence.retainOnUninstall`, default true), so
`helm uninstall` never deletes data; so does the created Secret, since a retained PostgreSQL volume needs
the password it was made with. `values-dev.yaml` turns this off. Deleting data is explicit:
`kubectl -n dbt-portal delete pvc -l app.kubernetes.io/instance=dbt-portal` (or `portal.sh --volumes
helm-uninstall`, which asks first).

## Security

Set on every workload, because the images support it (verified against their Dockerfiles):

* `automountServiceAccountToken: false` (the portal never calls the Kubernetes API), `seccompProfile:
  RuntimeDefault`, `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, all capabilities dropped.
* **uids** are the images' own, not invented: backend and worker `10001` (the image's `appuser`, a
  non-numeric `USER`, so Kubernetes needs the number; `fsGroup 10001` for the volumes); the frontend runs
  as nginx-unprivileged's numeric `USER 101`, so no uid is forced; Cube runs as `USER node` (not numeric),
  so the chart sets `1000`, the `node` user of the Node.js base image. **Verify it for the Cube image you
  pull:** `docker run --rm --entrypoint id <cube image>` (override `cube.podSecurityContext.runAsUser`).
  Bundled PostgreSQL runs as `70` (Alpine's `postgres`), Redis as `999:1000` (Alpine's `redis`): change them
  with the image.
* **No read-only root filesystem**: the backend entrypoint writes to the user's home, `/tmp` and the
  workspace; nginx renders its config into `/etc/nginx/conf.d` at start. `readOnlyRootFilesystem` is a
  value you can try per component.
* No secret in the frontend; Cube only `CUBE_API_SECRET`; `ClusterIP` Services only (enforced by the schema
  for the backend and Cube); no `hostPort`, `hostNetwork` or privileged container.
* **NetworkPolicy** (`networkPolicy.enabled`, on in `values-prod.yaml`) restricts *ingress*: the frontend
  accepts `networkPolicy.frontendFrom` (empty: anywhere, which an Ingress controller needs), the backend
  only the frontend and Cube (+ `backendFrom`, e.g. Prometheus), Cube only the backend, PostgreSQL and
  Redis only the backend and workers, the workers nobody. Egress is open (Git, the warehouse, AI
  providers). It needs a CNI that enforces NetworkPolicy; on one that does not the objects are ignored.

## Health probes

| Workload | Startup | Readiness | Liveness | What it proves |
|---|---|---|---|---|
| backend | `GET /api/health` (up to 5 min) | same | same | The API process answers. **Not** PostgreSQL, Redis or Cube. Startup is long because the entrypoint clones the project and runs `dbt deps` before uvicorn listens. |
| worker | `python -m app.worker --check` | none (no Service) | same | Redis answered a PING: the worker can reach its queue. **Not** that its loop is alive. Exec timeout is 10 s because it starts Python. |
| frontend | `GET /` | `GET /` | `GET /` | nginx serves the SPA. |
| cube | `/livez` | `/readyz` | `/livez` | Cube's process is up; `/readyz` gates traffic. |
| PostgreSQL (bundled) | `pg_isready` | `pg_isready` | `pg_isready` | The server accepts connections. |
| Redis (bundled) | `redis-cli ping` (authenticated through `REDISCLI_AUTH`) | same | same | Redis answers. |

Startup probes carry the slow first start so the liveness probe never restarts a pod that is still
cloning. Timings are values (`<component>.probes.*`, each probe can be `enabled: false`).

## Backups and restore

* **Automatic**: the portal writes an archive (database rows, `/data`, the workspace when it is the portal's
  own clone) every `BACKUP_INTERVAL_HOURS` (24) into the `backups` volume, keeping `BACKUP_KEEP` (14).
  `kubectl -n dbt-portal exec deploy/dbt-portal-backend -- python -m app.backup now|list`.
* A volume on the same cluster is not a backup. Also use **PostgreSQL's own backups** (managed snapshots,
  `pg_dump`), **volume snapshots** of the workspace and backups claims, and keep **`PORTAL_SECRET_KEY`** in
  your secret manager.
* **Restore** replaces the portal's data with an archive and wants the portal quiet. Procedure (not
  exercised here: try it on a copy first): scale the frontend, workers and backend so nothing writes,
  start the backend alone, restore, restart.
  ```bash
  kubectl -n dbt-portal scale deploy/dbt-portal-frontend deploy/dbt-portal-worker --replicas=0
  kubectl -n dbt-portal exec deploy/dbt-portal-backend -- python -m app.backup list
  kubectl -n dbt-portal exec deploy/dbt-portal-backend -- python -m app.backup restore latest
  kubectl -n dbt-portal rollout restart deploy/dbt-portal-backend
  kubectl -n dbt-portal scale deploy/dbt-portal-worker --replicas=2 && kubectl -n dbt-portal scale deploy/dbt-portal-frontend --replicas=2
  ```

## Upgrade, rollback, uninstall

```bash
# upgrade to a release (or your pinned tags): render, then upgrade
scripts/release-tags.sh --list
scripts/portal.sh helm-template --release 2026.10.19 --values deploy/helm/dbt-portal/values-prod.yaml --values my-prod.local.yaml
scripts/portal.sh helm-upgrade  --release 2026.10.19 --values deploy/helm/dbt-portal/values-prod.yaml --values my-prod.local.yaml

# roll back to the previous revision (or: helm history, then a number)
scripts/portal.sh helm-rollback
helm -n dbt-portal history dbt-portal

# uninstall: the claims (and the created Secret) stay
scripts/portal.sh helm-uninstall
scripts/portal.sh --volumes helm-uninstall     # ALSO deletes the claims, after you type 'delete data'
```

The backend rolls with the `Recreate` strategy (it owns a ReadWriteOnce volume), so it is briefly down
during an upgrade; the frontend and Cube roll without downtime. Backend and frontend must be upgraded
together across an API major (see the notes in releases.yml). A ConfigMap change restarts backend and
worker (checksum annotation); a change inside an **existing** Secret does not: `kubectl rollout restart`.
Upgrading a pre-2026.11 portal (separate identity/execution/insights/semantic databases): scale the old
Deployments to 0 and run [postgres/upgrade.sh](../postgres/upgrade.sh) once with `PGHOST` pointing at the
database before installing (it copies `portal_identity` and `portal_execution` into `portal`); the
semantic layer's warehouse login is entered again in the portal.

**Or let Helm do it** (`legacyMigration.enabled=true`): a hook Job runs a copy of that script
([files/upgrade.sh](../deploy/helm/dbt-portal/files/upgrade.sh); `scripts/validate.sh helm` fails if the
two differ) before the release is installed or upgraded. It copies `portal_identity` and
`portal_execution` into `portal`, keeps the old databases, and does nothing on a new install or once
moved, so it is safe to leave on. Turn it on only for a database the old portal used.

| Database | Runs on | Needs |
|---|---|---|
| bundled PostgreSQL | `helm upgrade` | nothing more (it uses the chart's Secret) |
| external | `helm install` and `helm upgrade` | `legacyMigration.database.host`, `legacyMigration.passwordSecret.name` (a Secret that **exists already**: the hook runs before the chart creates its own; key `POSTGRES_PASSWORD`), `database.user` if it is not `portal`; the target database must be called `portal` |

```bash
scripts/portal.sh helm-upgrade --values my-values.yaml \
  --set legacyMigration.enabled=true --set legacyMigration.database.host=db.internal \
  --set legacyMigration.passwordSecret.name=legacy-db-password
kubectl -n dbt-portal logs job/dbt-portal-legacy-migration   # a failed Job is kept; a successful one is removed
```

Only the database is moved: files on the old volumes (the dbt editor's trash, Cube's state) are not
(that is the Compose volume copy in the same script, skipped here because there is no `/data`). Scale the
old Deployments to 0 first, as above. The hook Job has no Kubernetes API access, runs as uid 70 with all
capabilities dropped, and is rendered and schema-checked by CI (`ci/legacy-migration-values.yaml`);
running it against a real old database is not part of CI.

## Cleanup

```bash
helm -n dbt-portal uninstall dbt-portal                                   # keeps volumes
kubectl -n dbt-portal get pvc,secret                                      # what is left
kubectl -n dbt-portal delete pvc -l app.kubernetes.io/instance=dbt-portal # DELETES the data
kubectl delete namespace dbt-portal                                       # everything, last
```

Rendered manifests (`helm template` output) can contain Secret data: never commit them
(`*.rendered.yaml` is git-ignored).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `an image tag is required` | Pass the tags: `portal.sh` does it; with `helm`, add `-f <(scripts/release-tags.sh --format helm-values)`. |
| `... is 'latest'` | Pin a release tag, or `allowLatestTag=true` for a throwaway install. |
| `secrets.existingSecret is required...` | `secrets.create=false` needs the Secret's name. |
| Pod `CreateContainerConfigError: couldn't find key X in Secret` | The Secret lacks a required key: [the table](#the-secret). |
| `ImagePullBackOff` | [image pull Secret](#image-pull-credentials), or the tag does not exist. |
| Backend stays `Running` but not `Ready` for minutes | First start: clone, `dbt deps`, migrations. `kubectl logs deploy/dbt-portal-backend`; the startup probe allows 5 minutes. |
| Workspace claim `Pending` | No class gives ReadWriteMany: set `workspace.persistence.storageClass`, or ReadWriteOnce on one node. |
| Workers cannot see the project | They must use the same workspace claim as the backend (the chart does); check `kubectl get pvc`. |
| WebSocket / long job logs drop | Raise the ingress read timeout (see Ingress). |
| `field is immutable` upgrading over a Kustomize install | The selectors changed: follow [the migration](#migrating-from-kustomize-to-helm). |
| NetworkPolicy blocks the Ingress | Add the controller's namespace to `networkPolicy.frontendFrom`, or leave it empty. |

## Migrating from Kustomize to Helm

`deploy/kubernetes` (Kustomize) was removed after the chart was rendered and compared with it, resource
by resource. Everything it did is represented; four things are **intentionally different**:

| Kustomize (`deploy/kubernetes`) | Helm chart | Equivalent or improved |
|---|---|---|
| `namespace.yaml` | `--create-namespace` | equivalent |
| ConfigMap `dbt-portal-config-<hash>` from `portal.env` | ConfigMap `dbt-portal-config` from `config.*`, `project.*` | equivalent; git URL/ref/user go to the backend only |
| Secret `dbt-portal-secrets-<hash>` from `secrets.env` | your Secret `dbt-portal-secrets`, or one the chart creates | equivalent, **plus** the required `PORTAL_SECRET_KEY` (the Kustomize workers never mounted `/data`, so a worker could not share the credentials key) |
| Deployments backend / worker / frontend / cube | same names | equivalent, plus startup probes, a worker exec timeout (the old probe had the 1 s default), `seccompProfile`, dropped capabilities, no service-account token |
| StatefulSet `dbt-portal-postgres`, Deployment `dbt-portal-redis`, Services | optional, same names; PostgreSQL claim `data-dbt-portal-postgres-0` is the same | equivalent; the schema keeps them ClusterIP |
| PVCs `dbt-portal-workspace`, `-data`, `-backups` | same names (adopt with `existingClaim`) | equivalent; storage class, size and mode configurable per claim |
| `images:` with stale `1.0.0` tags | tags required, from `releases.yml` | improved |
| `ingress.yaml` (ingress-nginx, a placeholder host) | optional, no host, no class assumed | **different**: disabled until configured |
| Cube Service exposed `sql` 15432 inside the cluster | only with `cube.service.sql.enabled` | **different**: least exposure by default |
| `FORWARDED_HOPS=1` always | `1` when the Ingress is enabled, else `0` | **different**: correct without an Ingress |
| selectors `app: dbt-portal, component: x` | `app.kubernetes.io/*` | **different**: Deployments cannot be upgraded in place from one to the other |

Because the selectors changed (they are immutable), you cannot `helm install` over live Kustomize
objects. Move across without touching the data:

1. **Back up**: `kubectl -n dbt-portal exec deploy/dbt-portal-backend -- python -m app.backup now`, a
   database dump, and a copy of the Secret.
2. **Save the credentials key.** If the old install never set `PORTAL_SECRET_KEY`, the backend made one
   in its data volume. Keep it, or the stored warehouse logins become unreadable:
   `kubectl -n dbt-portal exec deploy/dbt-portal-backend -- cat /data/secret.key`.
3. **Create the new Secret** from the old keys (your git-ignored `secrets.env`; the old template is in the
   git history of this repo) plus that key:
   ```bash
   kubectl -n dbt-portal create secret generic dbt-portal-secrets \
     --from-env-file=secrets.env --from-literal=PORTAL_SECRET_KEY="$(cat saved-secret.key)"
   ```
4. **Remove the old workloads but not the volumes.** Do **not** use `kubectl delete -k` (it deletes the
   claims): `kubectl -n dbt-portal delete deploy,svc,sts -l app=dbt-portal` (a StatefulSet's claims are
   kept), then the Ingress, the ConfigMap and the hashed Secret by name (they carry no `app` label):
   `kubectl -n dbt-portal delete ingress dbt-portal`, and `kubectl -n dbt-portal get cm,secret` to find the rest.
5. **Install with the existing claims:**
   ```yaml
   # my.local.yaml
   secrets: {create: false, existingSecret: dbt-portal-secrets}
   workspace: {persistence: {existingClaim: dbt-portal-workspace}}
   data:      {persistence: {existingClaim: dbt-portal-data}}
   backups:   {persistence: {existingClaim: dbt-portal-backups}}
   project: {source: git, git: {url: <the old DBT_PROJECT_GIT_URL>, ref: <the old ref>}}
   postgresql: {enabled: true}   # only if you used the bundled one: same password, same claim
   redis: {enabled: true}
   ```
   `scripts/portal.sh helm-install --values deploy/helm/dbt-portal/values-prod.yaml --values my.local.yaml`
6. Check the portal, then remove the leftovers.

The former `portal.env` keys map to values: `ENVIRONMENT` → `config.environment`, `DBT_TARGET` →
`config.dbtTarget`, `DBT_DEPS_ON_START` → `config.dbtDepsOnStart`, `DBT_PROJECT_GIT_*` → `project.git.*`,
`DBT_PROJECT_SUBDIR` → `project.subdir`, `DBT_PROFILES_DIR=/etc/dbt` → `project.profiles.existingSecret`,
anything else (`AIRFLOW_URL`...) → `config.extra`.

## Supported versions

Nothing is declared. Chart `Chart.yaml` has **no `kubeVersion`**; it uses only `apps/v1`, `v1`,
`networking.k8s.io/v1` and `policy/v1`. Record what you ran it on:

| | Version | Tested how |
|---|---|---|
| Kubernetes | _to record_ | |
| Helm | _to record_ (rendered with 3.16.4) | `scripts/validate.sh helm` |
| Schema check | kubeconform against 1.28, 1.31 (and 1.33 in CI) | rendering only, no cluster |
| Ingress controller / CNI / storage class | _to record_ | |
