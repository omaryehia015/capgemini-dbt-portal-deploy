# System guide: the Data Engineering Accelerator end to end

Read this first if you are new to the team. It explains what the whole
system does, which repo holds which part, how a request and a dbt run travel
through it, and where to go next for each part.

- [1. What the system does](#1-what-the-system-does)
- [2. The five repos](#2-the-five-repos)
- [3. The running system](#3-the-running-system)
- [4. A dbt run, end to end](#4-a-dbt-run-end-to-end)
- [5. Onboarding a client project](#5-onboarding-a-client-project)
- [6. Where the data lives](#6-where-the-data-lives)
- [7. The contracts between repos](#7-the-contracts-between-repos)
- [8. From commit to client](#8-from-commit-to-client)
- [9. Your first week](#9-your-first-week)

---

## 1. What the system does

A client has a **dbt project** on a **warehouse** (Snowflake, Databricks or
BigQuery). The accelerator gives them, without installing Python or dbt:

```mermaid
mindmap
  root((dbt Portal))
    Build
      dbt Runner and schedules
      dbt Development IDE in the browser
      AI model and test generation
    Quality
      Elementary test reports
      Failed tests with samples
      SQL Linter history
      Profiler
    Understand
      dbt Docs
      Colibri column lineage
      Ask AI over the project and its data
      Semantic layer with Cube
    Cost
      DWH FinOps per warehouse
      Tuning advisor
    Run the platform
      Setup Assistant and onboarding
      Users, roles, audit trail
      Airflow and Airbyte modules
      Failure alerts
```

Two halves make that work:

- a **dbt package** (`capgemini_dbt_core`) the client installs with
  `dbt deps`: it routes framework tables to a metadata database, provisions
  it, and builds the FinOps and SQLFluff models;
- the **portal** (backend, frontend, cube, deploy): a web app that runs dbt
  on the client's project and turns what dbt produces into pages.

## 2. The five repos

```mermaid
flowchart TB
  subgraph pkg["Installed in the client's dbt project"]
    CORE["capgemini_dbt_core<br/>dbt package · macros · FinOps/SQLFluff models<br/>scripts/portal.py"]
  end
  subgraph portal["The portal (container images)"]
    BE["capgemini-dbt-portal-backend<br/>FastAPI API + dbt workers<br/>image: -backend"]
    FE["capgemini-dbt-portal-frontend<br/>React SPA + nginx gateway<br/>image: -frontend"]
    CU["capgemini-dbt-portal-cube<br/>Cube semantic engine<br/>image: -cube"]
  end
  DEP["capgemini-dbt-portal-deploy<br/>compose · Kubernetes · client kit<br/>releases.yml · e2e smoke test"]

  FE -- "public API (openapi.json → schema.gen.ts)" --> BE
  CU -- "/internal/cube contract" --> BE
  BE -- "runs dbt on the client project with" --> CORE
  CORE -- "portal.py drives /api/onboarding" --> BE
  DEP -- "pins tested versions of" --> BE & FE & CU
```

| Repo | Read next |
|---|---|
| `capgemini_dbt_core` | [docs/DEVELOPER_GUIDE.md](https://github.com/omaryehia015/capgemini_dbt_core/blob/main/docs/DEVELOPER_GUIDE.md), then `docs/technical/` |
| `capgemini-dbt-portal-backend` | [docs/README.md](https://github.com/omaryehia015/capgemini-dbt-portal-backend/blob/main/docs/README.md) |
| `capgemini-dbt-portal-frontend` | [docs/README.md](https://github.com/omaryehia015/capgemini-dbt-portal-frontend/blob/main/docs/README.md) |
| `capgemini-dbt-portal-cube` | [docs/GUIDE.md](https://github.com/omaryehia015/capgemini-dbt-portal-cube/blob/main/docs/GUIDE.md) |
| `capgemini-dbt-portal-deploy` (this repo) | [ARCHITECTURE.md](ARCHITECTURE.md), [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md), [ONBOARDING.md](ONBOARDING.md) |

The repos only work together when checked out **side by side** in one
folder (`../<repo>` paths in `compose.build.yaml`, `run-local.ps1` and the
frontend's `npm run gen:api`). The team workspace's `tools/ws.py clone` does
that.

## 3. The running system

```mermaid
flowchart LR
  U["User's browser"] -->|"HTTPS :8080"| FE

  subgraph host["One host or one Kubernetes namespace"]
    FE["frontend<br/>nginx: SPA + gateway"]
    BE["backend<br/>EXECUTION_ROLE=api<br/>identity · execution · insights · semantic"]
    WK["worker(s)<br/>python -m app.worker<br/>dbt subprocesses"]
    CU["cube"]
    PG[("PostgreSQL<br/>users, audit, run history,<br/>schedules, settings")]
    RD[("Redis<br/>job queue, live logs,<br/>cancel, cache events")]
    WS[/"workspace volume<br/>the client's dbt project"/]
    DATA[/"portal_data volume<br/>secret.key, Cube state, trash"/]
  end

  FE -->|"/api/*, WebSocket"| BE
  BE <-->|"jobs + logs"| RD
  RD <--> WK
  BE --> PG
  WK --> PG
  BE --- WS
  WK --- WS
  BE --- DATA
  WK --- DATA
  BE -->|"queries"| CU
  CU -->|"/internal/cube"| BE
  WK -->|"dbt"| DWH[("Client warehouse")]
  BE -->|"page reads"| DWH
  CU -->|"semantic queries"| DWH
```

Only the frontend port is published. The single-node variant
(`compose.single.yaml`) drops Redis, PostgreSQL and the worker: the backend
runs dbt itself on SQLite. Details per container:
[ARCHITECTURE.md](ARCHITECTURE.md).

## 4. A dbt run, end to end

What happens when an engineer clicks **Run** on the dbt Runner page:

```mermaid
sequenceDiagram
  autonumber
  actor E as Engineer
  participant FE as Frontend (SPA)
  participant GW as nginx gateway
  participant BE as Backend (API)
  participant R as Redis
  participant W as Worker
  participant DBT as dbt + capgemini_dbt_core
  participant DWH as Warehouse
  participant PG as PostgreSQL

  E->>FE: Run "dbt build -s orders+"
  FE->>GW: POST /api/dbt/execute (cookie + X-Portal-Client)
  GW->>BE: proxy
  BE->>BE: session valid? role has dbt.execute?
  BE->>R: LPUSH job request
  W->>R: BRPOP job request
  W->>W: build the plan from the project files
  W->>PG: run history row (running)
  W->>DBT: start subprocess
  W->>R: reply {job_id}
  R-->>BE: reply
  BE-->>FE: {job_id, status: running}
  FE->>BE: WebSocket /api/jobs/ws/{job_id}
  DBT->>DWH: client models → client database
  DBT->>DWH: Elementary hooks, stored test failures → metadata database
  loop every line
    DBT-->>W: stdout
    W->>R: XADD log line
    R-->>BE: stream
    BE-->>FE: {"type":"log"}
  end
  DBT-->>W: exit code
  W->>PG: final status, log tail
  W->>R: XADD status
  BE-->>FE: {"type":"status"}
  W-->>W: alerts (Slack/Teams/email) on failure, cache invalidation
  E->>FE: open Elementary / FinOps
  FE->>BE: GET /api/elementary/...
  BE->>DWH: read metadata tables
```

## 5. Onboarding a client project

```mermaid
flowchart TD
  subgraph install["Install the portal (pick one)"]
    I1["Windows: Install-DbtPortal.cmd<br/>(client kit installer)"]
    I2["curl … install.sh | bash<br/>or setup.sh / setup.ps1"]
    I3["python portal.py onboard<br/>(from capgemini_dbt_core)"]
    I4["kubectl apply -k deploy/kubernetes"]
  end
  install --> SA["Setup Assistant (Admin)<br/>workspace · warehouse login · dbt project<br/>(Git, local folder or image) · packages · modules · team"]
  SA --> OB["Onboarding page (5 steps, each a dbt job)"]
  OB --> S1["connect<br/>dbt debug"] --> S2["packages<br/>dbt deps"] --> S3["provision<br/>grant_package_access<br/>(metadata DB + schemas)"] --> S4["observability<br/>Elementary + FinOps models,<br/>project tests"] --> S5["artifacts<br/>docs, lineage,<br/>Elementary report"]
  S5 --> USE["Every page has data"]
  USE --> REF["Daily: portal.py refresh or schedules<br/>rebuild models, tests, reports"]
```

Every step is judged from real state (files, warehouse), not from clicks,
so re-running anything is safe. Full operator guide:
[ONBOARDING.md](ONBOARDING.md).

## 6. Where the data lives

| Data | Where | Owner |
|---|---|---|
| Client models | client database / schemas in the warehouse | the client's dbt project |
| Elementary, FinOps, profiler, SQLFluff history, stored test failures | **metadata database** (`DBT_PKG_DATABASE`), one schema per package | `capgemini_dbt_core` routing |
| Users, roles, sessions, audit trail | PostgreSQL (`portal_users`, ...) | backend identity service |
| Run history, schedules, settings (warehouse login encrypted) | PostgreSQL (`portal_job_history`, `portal_schedules`, `portal_settings`) | backend execution service |
| dbt artifacts (`manifest.json`, `run_results.json`, reports) | `target/` in the workspace volume | dbt, read by insights |
| Cube login and generated model | `/data/cube` | backend semantic service |
| Encryption key for stored secrets | `/data/secret.key` or `PORTAL_SECRET_KEY` | backend |
| Live logs, job queue | Redis (nothing survives a restart, nothing needs to) | backend + workers |

```mermaid
flowchart LR
  subgraph warehouse["Warehouse"]
    CDB[("client database<br/>STAGING · MARTS …")]
    subgraph MDB["metadata database (DBT_PKG_DATABASE)"]
      EL["ELEMENTARY"]
      FO["FINOPS"]
      PR["PROFILER"]
      SQ["SQLFLUFF"]
      TR["TEST_RESULTS"]
      GO["GOVERNANCE"]
      MO["SNOWFLAKE_MONITORING /<br/>BIGQUERY_MONITORING"]
    end
  end
  DBT["dbt run/test"] --> CDB
  DBT --> MDB
  PAGES["portal pages"] --> MDB
```

## 7. The contracts between repos

These break **silently** when only one side changes. Change both sides in
the same piece of work (the `cross-repo-contracts` skill has the checklist).

```mermaid
flowchart LR
  BE["backend"] -- "1 · public API<br/>openapi.json · API_VERSION" --> FE["frontend"]
  BE -- "2 · cube config API<br/>CONTRACT_VERSION" --> CU["cube"]
  CORE["core"] -- "3 · FinOps columns" --> BE
  BE -- "3 · FinOps columns" --> FE
  BE -- "4 · gateway routes<br/>services.py prefixes" --> FE
  BE -- "5 · client install contract<br/>/api/auth, /api/onboarding, /api/jobs,<br/>env vars, credentials banner" --> CORE
  CORE -- "6 · metadata_package_schemas" --> BE
  CORE -- "7 · versions.yml ↔ elementary-data pin" --> BE
  BE & FE & CU -- "8 · vX.Y.Z tags" --> DEP["deploy releases.yml"]
```

| # | Contract | Producer | Consumer | Guarded by |
|---|---|---|---|---|
| 1 | Public API | backend `openapi.json`, `API_VERSION` | frontend `schema.gen.ts`, `version.ts` | backend CI (stale schema), frontend `tsc`, version banner |
| 2 | Cube config API | backend `CONTRACT_VERSION` | cube `CONTRACT` | cube log error at start, `releases.yml` |
| 3 | FinOps columns | core `models/finops/` | backend FinOps service, frontend FinOps page | `pytest/test_finops_models.py` (core), `tests/test_finops_contract.py` (backend) |
| 4 | Gateway routes | backend `app/core/services.py` | frontend `nginx/default.conf.template` | review |
| 5 | Client install | backend auth/onboarding/jobs, env vars, log banner | core `scripts/portal.py` | `pytest/test_portal_script.py` |
| 6 | Package schemas | core `metadata_package_schemas` | backend onboarding | shared var, read at run time |
| 7 | Versions | core `versions.yml` | backend `requirements.txt` | review |
| 8 | Releases | each repo's tags | deploy `releases.yml` | e2e smoke test |

When a change spans repos, merge **producer first**: core → backend → cube
→ frontend → deploy.

## 8. From commit to client

```mermaid
flowchart LR
  subgraph comp["backend / frontend / cube"]
    BR["working branch<br/>feature/ fix/ chore/ …"] -->|"PR + pre-check"| DEV["dev"]
    DEV -->|"PR"| TEST["test"]
    TEST -->|"PR"| MAIN["main"]
    DEV & TEST & MAIN -->|"publish.yml"| IMG["ghcr image &lt;env&gt;-&lt;sha&gt;"]
    MAIN -->|"tag vX.Y.Z"| REL["images X.Y.Z, X.Y, latest"]
  end
  REL -->|"repository_dispatch"| E2E["deploy: e2e-smoke.yml<br/>new version + releases.yml latest of the others"]
  E2E -->|"passes"| RY["PR: add entry to releases.yml"]
  RY -->|"merge to main"| KIT["client-kit.yml<br/>zip + Windows installer<br/>GitHub release portal-&lt;release&gt;"]
  KIT --> CL["clients: setup.sh --release,<br/>manage.sh upgrade, portal.py --release"]
```

The core package promotes `dev → uat → main` and is consumed by clients
through `packages.yml` (git revision), not through images.

Nothing is committed or pushed without being asked, and pushes to
`dev`/`test`/`main` publish images: see the workspace `CLAUDE.md` for the
branch rules.

## 9. Your first week

```mermaid
journey
  title Getting productive
  section Day 1
    Clone the workspace (tools/ws.py clone): 5
    Run the stack (run-local.ps1), sign in as admin: 4
    Read this guide and ARCHITECTURE.md: 4
  section Day 2
    Backend guide: architecture and flows: 3
    Run pytest, change a small route, regenerate openapi.json: 3
  section Day 3
    Frontend guide, npm run dev against your backend: 3
    Follow a dbt run through the code: 4
  section Day 4-5
    Core developer guide, dbt parse, unittest: 3
    Pick a small issue, verify with tools/ws.py check: 4
```

Commands you will use every day (from the workspace folder):

```bash
python tools/ws.py status                 # branch and dirty files of every repo
python tools/ws.py check backend frontend # each repo's CI checks, locally
cd capgemini-dbt-portal-deploy && ./run-local.ps1   # whole stack at http://localhost:8090
```
