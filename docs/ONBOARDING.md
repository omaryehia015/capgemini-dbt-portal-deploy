# Onboarding a client onto the dbt Portal

This portal is generic: it never hard-codes a client's dbt project, warehouse
or infrastructure, and the image itself carries zero client-specific config.
Onboarding a new client is choosing **where their dbt project lives** and
**how it reaches this portal** — that's it. Warehouse credentials are not a
separate thing to configure: the backend's entrypoint reads them straight out
of the client's own project `.env` (the file sitting next to their
`profiles.yml`, which that project needs regardless of this portal), so
pointing the image at a project is normally the *entire* setup. No code
changes, and for the common case, no `.env` of the portal's own either.

**Shipping this to a client?** They don't need this repo, a build step, or
any of what follows in this doc except the env-var reference (section 6).
They get exactly two files: [deploy/client/compose.yaml](../deploy/client/compose.yaml)
and [deploy/client/.env.example](../deploy/client/.env.example), documented in
[deploy/client/README.md](../deploy/client/README.md) — pre-built images, a
project mount, `docker compose up -d`. This doc is for *you*: how those
images get built and how to wire them into whatever infrastructure a
particular client already has.

## Fastest path: one script

The client-side script lives in the dbt package, not in this repo:
[capgemini_dbt_core/scripts/portal.py](https://github.com/omaryehia015/capgemini_dbt_core/blob/main/scripts/portal.py).
It is one file (Python 3.8+, standard library only) and behaves the same on Windows, macOS
and Linux. The client needs Docker or Podman and nothing else, because dbt runs inside this
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
missing credentials to the project's `.env`. Then it pulls the images and starts a portal
instance just for that project, with its own containers, volume and a free port. It
confirms that `/api/onboarding/status` reports the same `project_name`, runs the steps below
through the API and schedules `refresh`. Proxies (`HTTP(S)_PROXY`), a corporate CA
(`--ca-cert`), mirrors (`--registry`/`--tag`) and offline machines (`--no-pull`) are
covered. The backend runs as root inside the container because Windows/macOS bind mounts
and rootless Podman need it for `dbt deps`. On Linux with rootful Docker, the script hands
the files dbt wrote back to the project owner.

The script uses only the API (`/api/auth/*`, `/api/onboarding/*`, `/api/jobs/*`) and the
container contract (`DBT_PROJECT_DIR`, `DBT_PROFILES_DIR`, `/data`, the
`GENERATED INITIAL CREDENTIALS` log banner). Changing any of these breaks client installs,
so update the script in capgemini_dbt_core at the same time.

The same steps are available later in the portal's **Onboarding** page:

| Step | Done when | What running it does |
|---|---|---|
| Connect | project, profile, credentials and dbt are present | `dbt debug` (logs in to the warehouse) |
| Install packages | every package in `package-lock.yml` is in `dbt_packages/` | `dbt deps` (retries transient mount errors) |
| Provision database | the metadata database has every package schema | `dbt run-operation grant_package_access` |
| Build observability | Elementary tables exist | `dbt run -s elementary` (+ FinOps if installed) |
| Generate reports | docs, Colibri and Elementary report exist | docs + Colibri + `edr report` |

*Provision* is limited to users with `governance.manage` (the Admin role). The sections below are for
infrastructure the script doesn't cover (Kubernetes, baked images, bare VMs).

Read order: [1. What "onboarding" means here](#1-what-onboarding-means-here) →
pick your path in [2](#2-pick-a-deployment-path) → do the steps in that
path's section → [6. Every environment variable](#6-every-environment-variable-reference)
as a reference while you fill in `.env` → [7](#7-verify-the-install) to confirm it worked.

## 1. What "onboarding" means here

Two independent things point the portal at a specific client:

1. **Where the dbt project's files are** — a host folder, a git repo, a
   Kubernetes volume, or baked into the image. Section 3.
2. **Where dbt should run it** — Snowflake (or another warehouse) account,
   plus which `profiles.yml` target. Section 4.

Everything else (portal auth secret, seed passwords, database) is the same
shape for every client and is covered in section 6.

The backend resolves the project path with this precedence (unchanged from
the original Streamlit portal, so client `profiles.yml`/scripts that already
depend on it keep working): **`DBT_PROJECT_DIR`** → **`WORKSPACE_ROOT`** →
**`PROJECT_ROOT`** → the first parent of the working directory containing
`dbt_project.yml` → the backend's own parent directory. See
[backend/app/core/config.py](../backend/app/core/config.py).

## 2. Pick a deployment path

| Client's setup | Path | Project source |
|---|---|---|
| Just a client, no repo access — this is the normal case | [E — Client kit](#e-client-kit-pre-built-images-what-you-actually-hand-a-client) | bind mount or git clone |
| You, building/testing this repo, or a laptop with no image registry yet | [A — Podman/Docker Compose](#a-podmandocker-compose-single-vm-or-laptop) | bind mount or git clone |
| Kubernetes cluster (their own or managed) | [B — Kubernetes](#b-kubernetes) | git clone (init container pattern) or a shared volume |
| dbt project already ships as a container image | [C — Bake the project into the image](#c-bake-the-project-into-the-image) | baked in at build time |
| Plain Linux VM, no containers allowed | [D — Bare VM (systemd + nginx)](#d-bare-vm-systemd--nginx) | git clone or rsync'd folder |

All five run the exact same backend/frontend code and read the exact same
environment variables (section 6) — they differ only in how those variables
get set and how the project's files arrive at `/workspace` (or the
VM-native path in path D). A and E are the same containers and the same
compose shape; the only difference is A builds the images locally from this
repo (`build:`), E pulls already-published ones (`image:`) and needs nothing
from this repo at all.

### How the client's dbt project gets into the container (any path)

Three interchangeable options — pick per client:

- **Mount** — a host path (`DBT_PROJECT_PATH`, compose) or a
  cluster volume is bind-mounted at `/workspace`. Nothing to build; the
  client's own CI/CD or a colleague keeps the folder up to date. Best when
  the client already deploys dbt this way (e.g. an existing Airflow worker
  image with the project on a shared volume).
- **Git** — set `DBT_PROJECT_GIT_URL` (+ `DBT_PROJECT_GIT_REF`, and
  `DBT_PROJECT_GIT_TOKEN` for private repos). The container's entrypoint
  (`backend/docker-entrypoint.sh`) clones on first start and fast-forwards on
  every restart. Best default for a client with a git repo and no existing
  deployment pattern — one image, zero host state.
- **Bake** — the project is `COPY`'d into the image at build time
  ([deploy/bake/Dockerfile](../deploy/bake/Dockerfile)). Best when the client
  already versions their dbt project as an image and wants the portal
  version-locked to a specific project release.

`DBT_PROJECT_SUBDIR` handles a monorepo in any of the three (the dbt project
is a sub-folder of what got mounted/cloned/baked).

---

### E. Client kit (pre-built images) — what you actually hand a client

This is the real deliverable. A client gets **two files**, not this repo:
[deploy/client/compose.yaml](../deploy/client/compose.yaml) and
[deploy/client/.env.example](../deploy/client/.env.example) (walkthrough in
[deploy/client/README.md](../deploy/client/README.md)). Both images are
already published — see [.github/workflows/publish-images.yml](../.github/workflows/publish-images.yml),
which builds and pushes them to `ghcr.io/<this-repo>-backend`/`-frontend` on
every `vX.Y.Z` tag.

Client-side, the whole install is:

```bash
cp .env.example .env
# set DBT_PROJECT_PATH to their dbt project folder, or DBT_PROJECT_GIT_URL
docker compose pull
docker compose up -d
docker compose logs backend | grep -A6 "GENERATED INITIAL CREDENTIALS"
```

No source checkout, no build, no Python/Node/dbt on their machine, and
normally no other configuration: warehouse credentials come from their
project's own `.env` (section 4), and the session secret and initial account
passwords are generated on first start (sections 5–6). If their
infrastructure is actually Kubernetes or a bare VM, use path B or D instead
with `images:` pointing at the same published tags — the client kit is the
compose-shaped packaging of the same two images, not a different build.

To publish a new version: `git tag v1.1.0 && git push --tags` (or run the
workflow manually from the Actions tab for an unreleased test build). First
time only: make the two GHCR packages public from their GitHub package
settings, or give clients a `docker login ghcr.io` token — private packages
otherwise block `docker compose pull` with a 401.

### A. Podman/Docker Compose (single VM or laptop)

```bash
cp .env.example .env
# Set DBT_PROJECT_PATH (or the DBT_PROJECT_GIT_URL block) -- that's the only
# required line. Warehouse creds come from the project's own .env (section 4).
notepad .env   # or your editor of choice
```

**Mount mode** — set `DBT_PROJECT_PATH` to the project folder, relative to
`compose.yaml` (e.g. `../capgemini_dbt_core`). Podman's Windows client mangles
absolute `/mnt/c/...` paths, so keep it relative.

**Git mode** — leave `DBT_PROJECT_PATH` unset, set `DBT_PROJECT_GIT_URL` (and
`DBT_PROJECT_GIT_REF`, `DBT_PROJECT_GIT_TOKEN` if private). The project lands
in the `workspace` named volume.

Then bring it up:

```bash
podman compose up --build -d      # or: podman-compose up --build -d
# open http://localhost:8080
```

`podman compose` needs a compose provider — `pip install --user podman-compose`
(add its `Scripts` dir to `PATH`) if neither `docker-compose` nor
`podman-compose` is already on PATH.

Check it worked before opening the browser:

```bash
podman compose logs backend | grep -A2 Preflight
```

Backend-only development (frontend via `npm run dev`), the same modes apply:

```powershell
cd backend
.\run_fastapi.ps1 -Command preflight   # dry run: reports problems, starts nothing
.\run_fastapi.ps1 -Command up
```

### B. Kubernetes

Manifests: [deploy/kubernetes/](../deploy/kubernetes/) (kustomize).

```bash
cd deploy/kubernetes
cp secrets.env.example secrets.env      # fill in warehouse creds + git token (JWT_SECRET: leave blank, auto-generated)
$EDITOR portal.env                      # DBT_PROJECT_GIT_URL/REF, DBT_TARGET, images
kubectl apply -k .
kubectl logs -n dbt-portal deploy/dbt-portal-backend -f   # watch preflight + clone
```

Notes specific to Kubernetes:

- **One backend replica.** Running jobs and their live log streams live in
  the backend's process memory; a second pod would show a different job list
  depending which pod a request hit. `backend.yaml` sets `replicas: 1` and
  `strategy: Recreate` — don't raise it without moving job state to something
  shared first.
- **Project source**: `portal.env` defaults to git mode with an `emptyDir`
  workspace (cloned fresh on every pod (re)start — fine, since dbt projects
  are small and dbt writes `target/`/`dbt_packages/` back into it anyway). If
  the client already has the project on a `ReadWriteMany` volume (e.g. shared
  with an existing Airflow deployment), swap the `emptyDir` for a
  `persistentVolumeClaim` in `backend.yaml` and drop `DBT_PROJECT_GIT_URL`.
- **`profiles.yml` as a Secret** instead of committed with `env_var()`:
  `kubectl create secret generic dbt-profiles --from-file=profiles.yml -n dbt-portal`,
  then uncomment the `dbt-profiles` volume/mount in `backend.yaml` and set
  `DBT_PROFILES_DIR=/etc/dbt` in `portal.env`.
- **Ingress** in `ingress.yaml` is an ingress-nginx example; adapt to the
  client's ingress controller. No ingress available yet? `kubectl port-forward
  svc/dbt-portal-frontend 8080:8080` and open `http://localhost:8080`.
- **Images**: push `capgemini-dbt-portal-backend`/`-frontend` to the client's
  registry and set the tags in `kustomization.yaml`'s `images:` block.

### C. Bake the project into the image

For a client who already publishes their dbt project as (or alongside) a
container image:

```bash
podman build -t capgemini-dbt-portal-backend:local backend    # portal base image
podman build -f deploy/bake/Dockerfile \
  --build-arg CLIENT_DBT_IMAGE=registry.client.com/analytics/dbt:2.3.0 \
  --build-arg CLIENT_PROJECT_PATH=/usr/app/dbt \
  -t registry.client.com/analytics/dbt-portal-backend:2.3.0 .
```

Then deploy that image with **no** `DBT_PROJECT_PATH`/`DBT_PROJECT_GIT_URL`
set at all — the project is already at `/workspace`. Works with either
compose (point `image:` at the baked tag) or Kubernetes (path B, images
section). See comments in [deploy/bake/Dockerfile](../deploy/bake/Dockerfile)
for building from a local checkout instead of an image.

### D. Bare VM (systemd + nginx)

For a client that won't run containers at all. Needs Python 3.11+, Node 22
(build-time only), nginx.

```bash
git clone <portal repo> /opt/dbt-portal
cd /opt/dbt-portal/backend
python -m venv .venv && .venv/bin/pip install -r requirements.txt

# Get the client project onto the box (any of these, matching section 3):
git clone <client-repo> /opt/dbt-portal-project      # git mode, manual
#  - or rsync/scp an existing checkout to the same path
#  - or point DBT_PROJECT_DIR at wherever the client's own deploy already puts it

sudo useradd --system --home /opt/dbt-portal dbtportal
sudo mkdir -p /etc/dbt-portal /data
sudo cp ../.env.example /etc/dbt-portal/portal.env    # fill in as an env file (KEY=VALUE, no quotes)
echo "DBT_PROJECT_DIR=/opt/dbt-portal-project" | sudo tee -a /etc/dbt-portal/portal.env
echo "DATABASE_URL=sqlite:////data/portal.db"   | sudo tee -a /etc/dbt-portal/portal.env
sudo chown -R dbtportal /opt/dbt-portal /opt/dbt-portal-project /data

.venv/bin/python -m app.preflight   # check before wiring up systemd
sudo cp ../deploy/vm/dbt-portal-backend.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now dbt-portal-backend

cd ../frontend && npm ci && npm run build
sudo mkdir -p /var/www/dbt-portal && sudo cp -r dist/* /var/www/dbt-portal/
sudo cp ../deploy/vm/nginx-dbt-portal.conf /etc/nginx/conf.d/dbt-portal.conf
sudo nginx -t && sudo systemctl reload nginx
```

For git-mode auto-update on this path, run
`backend/docker-entrypoint.sh`'s clone/fetch logic yourself in a cron job or
a `git pull` step in your deploy script — the systemd unit itself doesn't
run it (there's no container entrypoint here).

## 3. Cross-cutting: how the frontend finds the backend

The nginx container ([frontend/nginx/default.conf.template](../frontend/nginx/default.conf.template))
proxies `/api/*` (including the dbt-runner WebSocket) to `BACKEND_UPSTREAM`
(default `backend:8000`, matching the compose service name). Override it
per deployment:

- Compose: leave it — the service is named `backend`.
- Kubernetes: `frontend.yaml` sets it to the backend Service name
  (`dbt-portal-backend:8000`).
- Bare VM: `deploy/vm/nginx-dbt-portal.conf` hard-codes `127.0.0.1:8000`
  (same host, no container networking).
- Local frontend dev (`npm run dev`, no container): Vite's dev proxy target
  is `VITE_API_PROXY_TARGET` (default `http://127.0.0.1:8123`) in
  [frontend/vite.config.ts](../frontend/vite.config.ts).

## 4. Warehouse credentials and the dbt profile

The portal never talks to the warehouse directly except through dbt and a
thin Snowflake metadata browser ([backend/app/services/snowflake.py](../backend/app/services/snowflake.py)).
Both read the **same** environment variables, so one set of credentials
covers dbt runs and the in-portal warehouse pages:

`DBT_PKG_ACCOUNT`, `DBT_PKG_USER`, `DBT_PKG_PASSWORD`, `DBT_PKG_ROLE`,
`DBT_PKG_WAREHOUSE`, `DBT_PKG_DATABASE` (legacy `DBT_SNOWFLAKE_*` /
`SNOWFLAKE_*` names are also read, in that order, for clients whose existing
`profiles.yml` already used them).

**You almost never set these yourself.** [backend/docker-entrypoint.sh](../backend/docker-entrypoint.sh)
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
  (path E) — which reach the container the same way and are just as
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
add that adapter to the backend image with the `EXTRA_PIP_PACKAGES` build arg
— `podman build --build-arg EXTRA_PIP_PACKAGES="dbt-bigquery~=1.8.0" backend`
(compose: set `EXTRA_PIP_PACKAGES` in `.env`) — and write `profiles.yml`
accordingly. `snowflake.py`'s pages will no-op for non-Snowflake clients
(`is_configured()` returns false); nothing else assumes Snowflake.

**Multiple targets** (dev/staging/prod): set `DBT_TARGET` per deployment. It
overrides the profile's own `target:` key without touching the file.

## 5. Portal accounts and RBAC

Four seeded roles (Admin, Lead Engineer/"engineer", Analyst, Auditor — see
[backend/app/db/seed.py](../backend/app/db/seed.py)) exist from first start,
stored in the portal database, editable afterward from the Governance page.

- `ENVIRONMENT=development` (the default) seeds documented passwords
  (`admin123!` etc.) — fine for a demo, never for anything a client can reach.
- Any other `ENVIRONMENT` value generates a random password per account and
  prints it once in the backend log (`podman logs`/`kubectl logs`) — capture
  it there, or pre-set `SEED_ADMIN_PASSWORD` etc. before first start.
- `JWT_SECRET`: leave unset. The entrypoint generates one and persists it to
  the data volume/PVC on first start (see section 6) — nothing to set outside
  development either.

## 6. Every environment variable (reference)

Full template with inline comments: [.env.example](../.env.example). Grouped
here by what they control — `backend/app/core/config.py`,
`backend/app/services/dbt_context.py`, `backend/app/services/project_paths.py`
and `backend/app/services/snowflake.py` are the source of truth.

| Variable | Default | Purpose |
|---|---|---|
| `DBT_PROJECT_DIR` / `WORKSPACE_ROOT` / `PROJECT_ROOT` | walk-up from cwd | Where the dbt project is, in that precedence order. Compose sets `DBT_PROJECT_DIR=/workspace` for you. |
| `DBT_PROJECT_PATH` | — | Compose-only: host path mounted at `/workspace` (mount mode). |
| `DBT_PROJECT_GIT_URL` | — | Git mode: repo to clone into the workspace. |
| `DBT_PROJECT_GIT_REF` | `main` | Branch/tag to clone and track. |
| `DBT_PROJECT_GIT_TOKEN` / `DBT_PROJECT_GIT_USERNAME` | — | Auth for a private repo (HTTPS). Username defaults to `x-access-token` (GitHub PAT); use `oauth2` for GitLab. |
| `DBT_PROJECT_SUBDIR` | — | dbt project is a sub-folder of the mount/clone (monorepo). |
| `DBT_DEPS_ON_START` | `false` | Run `dbt deps` in the entrypoint before the server starts. |
| `DBT_PROFILES_DIR` | project root, then `~/.dbt` | Where `profiles.yml` lives, if not the project root. |
| `DBT_EXECUTABLE_PATH` | auto-detected | Explicit path to the `dbt` binary; only needed for an unusual layout. |
| `DBT_TARGET` | profile's own `target:` | Which `profiles.yml` output to run against. |
| `EXTRA_PIP_PACKAGES` | — | Backend image **build arg**: extra pip packages (a different adapter, a pinned dbt version). |
| `JWT_SECRET` | auto-generated | Portal session signing key. Leave unset: the entrypoint generates one on first start and persists it to the data volume/PVC (`/data/.jwt_secret`), so sessions survive restarts without anyone setting a secret by hand. Set it explicitly to pin or rotate it. |
| `JWT_EXPIRES_MINUTES` | `480` | Session length. |
| `ENVIRONMENT` | `development` | Gates the JWT-secret check and seed-password behavior above. |
| `SEED_ADMIN_PASSWORD` / `SEED_ENGINEER_PASSWORD` / `SEED_ANALYST_PASSWORD` / `SEED_AUDITOR_PASSWORD` | dev defaults, else random | Initial password for each seeded account. |
| `DATABASE_URL` | `sqlite:////data/portal.db` | Portal state (users, roles, audit log, run history). Any SQLAlchemy URL; `postgresql+psycopg2://...` for Postgres. |
| `DBT_PKG_ACCOUNT` / `_USER` / `_PASSWORD` / `_ROLE` / `_WAREHOUSE` / `_DATABASE` | — | Warehouse credentials, read by both `profiles.yml` (via `env_var`) and the portal's Snowflake pages. |
| `CORS_ORIGINS` | `["http://localhost:5173"]` | Only relevant if the frontend is served from a different origin than the backend (not the case for the compose/Kubernetes/VM setups above, which proxy same-origin). |
| `AIRFLOW_URL` / `AIRFLOW_WEBSERVER_URL` | — | Default URL shown on the Airflow page; users can still enter one at runtime. |
| `COLIBRI_DIST_DIR` | auto-discovered | Override where the Colibri static report is found. |
| `PREFLIGHT_ON_START` | `true` | Set `false` to skip the entrypoint's preflight checks entirely. |
| `PREFLIGHT_STRICT` | `false` | `true` refuses to start the container when preflight finds a failure (vs. warning and starting anyway). |

## 7. Verify the install

**Before** starting the server, run the standalone check — it validates
config, the dbt project, the profile/target/adapter, and warehouse env vars
without needing a running container:

```bash
# Compose / Podman
cd backend && .\run_fastapi.ps1 -Command preflight        # PowerShell
podman run --rm --env-file ../.env <image> python -m app.preflight   # any shell

# Kubernetes
kubectl exec -n dbt-portal deploy/dbt-portal-backend -- python -m app.preflight

# Bare VM
.venv/bin/python -m app.preflight

# add --dbt-debug to also test the actual warehouse login (`dbt debug`)
```

It also runs automatically on every container start
([backend/docker-entrypoint.sh](../backend/docker-entrypoint.sh)) and its
output is the first thing to check in `podman logs` / `kubectl logs` /
`journalctl -u dbt-portal-backend` when something's wrong. Example output:

```
[OK  ] environment: production
[OK  ] JWT_SECRET: set
[OK  ] portal database: sqlite:////data/portal.db
[OK  ] dbt project: capgemini_dbt_core at /workspace
[OK  ] dbt executable: /opt/venv/bin/dbt
[OK  ] dbt profile: default.dev (snowflake) from /workspace/profiles.yml
[OK  ] Snowflake: SVC_DBT@xy12345.eu-central-1 (role DBT_TRANSFORMER_ROLE)
[OK  ] Airflow: http://airflow-webserver:8080

Preflight: passed
```

**After** the server is up:

1. `curl http://<host>:8080/api/health` → `{"status":"ok"}`.
2. Log in (seeded admin account — password from section 5) and open
   **dbt Runner**: the model/tag/package pickers should show the client's
   real assets (from `target/manifest.json`, or a filesystem scan before the
   first compile).
3. Run **Maintenance → debug** from the UI — it wraps `dbt debug` and streams
   the result live over WebSocket; success there confirms the warehouse
   credentials end-to-end, not just that they're present.

## 8. Adding a new client, end to end (checklist)

1. Confirm which [path](#2-pick-a-deployment-path) (E–D) matches their infra.
2. Confirm their `profiles.yml` uses `env_var()` for every credential (section
   4) — if not, that's a one-time edit to their dbt project, not the portal.
3. Pick mount, git, or bake for the project source (section 3).
4. Mount mode with the project's own `.env` already on disk: usually nothing
   to fill in at all. Git mode, Kubernetes, or a deviation from the project's
   defaults: set the relevant credentials in `.env` / `secrets.env` /
   `portal.env` (section 4's mount-vs-git note, section 6 for the full list).
5. `python -m app.preflight --dbt-debug` (or the compose/Kubernetes
   equivalent) — fix everything it flags before going further.
6. Start the stack, confirm section 7's post-start checks.
7. Capture the generated admin password from `docker compose logs backend`
   (or set `SEED_*_PASSWORD` beforehand) and hand it to the client through
   your normal secret-sharing channel, not this repo. `JWT_SECRET` needs no
   action either way — it's generated and persisted automatically.
