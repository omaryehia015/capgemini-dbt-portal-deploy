# CHANGES: what was done in this work, what it adds, how to use it

This file describes **everything** changed in the deployment work: the deploy repository
(`capgemini-dbt-portal-deploy`) and the small change in the three component repositories.
**Nothing is committed or pushed**; all of it is in the working trees, waiting for your review.

Contents: [1. The goal](#1-the-goal) · [2. What was added](#2-what-was-added) ·
[3. What was removed](#3-what-was-removed) · [4. How to use it](#4-how-to-use-it) ·
[5. The workflows](#5-the-workflows) · [6. Secrets and settings to create](#6-secrets-and-settings-to-create) ·
[7. The change in the component repos](#7-the-change-in-the-component-repos) ·
[8. How it was checked](#8-how-it-was-checked) · [9. Before you commit](#9-before-you-commit) ·
[10. Known limits](#10-known-limits)

---

## 1. The goal

A client **downloads one script** and runs the portal from **pre-built images pulled from the registry**
(`ghcr.io/omaryehia015/capgemini-dbt-portal-{backend,frontend,cube}`). Nothing is built unless someone
asks for it (`--build`). Four ways to run it:

| Case | Mode | How it runs |
|---|---|---|
| Your computer, Windows or Linux, Docker or Podman | `local` | Docker/Podman Compose |
| Linux server, containers | `server` | Compose, started now |
| Linux server, as a service | `service` | the same Compose stack, run by a systemd unit that starts at boot |
| Kubernetes | `kubernetes` | the Helm chart |

The step-by-step client instructions are in the [README](README.md#install-it-as-a-client-step-by-step).

Image tags follow one convention for all three images: `dev-<commit-sha>`, `test-<commit-sha>`,
`prod-<commit-sha>` (Cube too). [releases.yml](releases.yml) is the list of backend + frontend + Cube
combinations that were tested together; nothing else decides which tags go together.

## 2. What was added

### 2.1 Compose (Docker or Podman Compose)

| File | What it is |
|---|---|
| `compose.yaml` | The full stack: frontend, backend, worker, Cube, PostgreSQL, Redis, and a one-shot `upgrade` step. Rewritten with YAML anchors (`x-backend`, `x-hardened`), hardened containers (`no-new-privileges`, `cap_drop: ALL`, seccomp `RuntimeDefault`), a settings file chosen by `PORTAL_ENV_FILE`, and **only the frontend published** (`PORTAL_BIND`). The backend, Cube, PostgreSQL and Redis stay on the internal network. |
| `compose.single.yaml` | One node: SQLite, no Redis, no worker. A laptop or a demo. |
| `compose.build.yaml`, `compose.single.build.yaml` | Overlays that **build from source** (`../capgemini-dbt-portal-{backend,frontend,cube}`) instead of pulling. Used only with `--build`. |
| `compose.cube-sql.yaml` | Overlay that publishes Cube's SQL port (15432) for BI tools; `CUBE_SQL_BIND` chooses the interface (`127.0.0.1` by default). |
| `.env.example` | Every setting, with the latest release's tags (kept in line by `scripts/sync-release.sh`), `PROJECT_SOURCE`, `PORTAL_BIND`, `CUBE_SQL_BIND`, `REDIS_APPENDONLY`, `PORTAL_WORKERS` and the source-build variables. |

### 2.2 The Helm chart: `deploy/helm/dbt-portal/`

Replaces the old Kustomize install. Contents: `Chart.yaml`, `values.yaml` (every setting, locked-down
defaults), `values-dev.yaml`, `values-test.yaml`, `values-prod.yaml`, `values.schema.json` (rejects typos,
public Service types for the backend and Cube, a missing Secret name), and templates for the backend, worker,
frontend, Cube, bundled PostgreSQL and Redis, Ingress, NetworkPolicy, PodDisruptionBudget, Secret, ConfigMap,
volumes and ServiceAccount, plus `NOTES.txt` and its own README.

- The chart pins **no application tag**: the three image tags are required values and come from `releases.yml`.
- The Secret is created by the chart for development (`secrets.create=true`, keys generated once and kept
  across upgrades with `lookup`) or **you** manage it for production (`secrets.create=false`).
- `ci/*.yaml` are value sets that CI renders to cover every template branch (not examples).
- Two optional pieces added later: the **OCI package** (2.5) and the **legacy migration hook** (2.6).

### 2.3 The manager script and its helpers: `scripts/`

| Script | What it does |
|---|---|
| `portal.sh` | The one command for everything: `init`, `check`, `up`, `down`, `logs`, `pull`, `build`, `clean`, `release`, and `helm-template`, `helm-install`, `helm-upgrade`, `helm-status`, `helm-rollback`, `helm-uninstall`. Docker or Podman is detected. Options: `--single`, `--build`, `--cube-sql`, `--engine`, `--env-file`, `--values`, `--release`, `--set`, `--name`, `--namespace`, `--volumes`, `--yes`, `--pull-secret`, `--chart`, `--chart-version`. Secrets are never printed; the registry token reaches `kubectl`/`helm` only on stdin. It works from this repo and from the unpacked client kit. |
| `release-tags.sh` | Turns a release of `releases.yml` into the three image tags: `--list`, `--format env\|helm-values\|helm-set\|json`, `--write-env FILE`. |
| `build-kit.sh` | Assembles the client kit of a release (compose files, scripts, the chart without the CI value sets, that release's tags). The kit has **no build files**. |
| `add-release.sh` | Adds a release to `releases.yml`, makes it `latest`, then runs `sync-release.sh`. Keeps the file's line endings; restores `releases.yml` if anything fails. |
| `sync-release.sh` | Brings what repeats the latest release into line: `.env.example`'s three tags and the chart's `appVersion`. `--check` only reports. |
| `record_image.py` | Validates and writes an image record (`images/<env>.yaml`); refuses malformed or hostile input. |
| `validate.sh` + `check_manifests.py` | Every check CI runs (see [8](#8-how-it-was-checked)). Each check ends **PASSED, FAILED or NOT RUN**; a missing tool is never reported as a pass. |

### 2.4 The client kit: `deploy/client/`

- `install.sh` and `install.ps1`: the **one script per OS** a client downloads. `PORTAL_MODE` selects the
  case (`local`, `server`, `service`, `kubernetes`); on Windows only `local`.
- `setup.sh`, `manage.sh`, `lib.sh` (and the `.ps1` twins): setup, daily management, shared helpers. New:
  `PORTAL_ENGINE` (pin Docker or Podman), `PORTAL_WORKERS`, and `manage.sh service install|uninstall|print`, which writes
  the **systemd unit** (a oneshot unit that stays active and runs `manage.sh start`/`stop`; a system unit for
  Docker or rootful Podman, a `--user` unit with lingering for rootless Podman).
- `download/index.html`: the download page, with a mode selector that builds the command.
  `download/Install-DbtPortal.cmd`: the Windows double-click launcher (kept).
- `README.md`: the client's full guide (modes, service, Kubernetes, backups, troubleshooting).

### 2.5 The chart as an OCI artifact on GHCR

The `chart` job of `client-kit.yml` packages the chart with `helm package --version <release> --app-version <release>`
and pushes it to `oci://ghcr.io/<owner>/charts/dbt-portal`, then reads it back from the registry. The chart's
**version is the release's name**. `portal.sh` gained `--chart REF` (a folder or an `oci://` reference) and
`--chart-version`; with an OCI chart `--values` is required, and the registry login uses `PORTAL_TOKEN` on stdin.

### 2.6 The optional legacy migration hook (pre-2026.11 databases)

`postgres/upgrade.sh` moves the two old databases (`portal_identity`, `portal_execution`) into one (`portal`).
Compose runs it through the `upgrade` service. For Kubernetes the chart has `legacyMigration.enabled`
(**off by default**): a Helm hook Job that runs a copy of the script (`deploy/helm/dbt-portal/files/upgrade.sh`;
`validate.sh helm` fails if the two differ).

- Bundled PostgreSQL: runs on `helm upgrade`.
- External database: runs on `helm install` and `helm upgrade`; needs `legacyMigration.database.host` and
  `legacyMigration.passwordSecret.name` (a Secret that already exists), and the target database must be `portal`.
- The old databases are kept; it does nothing on a new install or once moved. Only the database is moved, not
  the old volumes' files.

### 2.7 Image records: what each environment last published

`images/dev.yaml`, `test.yaml`, `prod.yaml` hold the newest `image`, `tag`, `commit`, `published` time and
pipeline run of each component. They are written by `record-image.yml` from the component pipelines (7).
They are **information, not a tested combination**; `releases.yml` is the tested map.

### 2.8 Release automation

`new-release.yml` (Actions > New Release) runs `add-release.sh` on `dev` with the newest `prod` images from
`images/prod.yaml` (or tags you type), and opens a pull request `release/<name>` into `dev` containing the
new `releases.yml` entry, the synced `.env.example` and the chart's `appVersion`. Its e2e-smoke run starts a
real stack from exactly those tags: merge only when it passes. Before this, those three places were
checked by CI but updated by hand.

### 2.9 Documentation

New: `docs/DEPLOYMENT.md`, `docs/KUBERNETES.md`, this `CHANGES.md`. Rewritten or updated: `README.md` (client
step-by-step guide, run-from-repo table, releases and image records, secrets, CI table), `docs/ONBOARDING.md`,
`docs/DEVELOPER_GUIDE.md`, `docs/ARCHITECTURE.md`, `docs/SYSTEM_GUIDE.md`, `docs/SEMANTIC_LAYER.md`,
`deploy/client/README.md`, the chart's README. `docs/architecture.drawio/.png` and
`docs/data-flow-architecture.drawio/.png` were **left as they were** (the architecture diagram is stale).

### 2.10 Outside the repos: Claude Code hooks

In `E:\eda\.claude\` (project settings): a hook that blocks `git commit`, and one that blocks editing files
with Python. They only affect Claude Code sessions in that folder.

## 3. What was removed

| Removed | Why |
|---|---|
| `deploy/kubernetes/` (11 files: the Kustomize install) | Replaced by the Helm chart. A migration guide is in `docs/KUBERNETES.md`. |
| `deploy/client/installer/` (the signed `DbtPortalSetup.exe` builder) and the `app` job of `client-kit.yml` | Not needed: clients use `install.ps1` or `Install-DbtPortal.cmd`. The `CODESIGN_PFX_BASE64` and `CODESIGN_PASSWORD` secrets are no longer used. |
| `deploy/vm/` (systemd + nginx for a bare VM) | Not one of the supported cases; `service` mode covers containers at boot. |
| `deploy/bake/Dockerfile` (dbt project baked into the image) | Not one of the supported cases. |
| `run-local.ps1` | `scripts/portal.sh --build up` does the same. |
| `.trivyignore` | Nothing in this repo used it (the image scan belongs to the component repos). |

`Install-DbtPortal.cmd` stays: it is a self-contained file that PowerShell runs, so it does not need the deleted installer folder.

## 4. How to use it

### As a client (one script)

```bash
T='<access token you were sent>'
R=https://raw.githubusercontent.com/omaryehia015/capgemini-dbt-portal-deploy/main/deploy/client/install.sh

curl -fsSL $R | PORTAL_TOKEN=$T bash                                      # 1  this computer (Linux/macOS)
curl -fsSL $R | sudo env PORTAL_TOKEN=$T PORTAL_MODE=server bash          # 2a a server, Compose
curl -fsSL $R | sudo env PORTAL_TOKEN=$T PORTAL_MODE=service bash         # 2b a server, systemd service
curl -fsSL $R | PORTAL_TOKEN=$T PORTAL_MODE=kubernetes bash               # 3  Kubernetes, a trial install
```

Windows: open `Install-DbtPortal.cmd`, or in PowerShell set `$env:PORTAL_TOKEN` and run
`irm …/install.ps1 | iex`. `PORTAL_RELEASE` picks a release, `PORTAL_DIR` the folder. All the steps, production on
Kubernetes, upgrade and removal for each case: [README](README.md#install-it-as-a-client-step-by-step).

### From this repo (developers and operators)

```bash
scripts/portal.sh init                  # .env from .env.example; empty secrets generated, never printed
scripts/portal.sh check                 # tools, settings, project source, tags, Compose rendering
scripts/portal.sh up                    # pulls the images, then http://localhost:8080
scripts/portal.sh --single up           # one-node demo
scripts/portal.sh --build up            # build from the three sibling repos instead of pulling
scripts/portal.sh helm-template --values deploy/helm/dbt-portal/values-dev.yaml
scripts/portal.sh helm-install  --values deploy/helm/dbt-portal/values-dev.yaml --pull-secret
scripts/portal.sh helm-install  --chart oci://ghcr.io/<owner>/charts/dbt-portal --release 2026.10.19 --values my.yaml
scripts/validate.sh                     # everything CI checks
```

### Cutting a release

1. Let the component publish workflows finish (their `prod-<sha>` tags land in `images/prod.yaml`).
2. Actions > **New Release** > name such as `2026.11.0` (+ notes). Review and merge the pull request into `dev`
   when its e2e-smoke run passes, then promote `dev → test → main`.
3. Merging to `main` runs **Client Kit**: the kit zip, the `portal-<release>` GitHub release and the OCI chart.

By hand: `scripts/add-release.sh --name 2026.11.0 --from-images --notes "…"`; `scripts/sync-release.sh --check`
lists anything out of date.

### Upgrading and the migration hook

Clients upgrade by running the same install command with `PORTAL_RELEASE=<newer>` (or `./manage.sh upgrade`).
For Kubernetes databases from before 2026.11: `--set legacyMigration.enabled=true` plus the host and Secret for an
external database ([docs/KUBERNETES.md](docs/KUBERNETES.md#upgrade-rollback-uninstall)).

## 5. The workflows

| Workflow | Runs on | Does |
|---|---|---|
| `pre-check.yml` | pull requests | Promotion path (working branch → dev → test → main; `release/*` and `images/*` branches allowed where meant), Gitleaks, ShellCheck, and image-record pull requests may change only their own file. |
| `validate.yml` | pull requests and pushes | `scripts/validate.sh`: YAML, ShellCheck, Compose and Helm rendered and checked (kubeconform on Kubernetes 1.28, 1.31, 1.33), the client kit, image records, `releases.yml` consistency, no secret files. Renders only. |
| `e2e-smoke.yml` | pull requests, on demand, `component-released` | Starts a real Compose stack from published images and runs the Playwright smoke test (sign in, run `dbt debug`, see it in history). |
| `kubernetes-smoke.yml` | pull requests touching the chart or its scripts, on demand | Throwaway **kind** cluster, `portal.sh helm-install`, the same Playwright test through a port-forward. Validation only. |
| `client-kit.yml` | `releases.yml` changed on `main`, on demand | Builds and attaches the kit and the Windows launcher; pushes the chart to GHCR. |
| `record-image.yml` | `image-published` from a component pipeline, on demand | Opens or updates the pull request that records the image in `images/<env>.yaml`. |
| `new-release.yml` | on demand | Opens the pull request that adds a release (see 2.8). |

## 6. Secrets and settings to create

| Name | Where | For |
|---|---|---|
| `DEPLOY_REPO_TOKEN` | backend, frontend, cube repos | Their pipelines send `image-published` to this repo. A fine-grained token for **this** repo (Contents: read and write: the dispatch API requires it). Without it the job warns and the image is still published. |
| `IMAGE_PR_TOKEN` | this repo | `record-image.yml` and `new-release.yml` open pull requests with it so the checks run on them (Contents and Pull requests: read and write). Optional, but without it those checks do not start by themselves and "Allow GitHub Actions to create and approve pull requests" must be on. |
| `GHCR_READ_TOKEN` | this repo | Pulling the private images in `e2e-smoke.yml` and `kubernetes-smoke.yml` (`read:packages`), unless the packages grant this repo read access. |
| `DEPLOY_REPOSITORY` (variable) | component repos | Only if the deploy repo is not `<owner>/capgemini-dbt-portal-deploy`. |
| `TEAMS_WEBHOOK_URL` | component repos | Pipeline notifications (optional, as before). |

No real secret was written to any file. The chart package on GHCR is private, like the images, until its
visibility is changed in the GitHub package settings.

## 7. The change in the component repos

`capgemini-dbt-portal-backend`, `-frontend` and `-cube`: **one file each**,
`.github/workflows/reusable-container.yml`, got a last job **`record-in-deploy-repo`**.

- Runs after the image is pushed (`needs: container`, `if: inputs.push_image`, `permissions: {}`).
- Skips with a warning when `DEPLOY_REPO_TOKEN` is not set or the environment is not dev, test or prod.
- Fails if the tag is not `<env>-$GITHUB_SHA`.
- Sends a `repository_dispatch` event `image-published` (component, environment, image, tag, commit, run URL,
  time, actor) to the deploy repo; the token goes to `curl` on stdin, not on the command line.

## 8. How it was checked

`scripts/validate.sh` (last full run before the final clean-up of removed folders): **43 passed, 0 failed,
3 not run**. After the clean-up, the YAML, releases, secrets, stale-reference and kit groups were re-run
(15 passed, 0 failed). The checks cover YAML/JSON parsing; `bash -n` and ShellCheck (`-x -S warning`) on every
script; Compose (full, single, source-build, Cube SQL) rendering and assertions; `portal.sh init/check`;
Helm lint `--strict`, every value set rendered and asserted, invalid settings refused with clear messages,
kubeconform `-strict` on three Kubernetes versions; the OCI package (`helm package` reads back as the release);
`portal.sh --chart oci://…` against a helm stand-in (reference, version, token on stdin only); the legacy hook
(off by default, hook kinds, same script); the kit (contents, no build files, flat layout, systemd unit text,
Kubernetes flow with `kubectl`/`helm` replaced by recorders); the image-record tool; the release scripts on a copy
of the repo; no secret files tracked.

**NOT RUN (could not be, on the machine used):**

- A real container start with Docker or Podman, and Podman Compose rendering.
- `systemctl` (the systemd unit text is checked, not installed).
- The real download of `install.sh`/`install.ps1` and the Windows window.
- A real cluster: `kubectl apply --dry-run=server`, `helm install`, and the **kind job** (the workflow parses,
  but its first real run is the real test). The legacy hook against a real old database.
- Pushing or pulling the chart on GHCR; the real GitHub workflows; Gitleaks.

## 9. Before you commit

1. Review `git status` in the four repos. Everything here is uncommitted.
2. Keep the scripts executable: `git add --chmod=+x scripts/*.sh deploy/client/*.sh postgres/upgrade.sh`
   (Windows checkouts lose the bit).
3. Create the secrets in [6](#6-secrets-and-settings-to-create).
4. Open the changes as pull requests through `dev → test → main`; `pre-check.yml` enforces the path.
5. After the first merge to `main`, **re-run Client Kit** for the latest release so the kit includes the new modes
   (the existing zip of the latest release predates them) and the chart is pushed to GHCR.
6. Watch the first runs of `kubernetes-smoke.yml` and `new-release.yml` and fix what a real runner shows.

## 10. Known limits

- `releases.yml`'s two newest entries pin `prod-<sha>` for backend and frontend; older entries use version tags
  and every entry still pins Cube `1.0.1`, from before its pipeline published `prod-<sha>`. Tools take whatever
  the entry holds, so the next entry can use Cube's `prod-<sha>`.
- The bundled PostgreSQL and Redis in the chart are for development and trials (one pod, one disk each);
  production uses managed ones.
- The Compose stack publishes the portal on every interface by default (`PORTAL_BIND`): put a firewall or a
  TLS reverse proxy in front of a server.
- The legacy migration moves databases only; Compose's copy of the old volumes' files is not repeated on Kubernetes.
- `docs/architecture.drawio/.png` is stale (it shows the old layout) and was left alone on request.
