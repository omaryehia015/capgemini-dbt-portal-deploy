# Capgemini dbt Portal (FastAPI + React)

Standalone replacement for the Streamlit-based `streamlit_dashboard/` portal in
`capgemini_dbt_core`. **The Streamlit app stays live and is the system of
record until this app covers feature parity** — see Status below.

## Why this exists

The old portal fought Streamlit's rerun model for anything long-running
(background dbt jobs, live log output) and had no real session/cookie API,
forcing workarounds (`st.fragment(run_every=2)` polling, an iframe
`document.cookie` hack). This app replaces both with what the framework
naturally gives you: WebSocket push for live output, real `Authorization`
headers/JWTs for auth.

Same env-var contract as the old portal, so it points at any client dbt
project without code changes: `DBT_PROJECT_DIR` / `WORKSPACE_ROOT` /
`PROJECT_ROOT`, in that precedence order (see `backend/app/core/config.py`).

**Shipping this to a client?** They don't need this repo. They get
[deploy/client/](deploy/client/) — two pre-built images (published by
[.github/workflows/publish-images.yml](.github/workflows/publish-images.yml)),
one compose file, one `.env` with a single line (where their dbt project is).
Warehouse credentials come from that project's own `.env`; the session secret
and initial account passwords are generated on first start. Full details, plus
Kubernetes/bare-VM/bake variants: [docs/ONBOARDING.md](docs/ONBOARDING.md).

## Structure

```
backend/    FastAPI app (Python) — auth, dbt command building/execution, WebSocket log streaming
frontend/   React + TypeScript + Vite — UI, ported 1:1 in visual language from the old Streamlit theme
```

## Running (containers only — Podman or Docker)

The app is meant to run the way it will in production: two containers, no
host Python or Node required. Kubernetes, a bare VM, and baking the dbt
project into the image are also supported — see
[docs/ONBOARDING.md](docs/ONBOARDING.md) for those paths.

```
browser -> nginx :8080 (serves the SPA, proxies /api incl. WebSocket)
                 └──> backend :8000 (FastAPI + dbt, internal network only)
                          └── /workspace: bind-mounted, git-cloned, or baked
                              client dbt project (docs/ONBOARDING.md §3)
```

```bash
cp .env.example .env     # set DBT_PROJECT_PATH (or _GIT_URL) -- that's the only required line
podman compose up --build -d      # or: podman-compose up --build -d
# open http://localhost:8080
```

Before starting the stack (or any time something looks misconfigured), run
the standalone check — validates the project, dbt profile/target/adapter and
warehouse env vars, no server required:

```powershell
cd backend
.\run_fastapi.ps1 -Command preflight
```

Notes:
- **Podman needs a compose provider.** `podman compose` shells out to
  `docker-compose` or `podman-compose`; `pip install --user podman-compose`
  works (add its `Scripts` dir to `PATH`).
- **`DBT_PROJECT_PATH` must be relative to `compose.yaml`** (e.g.
  `../capgemini_dbt_core`). On Windows, Podman's client mangles absolute
  `/mnt/c/...` paths into `/mnt/c/mnt/c/...`. No host folder to mount? Set
  `DBT_PROJECT_GIT_URL` instead (docs/ONBOARDING.md §3) — the backend clones
  it into a named volume on start.
- The backend image carries its own dbt (`dbt-core` + `dbt-snowflake`), since a
  host virtualenv can't be used across the Windows/Linux container boundary.
  dbt writes `target/`, `logs/` and `dbt_packages/` into the mounted project.
  A different warehouse adapter or a pinned dbt version: build with
  `--build-arg EXTRA_PIP_PACKAGES="dbt-bigquery~=1.8.0"` (or set
  `EXTRA_PIP_PACKAGES` in `.env` for compose).
- **`up --build` does not recreate a running container** under podman-compose;
  use `podman-compose down && podman-compose up -d` after code changes.
- Snowflake credentials (`DBT_PKG_*`) come from `.env` and are read by the
  client project's `profiles.yml`. Without them `dbt debug` fails with
  `'user' is a required property`, which is the correct behavior.

Dev seed accounts (override with `SEED_*_PASSWORD` before any real use):
`admin` / `admin123!`, `engineer` / `engineer123!`, `analyst` / `analyst123!`,
`auditor` / `auditor123!`.

## Status

**Verified end-to-end in containers** (built with Podman; exercised through
nginx on :8080 against the real `capgemini_dbt_core` project — SPA + deep-link
fallback, login, RBAC 401/403, project/asset discovery from `manifest.json`,
and a real `dbt debug` job whose output streamed live over WebSocket). The
frontend now compiles cleanly under `tsc` + `vite build`. **Not yet checked:**
how the UI actually looks and behaves in a browser — that still needs a human
pass:
- JWT auth + RBAC (4 roles, 7 permissions, same model as the old portal)
- dbt Runner: Execution (run/build/test/seed/snapshot) with all scope modes
  (all/models/layer/tag/package/custom selector), lineage modifiers, flags
  (full-refresh/fail-fast/store-failures/threads), Maintenance
  (deps/clean/compile/debug), live WebSocket log streaming, run history

**Not yet ported (still on Streamlit — routed to a "coming soon" placeholder
in the sidebar so navigation doesn't 404):**
dbt Docs, Elementary, Colibri, Airflow, Assets, Ask AI, Governance, DWH
FinOps, Profiler, SQL Linter.

**Deliberately simplified vs. the old portal, flagged for follow-up:**
- Auth is portal-database-backed (`backend/app/services/auth_service.py`,
  `backend/app/db/`), not Snowflake/LDAP-backed yet — swap the module's
  `authenticate()`/`get_user()` without touching any route.
- Run history persists to the portal database (`job_store.py`, bounded to the
  newest rows), not to Snowflake `PORTAL_DBT_EXECUTIONS` like the old portal.
- SQLFluff/profiler/run-operation/custom-command tabs from the old dbt
  Runner page aren't ported — only Execution + Maintenance.
- CI is [publish-images.yml](.github/workflows/publish-images.yml): every pull
  request builds both images, pushes to `main` and `v*.*.*` tags publish them to
  GHCR, and Trivy reports HIGH/CRITICAL findings (report-only — set `exit-code`
  to `"1"` to gate on them).
- Images are built as OCI format by default, which drops image-level
  `HEALTHCHECK`; healthchecks therefore live in `compose.yaml` instead.

## Porting order (suggested)

1. Assets (mostly read-only, reuses `dbt_context.discover_client_assets`)
2. dbt Docs / Elementary / Colibri (serve pre-generated static HTML via
   FastAPI `StaticFiles` — simpler here than it was on Streamlit)
3. SQL Linter, Profiler (extend `command_builder.py` + `job_manager.py`,
   same pattern as dbt Runner)
4. Governance, DWH FinOps, Airflow, Ask AI (need real backing
   services/credentials wired up, not just UI)
