# Capgemini dbt Portal: deployment

How the portal's services are run together: compose files, the client kit,
Kubernetes manifests, and the list of releases. The code lives in three
repos, each released on its own:

| Repo | What | Images |
|---|---|---|
| [capgemini-dbt-portal-backend](https://github.com/omaryehia015/capgemini-dbt-portal-backend) | FastAPI: the portal API and its dbt workers | `-backend` |
| [capgemini-dbt-portal-frontend](https://github.com/omaryehia015/capgemini-dbt-portal-frontend) | React app + the gateway (nginx) | `-frontend` |
| [capgemini-dbt-portal-cube](https://github.com/omaryehia015/capgemini-dbt-portal-cube) | Cube, the semantic engine | `-cube` |
| this repo | how they run together, and which versions go together | none |

Images are published to `ghcr.io/omaryehia015/capgemini-dbt-portal-<name>`.
How the containers fit together: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Run it

**For a client or a shared server** (the portal API, dbt workers, PostgreSQL, Redis):

```bash
./deploy/client/setup.sh /path/to/dbt-project            # Windows: .\deploy\client\setup.ps1 -Project ...
```

The script writes `.env` (generated secrets, the project path, image tags
from [releases.yml](releases.yml)), starts [compose.yaml](compose.yaml) and
prints the first-login passwords. Clients get the same thing without this
repo, as the [client kit](deploy/client/README.md).

**On one laptop** (dbt runs inside the API container, SQLite, no Redis):
[compose.single.yaml](compose.single.yaml), or the dbt package's `portal.py`.

**On Kubernetes**: [deploy/kubernetes/](deploy/kubernetes/).

**From source, across the repos**: check the three repos out next to this
one, then `docker compose -f compose.yaml -f compose.build.yaml up --build -d`.

Every path, every setting, upgrades and moving an existing single-node
portal over: [docs/ONBOARDING.md](docs/ONBOARDING.md).

## Releases

Each component repo publishes its own versions (`vX.Y.Z` → images `X.Y.Z`,
`X.Y`, `latest`). A **portal release** is a combination of the three that
passed [the e2e smoke test](.github/workflows/e2e-smoke.yml) together, listed
in [releases.yml](releases.yml):

```yaml
releases:
  "2026.10.0":
    backend: "1.0.0"
    frontend: "1.0.0"
    cube: "1.0.0"
```

To cut one: tag the component repos, let their publish workflows finish (a
release tag also triggers the e2e smoke test here), then add the entry to
`releases.yml` through the usual PR flow. Merging it to `main` builds the
client kit ([client-kit.yml](.github/workflows/client-kit.yml)) and attaches
it to a `portal-<release>` GitHub release.

## Repository secrets

| Secret | Repo | Used for |
|---|---|---|
| `DEPLOY_REPO_TOKEN` | backend, frontend, cube | telling this repo a component was released (fine-grained token: Contents read/write here) |
| `GHCR_READ_TOKEN` | this repo | pulling the private images in the e2e test (a token with `read:packages`), unless the packages grant this repo read access |
| `TEAMS_WEBHOOK_URL` | backend, frontend, cube | pipeline notifications (optional) |

## Branches and CI

Every repo uses the same flow: working branch → `dev` → `test` → `main`
(pull requests, checked by `pre-check.yml`). Pushes to `dev`, `test` and
`main` publish `<env>-<sha>` images; a `vX.Y.Z` tag on `main` publishes a
release.
