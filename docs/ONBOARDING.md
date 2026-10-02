# Onboarding a client onto the dbt Portal

This portal is generic. It never hard-codes a client's dbt project, warehouse
or infrastructure, and its images carry no client-specific config. To
onboard a new client you choose **where their dbt project lives** and
**how it reaches the portal**, and that's it. Warehouse credentials need no
separate setup: the services' entrypoint reads them from the client's own
project `.env`, the file next to their `profiles.yml` that the project needs
anyway. Pointing the stack at a project is normally the whole setup.

The portal runs as separate services, each in its own container, released
from three repos (how they fit together: [ARCHITECTURE.md](ARCHITECTURE.md)):

| Image | From | Runs |
|---|---|---|
| `capgemini-dbt-portal-backend` | [backend repo](https://github.com/omaryehia015/capgemini-dbt-portal-backend) | every service in one process (single node), or the **execution** API and its **workers** |
| `capgemini-dbt-portal-identity` / `-insights` / `-semantic` | backend repo | one service each |
| `capgemini-dbt-portal-frontend` | [frontend repo](https://github.com/omaryehia015/capgemini-dbt-portal-frontend) | the SPA and the gateway (nginx) |
| `capgemini-dbt-portal-cube` | [cube repo](https://github.com/omaryehia015/capgemini-dbt-portal-cube) | the semantic engine |

This repo holds what runs them together: the compose files, the client
kit, Kubernetes manifests, and [releases.yml](../releases.yml), which says
which versions of the three repos are released together.

**Shipping this to a client?** They don't need any of the repos. They get
the client kit ([deploy/client/README.md](../deploy/client/README.md)):
pre-built images, `compose.yaml` and a setup script that writes the secrets
and starts everything.

## Fastest path: one script

For a single laptop or VM, the dbt package's script runs the single-node
portal (every backend service in one container, SQLite, no Redis):
[capgemini_dbt_core/scripts/portal.py](https://github.com/omaryehia015/capgemini_dbt_core/blob/main/scripts/portal.py).
It is one file (Python 3.8+, standard library only) and behaves the same on Windows, macOS
and Linux. The client needs Docker or Podman and nothing else, because dbt runs inside the
image. Once the package is installed, the script is also at
`dbt_packages/capgemini_dbt_core/scripts/portal.py`.

```bash
python portal.py onboard     # from the dbt project folder, or with --project <folder>
python portal.py refresh     # daily upkeep; onboard schedules it (Task Scheduler / cron)
python portal.py status      # project, URL, schedule, last refresh, onboarding steps
python portal.py stop        # stop this project's portal and its schedule (data is kept)
```

`onboard` finds the dbt project, including a sub-folder of a monorepo, and its
`profiles.yml`, including `~/.dbt` and `DBT_PROFILES_DIR`, which it mounts read-only at
`/profiles`. It adds `capgemini_dbt_core` to `packages.yml` if it is missing and writes
missing credentials to the project's `.env`. Then it pulls the images (one portal release,
`--release`, or per-image tags) and starts a portal instance just for that project, with
its own containers, volume and a free port. It confirms that `/api/onboarding/status`
reports the same `project_name`, runs the steps below through the API and schedules
`refresh`. Proxies (`HTTP(S)_PROXY`), a corporate CA (`--ca-cert`), mirrors
(`--registry`/`--tag`) and offline machines (`--no-pull`) are covered.

The script uses only the API (`/api/auth/*`, `/api/onboarding/*`, `/api/jobs/*`) and the
container contract (`DBT_PROJECT_DIR`, `DBT_PROFILES_DIR`, `/data`, `CUBE_API_SECRET`, the
`GENERATED INITIAL CREDENTIALS` log banner). Changing any of these breaks client installs,
so update the script in capgemini_dbt_core in the same backend release.

The same steps are available later in the portal's **Onboarding** page:

| Step | Done when | What running it does |
|---|---|---|
| Connect | project, profile, credentials and dbt are present | `dbt debug` (logs in to the warehouse) |
| Install packages | every package in `package-lock.yml` is in `dbt_packages/` | `dbt deps` (retries transient mount errors) |
| Provision database | the metadata database has every package schema | `dbt run-operation grant_package_access` |
| Build observability | Elementary tables exist | `dbt run -s elementary` (+ FinOps if installed), then `dbt test --select package:<project>` (failures don't fail the step) |
| Generate reports | docs, Colibri and Elementary report exist | docs + Colibri + `edr report` |

*Provision* is limited to users with `governance.manage` (the Admin role).

Read order: [1. What "onboarding" means here](#1-what-onboarding-means-here) →
pick your path in [2](#2-pick-a-deployment-path) → do the steps in that
path's section → [6. Every environment variable](#6-every-environment-variable-reference)
as a reference while you fill in `.env` → [7](#7-verify-the-install) to confirm it worked.

## 1. What "onboarding" means here

Two independent things point the portal at a specific client:

1. **Where the dbt project's files are**: a host folder, a git repo, a
   Kubernetes volume, or baked into the image. See "How the client's dbt
   project gets into the containers" below.
2. **Where dbt should run it**: the Snowflake (or other warehouse) account,
   plus which `profiles.yml` target. Section 4.

Everything else (secrets, databases, accounts) is the same shape for every
client and is covered in sections 5 and 6.

The services resolve the project path with this precedence (unchanged from
the original Streamlit portal, so client `profiles.yml`/scripts that already
depend on it keep working): **`DBT_PROJECT_DIR`** → **`WORKSPACE_ROOT`** →
**`PROJECT_ROOT`** → the first parent of the working directory containing
`dbt_project.yml` → the backend's own parent directory. See the backend
repo's [app/core/config.py](https://github.com/omaryehia015/capgemini-dbt-portal-backend/blob/main/app/core/config.py).

## 2. Pick a deployment path

| Client's setup | Path | What runs |
|---|---|---|
| A team, a shared server: the normal case | [E: Client kit](#e-client-kit-microservices-compose) | the microservices stack (compose), PostgreSQL, Redis |
| Kubernetes cluster (their own or managed) | [B: Kubernetes](#b-kubernetes) | the microservices stack, scaled per service |
| One laptop, a demo, a very small team | [A: Single node](#a-single-node) | one backend container (all services), SQLite |
| You, developing across the repos | [F: From source](#f-from-source-the-three-repos-side-by-side) | the microservices stack, built locally |
| dbt project already ships as a container image | [C: Bake the project into the image](#c-bake-the-project-into-the-image) | either of the above, with a baked backend image |
| Plain Linux VM, no containers allowed | [D: Bare VM (systemd + nginx)](#d-bare-vm-systemd--nginx) | single node, no semantic engine |

All of them run the same code and read the same environment variables
(section 6). They differ in how those variables are set, how the project's
files reach `/workspace`, and whether the services run together or apart.

**Single node or microservices?** Both run the same images. The single-node
setup keeps every backend service in one process on SQLite: simple, but one
heavy dbt run shares CPU with every user's page loads, and it cannot scale
past one container. The microservices stack runs dbt on separate **workers**
behind a job queue, keeps users and history in PostgreSQL, and lets each
service scale on its own. Use it for anything more than one or two users. An
existing single-node portal moves over with its data: see
[section 9, "From single node to microservices"](#from-single-node-to-microservices).

### How the client's dbt project gets into the containers (any path)

Three interchangeable options; pick one per client:

- **Mount**: a host path (`DBT_PROJECT_PATH`, compose) or a cluster volume
  is mounted at `/workspace`. Nothing to build; the client's own CI/CD or a
  colleague keeps the folder up to date. Best when the client already
  deploys dbt this way (e.g. an existing Airflow worker image with the
  project on a shared volume).
- **Git**: set `DBT_PROJECT_GIT_URL` (+ `DBT_PROJECT_GIT_REF`, and
  `DBT_PROJECT_GIT_TOKEN` for private repos). The execution container's
  entrypoint clones it on first start and fast-forwards it on every restart;
  the other services mount the same volume (workers read-write, insights and
  semantic read-only). Best default for a client with a git repo and no
  existing deployment pattern.
- **Bake**: the project is `COPY`'d into the backend image at build time
  ([deploy/bake/Dockerfile](../deploy/bake/Dockerfile)). Best when the client
  already versions their dbt project as an image and wants the portal
  version-locked to a specific project release.

`DBT_PROJECT_SUBDIR` handles a monorepo in any of the three (the dbt project
is a sub-folder of what got mounted/cloned/baked).

---

### E. Client kit (microservices, compose)

The deliverable for a client: the published images, [compose.yaml](../compose.yaml),
[.env.example](../.env.example), [releases.yml](../releases.yml) and the setup
scripts, packaged by the [client kit workflow](../.github/workflows/client-kit.yml)
as `dbt-portal-client-kit-<release>.zip` (walkthrough:
[deploy/client/README.md](../deploy/client/README.md)).

```bash
./setup.sh /path/to/their-dbt-project --release 2026.10.0      # Windows: .\setup.ps1 -Project ... -Release ...
```

The script writes `.env` with generated secrets (`JWT_SECRET`,
`CUBE_API_SECRET`, `POSTGRES_PASSWORD`, `REDIS_PASSWORD`), the project path and
the release's image tags; pulls the images; starts the stack; and prints the
first-login passwords. Running it again keeps the secrets, so it is also how
a client upgrades (`--release <newer>`) or moves the port. By hand, the same
install is:

```bash
cp .env.example .env     # set DBT_PROJECT_PATH (or the git block) and the four secrets
docker compose up -d
docker compose logs identity | grep -A6 "GENERATED INITIAL CREDENTIALS"
```

No source checkout, no build, no Python/Node/dbt on their machine. If their
infrastructure is Kubernetes, use path B with the same image tags.

**Scaling on one host.** `docker compose up -d --scale worker=3` runs three
dbt workers (each runs `WORKER_CONCURRENCY` jobs at once, 4 by default).
Everything else is sized for a team as is; for more, move to Kubernetes.

**Publishing images.** Each repo publishes its own: `git tag v1.4.0 && git
push --tags` in that repo builds, scans and pushes `1.4.0`, `1.4` and `latest`
(pushes to `dev`/`test`/`main` publish `<env>-<sha>` tags). When a combination
passes this repo's e2e smoke test, add it to `releases.yml`. First time only:
make the GHCR packages public, or give clients a `docker login ghcr.io`
read-only token, or `docker compose pull` fails with a 401.

### A. Single node

Every backend service in one container, SQLite, no Redis: the
[portal.py script](#fastest-path-one-script) does this per project, or by hand:

```bash
cp .env.example .env     # DBT_PROJECT_PATH and CUBE_API_SECRET are enough here
docker compose -f compose.single.yaml up -d
docker compose -f compose.single.yaml logs backend | grep -A6 "GENERATED INITIAL CREDENTIALS"
```

`JWT_SECRET` may stay empty on a single node: the backend generates one on
first start and keeps it on the `portal_data` volume.

**Mount mode**: set `DBT_PROJECT_PATH` to the project folder, relative to the
compose file (e.g. `../capgemini_dbt_core`). Podman's Windows client mangles
absolute `/mnt/c/...` paths, so keep it relative. **Git mode**: leave
`DBT_PROJECT_PATH` unset and set `DBT_PROJECT_GIT_URL` (and
`DBT_PROJECT_GIT_REF`, `DBT_PROJECT_GIT_TOKEN` if private); the project lands
in the `workspace` named volume.

`podman compose` needs a compose provider: `pip install --user podman-compose`
(add its `Scripts` dir to `PATH`), or Docker's `docker-compose` binary on `PATH`.

### F. From source: the three repos side by side

```
work/
  capgemini-dbt-portal-backend/
  capgemini-dbt-portal-frontend/
  capgemini-dbt-portal-cube/
  capgemini-dbt-portal-deploy/      <- run compose from here
```

```bash
cd capgemini-dbt-portal-deploy
cp .env.example .env     # project path + the four secrets (openssl rand -base64 36)
docker compose -f compose.yaml -f compose.build.yaml up --build -d
```

[compose.build.yaml](../compose.build.yaml) builds every image from the
sibling checkouts instead of pulling them. For a quicker loop on one repo,
see that repo's README (the backend runs every service with `uvicorn
app.main:app`; the frontend's `npm run dev` proxies to it).

### B. Kubernetes

Manifests: [deploy/kubernetes/](../deploy/kubernetes/) (kustomize).

```bash
cd deploy/kubernetes
cp secrets.env.example secrets.env      # secrets, database/Redis URLs, warehouse creds, git token
$EDITOR portal.env                      # DBT_PROJECT_GIT_URL/REF, DBT_TARGET
$EDITOR kustomization.yaml              # image tags: one release from releases.yml
kubectl apply -k .
kubectl -n dbt-portal logs deploy/dbt-portal-identity | grep -A6 "GENERATED INITIAL CREDENTIALS"
```

Notes specific to Kubernetes:

- **What scales.** identity, insights, the execution API and the frontend are
  stateless: raise `replicas` freely. dbt runs on the **worker** Deployment;
  add workers for more concurrent runs. semantic runs one replica (it writes
  the Cube model as files); Cube itself is stateless.
- **PostgreSQL and Redis.** [data-stores.yaml](../deploy/kubernetes/data-stores.yaml)
  runs one pod of each so the stack works anywhere. For production, use the
  platform's managed services: drop the file from `kustomization.yaml` and set
  `DATABASE_URL_IDENTITY`, `DATABASE_URL_EXECUTION` and `REDIS_URL` in
  `secrets.env`. Create the `portal_identity` and `portal_execution`
  databases there first ([postgres/init-databases.sql](../postgres/init-databases.sql)).
- **Project source.** The workspace is one `ReadWriteMany` volume
  ([workspace.yaml](../deploy/kubernetes/workspace.yaml)): the execution API
  clones into it in git mode, workers run dbt in it, insights and semantic
  read it. Pods spread over several nodes need an RWX storage class (Azure
  Files, EFS, Filestore, NFS); a single-node cluster can use RWO.
- **`profiles.yml` as a Secret** instead of committed with `env_var()`:
  `kubectl create secret generic dbt-profiles --from-file=profiles.yml -n dbt-portal`,
  mount it at `/etc/dbt` in the execution, worker, insights and semantic
  Deployments, and set `DBT_PROFILES_DIR=/etc/dbt` in `portal.env`.
- **Ingress** in `ingress.yaml` is an ingress-nginx example; adapt to the
  client's ingress controller. No ingress available yet? `kubectl port-forward
  svc/dbt-portal-frontend 8080:8080` and open `http://localhost:8080`.
- **Images**: mirror them to the client's registry if needed and set
  `newName`/`newTag` in `kustomization.yaml`'s `images:` block.

### C. Bake the project into the image

For a client who already publishes their dbt project as (or alongside) a
container image:

```bash
docker build -f deploy/bake/Dockerfile \
  --build-arg PORTAL_BACKEND_IMAGE=ghcr.io/omaryehia015/capgemini-dbt-portal-backend:1.0.0 \
  --build-arg CLIENT_DBT_IMAGE=registry.client.com/analytics/dbt:2.3.0 \
  --build-arg CLIENT_PROJECT_PATH=/usr/app/dbt \
  -t registry.client.com/analytics/dbt-portal-backend:2.3.0 .
```

Then use that image for the execution and worker containers (or the single
backend container) with **no** `DBT_PROJECT_PATH`/`DBT_PROJECT_GIT_URL` set:
the project is already at `/workspace`. Insights and semantic read the
project too, so bake it into their images the same way (`PORTAL_BACKEND_IMAGE`
= the insights or semantic image).

### D. Bare VM (systemd + nginx)

For a client that won't run containers at all: single node, without the
semantic engine (Cube runs only as a container). Needs Python 3.11+, Node 22
(build-time only), nginx.

```bash
git clone https://github.com/omaryehia015/capgemini-dbt-portal-backend /opt/dbt-portal-backend
cd /opt/dbt-portal-backend
python -m venv .venv && .venv/bin/pip install -r requirements.txt -c constraints.txt

# Get the client project onto the box:
git clone <client-repo> /opt/dbt-portal-project      # git mode, manual
#  - or rsync/scp an existing checkout to the same path
#  - or point DBT_PROJECT_DIR at wherever the client's own deploy already puts it

sudo useradd --system --home /opt/dbt-portal-backend dbtportal
sudo mkdir -p /etc/dbt-portal /data
sudo cp <this repo>/.env.example /etc/dbt-portal/portal.env    # KEY=VALUE, no quotes
echo "DBT_PROJECT_DIR=/opt/dbt-portal-project" | sudo tee -a /etc/dbt-portal/portal.env
echo "DATABASE_URL=sqlite:////data/portal.db"   | sudo tee -a /etc/dbt-portal/portal.env
echo "PORTAL_DATA_DIR=/data"                    | sudo tee -a /etc/dbt-portal/portal.env
sudo chown -R dbtportal /opt/dbt-portal-backend /opt/dbt-portal-project /data

.venv/bin/python -m app.preflight   # check before wiring up systemd
sudo cp <this repo>/deploy/vm/dbt-portal-backend.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now dbt-portal-backend

git clone https://github.com/omaryehia015/capgemini-dbt-portal-frontend /opt/dbt-portal-frontend
cd /opt/dbt-portal-frontend && npm ci && npm run build
sudo mkdir -p /var/www/dbt-portal && sudo cp -r dist/* /var/www/dbt-portal/
sudo cp <this repo>/deploy/vm/nginx-dbt-portal.conf /etc/nginx/conf.d/dbt-portal.conf
sudo nginx -t && sudo systemctl reload nginx
```

For git-mode auto-update on this path, run the backend's
`docker-entrypoint.sh` clone/fetch logic yourself in a cron job or a `git
pull` step in your deploy script: the systemd unit doesn't run it.

## 3. Cross-cutting: how requests reach each service

The frontend container is the gateway. Its nginx
([nginx/default.conf.template](https://github.com/omaryehia015/capgemini-dbt-portal-frontend/blob/main/nginx/default.conf.template))
serves the SPA and routes each `/api` prefix to the service that owns it:

| Prefix | Service | Upstream variable |
|---|---|---|
| `/api/auth`, `/api/governance` | identity | `IDENTITY_UPSTREAM` |
| `/api/elementary`, `/api/sqlfluff`, `/api/profiler`, `/api/assets`, `/api/finops`, `/api/insights`, `/api/ask-ai` | insights | `INSIGHTS_UPSTREAM` |
| `/api/semantic` | semantic | `SEMANTIC_UPSTREAM` |
| everything else under `/api`, including the job log WebSocket | execution | `EXECUTION_UPSTREAM` |

Each defaults to `BACKEND_UPSTREAM` (default `backend:8000`), so a single-node
install sets nothing. Per deployment:

- Compose: [compose.yaml](../compose.yaml) sets all four to the service names.
- Kubernetes: [frontend.yaml](../deploy/kubernetes/frontend.yaml) sets them to the Service names.
- Bare VM: [deploy/vm/nginx-dbt-portal.conf](../deploy/vm/nginx-dbt-portal.conf)
  proxies everything to `127.0.0.1:8000` (one process).
- Local frontend development (`npm run dev`): Vite's dev proxy sends `/api`
  to `VITE_API_PROXY_TARGET` (default `http://127.0.0.1:8123`), an all-in-one backend.

Services call each other only on their `/internal` API (never proxied by the
gateway), authenticated with a short-lived token signed with the shared
`JWT_SECRET`. Cube reads its configuration from the semantic service's
`/internal/cube` API with `CUBE_API_SECRET`. Both are covered in
[ARCHITECTURE.md](ARCHITECTURE.md).

## 4. Warehouse credentials and the dbt profile

The portal never talks to the warehouse directly except through dbt and a
thin Snowflake metadata browser ([app/services/snowflake.py](https://github.com/omaryehia015/capgemini-dbt-portal-backend/blob/main/app/services/snowflake.py)).
Both read the **same** environment variables, so one set of credentials
covers dbt runs and the in-portal warehouse pages:

`DBT_PKG_ACCOUNT`, `DBT_PKG_USER`, `DBT_PKG_PASSWORD`, `DBT_PKG_ROLE`,
`DBT_PKG_WAREHOUSE`, `DBT_PKG_DATABASE` (legacy `DBT_SNOWFLAKE_*` /
`SNOWFLAKE_*` names are also read, in that order, for clients whose existing
`profiles.yml` already used them).

**You almost never set these yourself.** The backend images' [docker-entrypoint.sh](https://github.com/omaryehia015/capgemini-dbt-portal-backend/blob/main/docker-entrypoint.sh)
loads the mounted/cloned project's own `.env` (whatever sits next to its
`profiles.yml`) into the container before starting anything, filling in only
what isn't already set some other way. A client's dbt project already has to
carry these credentials somewhere to run `dbt` on its own — the portal just
reads that same file, so there is normally nothing warehouse-related to
configure at the portal level at all. An explicit env var on the container
(compose `environment:`, `-e`, a Kubernetes Secret) still overrides whatever
the project's `.env` says, for the rare case a deployment needs to differ
from the project's own defaults (e.g. a staging target with different creds).

**This depends on the project actually having that `.env` file at runtime**,
which mount and git mode do NOT equally guarantee:

- **Mount mode**: almost always works with zero extra config. The client's
  `.env` already sits on disk next to `profiles.yml` (git-ignored, never
  committed), and it's simply part of what gets bind-mounted.
- **Git mode**: only works if that `.env` is actually committed to the repo
  the container clones — unusual and not recommended (it puts plaintext
  warehouse credentials in git history). The normal git-mode setup instead
  supplies the same variables through whatever secret-management the
  deployment target already has — `secrets.env` for the standalone scripts,
  a Kubernetes `Secret` (path B), `.env` next to the client compose file
  (path E) — which reach the containers the same way and are just as
  overridable, they're just supplied by the deployer instead of read off disk.

**The client's `profiles.yml` must read these through `env_var()`**, not
hard-code credentials — that's what makes the same image portable across
clients:

```yaml
default:
  target: "{{ env_var('DBT_TARGET', 'dev') }}"
  outputs:
    dev:
      type: snowflake
      account: "{{ env_var('DBT_PKG_ACCOUNT') }}"
      user: "{{ env_var('DBT_PKG_USER') }}"
      password: "{{ env_var('DBT_PKG_PASSWORD') }}"
      role: "{{ env_var('DBT_PKG_ROLE', 'DBT_TRANSFORMER_ROLE') }}"
      warehouse: "{{ env_var('DBT_PKG_WAREHOUSE', 'TRANSFORMING_WH') }}"
      database: "{{ env_var('DBT_PKG_DATABASE', 'METADATA_ANALYTICS') }}"
      schema: analytics
      threads: 4
```

Where `profiles.yml` lives:

1. `DBT_PROFILES_DIR`, if set and it exists.
2. `profiles.yml` committed in the project root (the `env_var()` pattern
   above makes this safe — no secret is in the file).
3. `~/.dbt/profiles.yml` inside the container.

**A different warehouse** (BigQuery, Redshift, Postgres, Databricks, ...):
add that adapter to the backend image (execution, workers, single node) with the `EXTRA_PIP_PACKAGES` build arg
— `podman build --build-arg EXTRA_PIP_PACKAGES="dbt-bigquery~=1.8.0" .` in the backend repo
(compose.build.yaml: set `EXTRA_PIP_PACKAGES` in `.env`) — and write `profiles.yml`
accordingly. `snowflake.py`'s pages will no-op for non-Snowflake clients
(`is_configured()` returns false); nothing else assumes Snowflake.

**Multiple targets** (dev/staging/prod): set `DBT_TARGET` per deployment. It
overrides the profile's own `target:` key without touching the file.

## 5. Portal accounts and RBAC

Four seeded roles (Admin, Data Engineer, Data Analyst, Auditor; see the
backend's [app/db/seed.py](https://github.com/omaryehia015/capgemini-dbt-portal-backend/blob/main/app/db/seed.py))
exist from first start, stored in the identity service's database, editable
afterward from the Governance page.

- `ENVIRONMENT=production` (the default) generates a random password per
  account and prints it once in the identity log (`docker compose logs
  identity`, `kubectl logs deploy/dbt-portal-identity`; on a single node, the
  backend log). Capture it there, or pre-set `SEED_ADMIN_PASSWORD` etc. before
  first start. The identity service refuses to start if one of those is set
  to a documented demo password.
- `ENVIRONMENT=development` seeds the documented passwords (`admin123!` etc.):
  for a local demo only, never for anything a client can reach.
- `JWT_SECRET`: every service verifies the same session tokens with it, so a
  split deployment sets one value for all of them (the setup script generates
  it). A single node may leave it unset: the entrypoint generates one and keeps
  it on the data volume.

## 5a. Data ingestion with Airbyte (optional)

The portal covers transform, test, document and serve. For the step before
that — getting source data (Salesforce, Postgres, S3, Stripe, 300+ others)
into the warehouse's raw schemas — it connects to an **Airbyte** instance
running next to it. Airbyte is free to self-host; the client runs it on their
own server for their own data.

**Why it is not in `compose.yaml`:** since 1.0, Airbyte installs only with its
own tool, `abctl` (it runs a small Kubernetes cluster inside one Docker
container, because every sync starts its own connector container). It still
runs on the same Docker host as the portal — it is just started by a
different command.

1. **Install Airbyte** on the portal's server (about 4 CPUs / 8 GB RAM extra):

   ```bash
   curl -LsfS https://get.airbyte.com | bash -
   abctl local install --host <server-hostname>   # UI + API on port 8000
   abctl local credentials                        # prints client-id / client-secret
   ```

   `--host` must be the name users (and the portal) use to reach it; Airbyte's
   ingress answers 404 to any other host name. Kubernetes clients install the
   official Helm chart instead; Airbyte Cloud works too
   (`AIRBYTE_URL=https://api.airbyte.com/v1`).

2. **Point the portal at it** in `.env`:

   ```bash
   AIRBYTE_URL=http://host.docker.internal:8000   # Podman: host.containers.internal
   AIRBYTE_CLIENT_ID=<client-id>
   AIRBYTE_CLIENT_SECRET=<client-secret>
   AIRBYTE_UI_URL=http://<server-hostname>:8000   # link users' browsers open
   ```

   On Linux with Docker Engine (not Desktop), `host.docker.internal` needs
   `extra_hosts: ["host.docker.internal:host-gateway"]` on the backend
   execution service — or use the server's hostname/IP directly in `AIRBYTE_URL`.
   Then `docker compose up -d execution`.

3. **Check it** on **Tools & Services** (sidebar → Workspace): the Airbyte
   card turns green once the URL is reachable and the credentials work. The
   **Airbyte** page (sidebar → Ingestion) lists connections with their last
   sync, sync history, and *Sync now* / cancel. Sources, destinations and
   connections are created in Airbyte's own UI (its connector forms come from
   each connector's spec).

**Scheduling:** set a connection's schedule to *Manual* in Airbyte when the
portal or Airflow will trigger it, so it never runs twice. Access follows the
`airflow.manage` permission ("Orchestration & Ingestion": Admin and Data
Engineer by default), and every sync and cancel lands in the audit trail.
## 6. Every environment variable (reference)

Full template with inline comments: [.env.example](../.env.example). Grouped
here by what they control; the backend's `app/core/config.py`,
`app/services/dbt_context.py`, `app/services/project_paths.py` and
`app/services/snowflake.py` are the source of truth.

**Topology** (set by compose.yaml / the Kubernetes manifests, rarely by hand):

| Variable | Default | Purpose |
|---|---|---|
| `PORTAL_SERVICES` | the image's service (`all` for the backend image) | Which services this container serves: `all`, or a comma list of `identity`, `execution`, `insights`, `semantic`. |
| `IDENTITY_URL` / `EXECUTION_URL` / `INSIGHTS_URL` / `SEMANTIC_URL` | — | Where the services a container does not host are reached (`http://identity:8000` ...). Required for every service a container calls but does not host. |
| `EXECUTION_ROLE` | `all` | Execution only. `api`: serve the API and queue dbt jobs for workers (needs `REDIS_URL`). `all`: run jobs in-process (single node). Workers run `python -m app.worker`. |
| `WORKER_CONCURRENCY` | `4` | dbt jobs one worker runs at once. |
| `REDIS_URL` | — | Job queue, live job logs across replicas, cache invalidation, email sign-in codes. Unset: all in-process (single node only). |
| `DATABASE_URL` | `sqlite:////data/portal.db` | This service's database. identity → `portal_identity`, execution and workers → `portal_execution` (`postgresql+psycopg2://...`). SQLite is for a single node. Schema changes are applied on start (Alembic). |
| `JWT_SECRET` | generated (single node only) | Session signing key, the same for every service. Also signs service-to-service calls. |
| `CUBE_API_SECRET` | generated (single node only) | Shared by the semantic service and Cube (Cube's `CUBEJS_API_SECRET`). |
| `CUBE_API_URL` | `http://cube:4000` | Where the semantic service reaches Cube. |
| `PORTAL_SEMANTIC_URL` | `http://semantic:8000` | Cube container: where it reads its configuration (single node: `http://backend:8000`). |
| `IDENTITY_UPSTREAM` / `EXECUTION_UPSTREAM` / `INSIGHTS_UPSTREAM` / `SEMANTIC_UPSTREAM` / `BACKEND_UPSTREAM` | `backend:8000` | Frontend container: where the gateway sends each `/api` prefix (section 3). |
| `PORTAL_DATA_DIR` | `/data` in the images | Files a service keeps outside its database: the semantic layer's state, the dbt editor's trash, a single node's SQLite file. |
| `BACKEND_TAG` / `FRONTEND_TAG` / `CUBE_TAG` / `IMAGE_REGISTRY` | `latest` / `ghcr.io/omaryehia015` | Compose: which images to run. Take them from one release in `releases.yml`. |

**The dbt project and the warehouse:**

| Variable | Default | Purpose |
|---|---|---|
| `DBT_PROJECT_DIR` / `WORKSPACE_ROOT` / `PROJECT_ROOT` | walk-up from cwd | Where the dbt project is, in that precedence order. Compose sets `DBT_PROJECT_DIR=/workspace` for you. |
| `DBT_PROJECT_PATH` | — | Compose-only: host path mounted at `/workspace` (mount mode). |
| `DBT_PROJECT_GIT_URL` | — | Git mode: repo the execution container clones into the workspace. |
| `DBT_PROJECT_GIT_REF` | `main` | Branch/tag to clone and track. |
| `DBT_PROJECT_GIT_TOKEN` / `DBT_PROJECT_GIT_USERNAME` | — | Auth for a private repo (HTTPS). Username defaults to `x-access-token` (GitHub PAT); use `oauth2` for GitLab. |
| `DBT_PROJECT_SUBDIR` | — | dbt project is a sub-folder of the mount/clone (monorepo). |
| `DBT_DEPS_ON_START` | `false` | Run `dbt deps` in the entrypoint before the server starts (execution / single node). |
| `DBT_PROFILES_DIR` | project root, then `~/.dbt` | Where `profiles.yml` lives, if not the project root. |
| `DBT_EXECUTABLE_PATH` | auto-detected | Explicit path to the `dbt` binary; only needed for an unusual layout. |
| `DBT_TARGET` | profile's own `target:` | Which `profiles.yml` output to run against. |
| `EXTRA_PIP_PACKAGES` | — | Backend image **build arg**: extra pip packages (a different adapter, a pinned dbt version). |
| `DBT_PKG_ACCOUNT` / `_USER` / `_PASSWORD` / `_ROLE` / `_WAREHOUSE` / `_DATABASE` | — | Warehouse credentials, read by both `profiles.yml` (via `env_var`) and the portal's Snowflake pages. |

**Sessions and accounts:**

| Variable | Default | Purpose |
|---|---|---|
| `JWT_EXPIRES_MINUTES` | `480` | Lifetime of `Authorization: Bearer` tokens minted for scripts. Browser sessions use the two settings below. |
| `ACCESS_TOKEN_MINUTES` | `15` | Browser access cookie lifetime; renewed silently before it expires. |
| `REFRESH_TOKEN_DAYS` | `7` | How long a browser stays signed in without activity. Rotated on every renewal; revoked on logout, account disable and password reset. |
| `COOKIE_SECURE` | automatic | Force the Secure flag on session cookies on (`true`) or off (`false`). Unset: Secure when the request arrived over HTTPS (directly or with `X-Forwarded-Proto: https`). |
| `ENVIRONMENT` | `production` | Gates the JWT-secret check and seed-password behavior above. `development` only for local demos. |
| `SEED_ADMIN_PASSWORD` / `SEED_ENGINEER_PASSWORD` / `SEED_ANALYST_PASSWORD` / `SEED_AUDITOR_PASSWORD` | dev defaults, else random | Initial password for each seeded account. |
| `CORS_ORIGINS` | `["http://localhost:5173"]` | Only relevant if the frontend is served from a different origin than the API (not the case for any setup above: the gateway serves both). |

**Operations and integrations:**

| Variable | Default | Purpose |
|---|---|---|
| `LOG_LEVEL` / `LOG_FORMAT` | `INFO` / `json` | Logging. `json` writes one object per line with a `request_id`; `text` is easier to read on a laptop. |
| `METRICS_ENABLED` | `true` | Prometheus metrics at `/metrics` on each service's port (not proxied by the gateway, so internal only). |
| `SCHEDULER_ENABLED` | `true` | Fire dbt Runner schedules. Runs on the workers (or the single node); safe with several, each slot is claimed once in the database. |
| `NOTIFY_SLACK_WEBHOOK` / `NOTIFY_TEAMS_WEBHOOK` / `NOTIFY_EMAIL_TO` | — | Default failure-alert channels. Admins can change them at runtime (Governance → Failure alerts); the stored values win. |
| `PORTAL_BASE_URL` | — | Public URL of the portal, so alerts link straight to the failed run. |
| `AIRFLOW_URL` / `AIRFLOW_WEBSERVER_URL` | — | Default URL shown on the Airflow page; users can still enter one at runtime. |
| `AIRFLOW_USERNAME` / `AIRFLOW_PASSWORD` | — | Service account for the Airflow REST API (with `AIRFLOW_URL`): DAG list, recent runs, trigger, pause. Without them the Airflow page only probes `/health` and embeds the UI. |
| `AIRFLOW_UPSTREAM` | — | Frontend container: `host:port` of an Airflow webserver to serve under `/airflow-ui/` on the portal's origin, so the Airflow page can embed it (a cross-site iframe loses Airflow's session cookie and its login fails with "CSRF session token is missing"). Airflow must run with `AIRFLOW__WEBSERVER__BASE_URL=http://<portal host>/airflow-ui`. |
| `AIRBYTE_URL` | — | Airbyte root the execution service calls (section 5a): `http://host.docker.internal:8000` for `abctl` on the same host, `https://api.airbyte.com/v1` for Airbyte Cloud. Unset = the Airbyte page shows the install steps. |
| `AIRBYTE_CLIENT_ID` / `AIRBYTE_CLIENT_SECRET` | — | API application credentials (`abctl local credentials`, or an Airbyte Cloud application). Only omit for an install with auth disabled. |
| `AIRBYTE_WORKSPACE_ID` | all workspaces | Limit the Airbyte page to one workspace. |
| `AIRBYTE_UI_URL` | derived from `AIRBYTE_URL` | The Airbyte UI link users' browsers open, when it differs from the URL the backend uses. |
| `COLIBRI_DIST_DIR` | auto-discovered | Override where the Colibri static report is found. |
| `PREFLIGHT_ON_START` | `true` | Set `false` to skip the entrypoint's preflight checks (they run in the execution and single-node containers). |
| `PREFLIGHT_STRICT` | `false` | `true` refuses to start the container when preflight finds a failure (vs. warning and starting anyway). |
| `PORTAL_CA_CERTS` | `<project>/.certs/` | Corporate root CA(s) for a proxy that inspects TLS (Zscaler, Netskope...): a PEM file or a folder of `*.pem`/`*.crt`. The entrypoint adds them to the public roots and points `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE` and `GIT_SSL_CAINFO` at the merged bundle. Symptom without it: `CERTIFICATE_VERIFY_FAILED ... self-signed certificate in certificate chain` from the AI providers or `dbt deps`. An explicit `SSL_CERT_FILE` wins. |

## 7. Verify the install

**Before** starting, run the standalone check. It validates config, the dbt
project, the profile/target/adapter, and warehouse env vars:

```bash
# Compose (microservices or single node)
docker compose run --rm --no-deps execution python -m app.preflight
docker compose -f compose.single.yaml run --rm --no-deps backend python -m app.preflight

# Kubernetes
kubectl exec -n dbt-portal deploy/dbt-portal-execution -- python -m app.preflight

# Bare VM
.venv/bin/python -m app.preflight

# add --dbt-debug to also test the actual warehouse login (`dbt debug`)
```

It also runs on every start of the execution (or single-node) container, and
its output is the first thing to check in its log when something's wrong.
Example output:

```
[OK  ] environment: production
[OK  ] JWT_SECRET: set
[OK  ] portal database: postgresql+psycopg2://portal:***@postgres:5432/portal_execution
[OK  ] dbt project: capgemini_dbt_core at /workspace
[OK  ] dbt executable: /opt/venv/bin/dbt
[OK  ] dbt profile: default.dev (snowflake) from /workspace/profiles.yml
[OK  ] Snowflake: SVC_DBT@xy12345.eu-central-1 (role DBT_TRANSFORMER_ROLE)

Preflight: passed
```

**After** the stack is up:

1. `docker compose ps`: every service `healthy` (workers included).
2. `curl http://<host>:8080/api/version`: the backend release and API version.
3. Sign in (seeded admin account, password from section 5) and open **Tools &
   Services**: *Portal database* should say PostgreSQL and *Redis* Connected.
4. Open **dbt Runner** and run **Maintenance → debug**. It is queued, runs on
   a worker, and its output streams live; success there confirms the warehouse
   credentials end-to-end.

## 8. Adding a new client, end to end (checklist)

1. Confirm which [path](#2-pick-a-deployment-path) matches their infra.
2. Confirm their `profiles.yml` uses `env_var()` for every credential (section
   4). If not, that's a one-time edit to their dbt project, not the portal.
3. Pick mount, git, or bake for the project source (section 2).
4. Mount mode with the project's own `.env` already on disk: usually nothing
   to fill in. Git mode, Kubernetes, or a deviation from the project's
   defaults: set the relevant credentials in `.env` / `secrets.env` /
   `portal.env` (section 4's mount-vs-git note, section 6 for the full list).
5. Pick one release from `releases.yml` and use its three tags everywhere.
6. Run preflight (section 7) and fix everything it flags.
7. Start the stack, confirm section 7's post-start checks.
8. Capture the generated admin password from the identity log (or set
   `SEED_*_PASSWORD` beforehand) and hand it to the client through your normal
   secret-sharing channel, not a repo.

## 9. Operating the portal

**Logs.** Every service writes one JSON object per line to stdout: `ts`,
`level`, `logger`, `msg`, a `request_id` for anything that happened during an
HTTP request, and context fields (`job_id`, `kind`, `status`, `duration_ms` ...).
Every response carries the same id in `X-Request-ID`, so a user's error
report can be matched to its log lines. Set `LOG_FORMAT=text` for a laptop.
dbt runs log in the **worker**; the API that queued them in **execution**.

**Metrics.** `GET /metrics` on each service's port (not through the gateway)
serves Prometheus metrics: `portal_http_requests_total` and
`portal_http_request_duration_seconds` by route template,
`portal_jobs_started_total`, `portal_jobs_finished_total{status}`,
`portal_job_duration_seconds`, `portal_jobs_running` (on the workers),
`portal_schedule_fires_total{outcome}` and
`portal_notifications_total{channel,outcome}`. The Kubernetes manifests carry
the usual `prometheus.io/*` scrape annotations.

**Scaling.** Add workers for more concurrent dbt runs (`--scale worker=N`,
or the worker Deployment's replicas); each takes up to `WORKER_CONCURRENCY`
jobs. identity, insights, the execution API and the frontend are stateless and
scale freely. A job request waits up to 20 seconds for a worker; with none
running, the page says "No execution worker picked up the job".

**Schedules.** On the dbt Runner page, build a command, then *Schedules → Add
schedule* with a cron expression and a time zone. A schedule runs as the user
who last saved it, and stops firing if that user is disabled or loses
`dbt.execute`. A slot missed while every worker was down runs late only
within 5 minutes; older ones are skipped, not replayed.

**Failure alerts.** Governance → Failure alerts (Admin role): Slack and Teams
webhooks, email recipients, and whether warnings and manual runs alert too.
*Send test alert* checks each channel. Webhook URLs are never shown again
after saving; the page displays a masked form.

**Restarts.** Running jobs are written to the execution database and kept
alive by the worker's heartbeat. If a worker stops, its jobs are marked failed
with "Interrupted" (right away on a clean shutdown, within about 2.5 minutes
after a crash). Live logs and *Cancel* work from any execution replica (Redis).
Sessions, lockouts and accounts are in the identity database; a user disabled
there is refused by every service within 10 seconds.

**Upgrades.** Pick a newer release in `releases.yml`, then
`./setup.sh <project> --release <name>` (or set the three tags in `.env` and
`docker compose up -d`). Schema changes are applied by each service on start;
several replicas starting together take turns (a PostgreSQL advisory lock).

### From single node to microservices

The single-node portal kept everything in one SQLite file. Move it into the
microservices stack's databases once, then keep using the new stack:

```bash
# 1. Stop the old portal and find its data volume (portal.py: capgemini-portal-<slug>-<sha6>-data)
docker volume ls | grep -- -data

# 2. Start the new stack's databases and services once, so the schemas exist
docker compose up -d postgres redis identity execution

# 3. Copy the tables each service owns (users/roles/audit/sessions; run history/schedules/alerts)
docker compose run --rm --no-deps -v <old-data-volume>:/old:ro identity  python -m app.db.import_sqlite /old/portal.db
docker compose run --rm --no-deps -v <old-data-volume>:/old:ro execution python -m app.db.import_sqlite /old/portal.db

# 4. Start everything
docker compose up -d
```

Tables that already hold rows are skipped; add `--replace` to overwrite them.
Keep the old volume until you have signed in and checked the history. The old
portal's sessions do not carry over (new secrets): users sign in again.
