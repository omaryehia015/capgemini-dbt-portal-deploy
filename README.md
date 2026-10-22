# Capgemini dbt Portal: deployment

How the portal's services are run together: the Compose files, the Helm chart, the client kit
that clients download, the record of what each environment last published, and the list of
tested releases. The code lives in three repos, each released on its own:

| Repo | What | Image |
|---|---|---|
| [capgemini-dbt-portal-backend](https://github.com/omaryehia015/capgemini-dbt-portal-backend) | FastAPI: the portal API and its dbt workers | `capgemini-dbt-portal-backend` |
| [capgemini-dbt-portal-frontend](https://github.com/omaryehia015/capgemini-dbt-portal-frontend) | React app and the gateway (nginx) | `capgemini-dbt-portal-frontend` |
| [capgemini-dbt-portal-cube](https://github.com/omaryehia015/capgemini-dbt-portal-cube) | Cube, the semantic engine | `capgemini-dbt-portal-cube` |
| this repo | how they run together, and which versions go together | none |

Images are published to `ghcr.io/omaryehia015/capgemini-dbt-portal-<name>`, each tagged
`dev-<commit-sha>`, `test-<commit-sha>` or `prod-<commit-sha>` by its own pipeline.
How the containers fit together: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

**New to the team?** Start with [docs/SYSTEM_GUIDE.md](docs/SYSTEM_GUIDE.md): the whole
accelerator end to end (repos, a dbt run, onboarding, data, contracts, releases), with diagrams.
Changing this repo: [docs/DEVELOPER_GUIDE.md](docs/DEVELOPER_GUIDE.md). What was added, removed and how to
use it, in one place: [CHANGES.md](CHANGES.md).

## Install it as a client: step by step

You download **one script**, run it, and the portal runs from **pre-built images pulled from the
registry**. Nothing is built, and you do not need this repository, Python, Node or dbt.

**What you need first, in every case**

- The **access token** you were sent (read-only; it lets this machine pull the private images). The
  scripts sign in to the registry with it (they hand it over on stdin and never print it). Your own shell
  history will contain it if you type it into a command, so paste the commands from a place you trust.
- The tools of your case (listed under each one).

**Pick your case**

| # | Where you want it | `PORTAL_MODE` | Section |
|---|---|---|---|
| 1 | **Your own computer**, Windows or Linux (also macOS), with Docker or Podman | `local` (default) | [1](#1-on-your-own-computer-windows-or-linux) |
| 2a | **A Linux server**, run as a plain Docker/Podman Compose stack | `server` | [2a](#2a-a-linux-server-as-a-docker-compose-stack) |
| 2b | **A Linux server**, run as a **service** that starts at boot (systemd) | `service` | [2b](#2b-a-linux-server-as-a-service-that-starts-at-boot) |
| 3 | **Kubernetes**, with Helm | `kubernetes` | [3](#3-on-kubernetes-with-helm) |

Every Linux/macOS command below uses these two variables (paste them once in your terminal):

```bash
T='<the access token you were sent>'
R=https://raw.githubusercontent.com/omaryehia015/capgemini-dbt-portal-deploy/main/deploy/client/install.sh
```

`PORTAL_RELEASE=<name>` (any release listed in [releases.yml](releases.yml)) installs another release than
the latest, and `PORTAL_DIR=<folder>` changes where the kit is unpacked. If downloading `install.sh` itself is
refused (a private repository), add `-H "Authorization: Bearer $T"` to the `curl`.

### 1. On your own computer (Windows or Linux)

**You need:** Docker Desktop (Windows, macOS) or Docker Engine with the Compose plugin (Linux), **or** Podman
(Podman Desktop on Windows) with a compose provider. It must be **running**. On Linux or macOS,
`./setup.sh --check` (in the kit) checks the memory, disk and Docker/Podman and says what is missing.

**Windows, double-click:**

1. Download **`Install-DbtPortal.cmd`** (from the [download page](deploy/client/download/index.html) or from the
   `portal-<release>` GitHub release of this repository) and open it. If Windows warns that it protected your
   PC, click **More info**, then **Run anyway**.
2. In the window, paste the **access token** and start the install. (*More options*: a dbt project folder on this
   computer, another install folder.)
3. Wait. It starts Docker Desktop or Podman if they are installed but stopped, pulls the images, starts
   everything, opens the portal at **http://localhost:8080**, shows the **admin password** and puts a
   **dbt Portal** shortcut on your desktop.

**Windows, PowerShell instead:**

```powershell
$env:PORTAL_TOKEN = "<the access token you were sent>"
irm https://raw.githubusercontent.com/omaryehia015/capgemini-dbt-portal-deploy/main/deploy/client/install.ps1 | iex
```

**Linux (and macOS):**

```bash
curl -fsSL $R | PORTAL_TOKEN=$T bash
```

It downloads the kit into `~/dbt-portal`, signs in to the registry, pulls the images, starts the portal and
opens http://localhost:8080. Docker is used when it works, otherwise Podman (`PORTAL_ENGINE=podman` forces
Podman). To use a dbt project folder on this computer instead of Git, add its path:
`curl -fsSL $R | PORTAL_TOKEN=$T bash -s -- ~/work/my-dbt-project`.

**Then, in every case:**

1. Sign in as **`admin`** with the password printed at the end of the install (`GENERATED INITIAL CREDENTIALS`,
   shown once). Change it under **My account**. Lost it? `./manage.sh reset-password`
   (Windows: `.\manage.ps1 reset-password`) prints a new one.
2. The **Setup Assistant** (`/setup`) walks you through the warehouse connection and your dbt project
   (a **Git repository**, a folder on this computer, or a Docker image with the project).

**Day to day** (in the install folder, `~/dbt-portal`; Windows: `.\manage.ps1 <command>`):

```bash
./manage.sh status               # is everything up, does the portal answer
./manage.sh logs backend         # follow a log
./manage.sh stop                 # stop (data is kept)      ./manage.sh start    # start again
./manage.sh backup               # a backup now (it also makes one every day)
```

**Upgrade:** run the same install command again, with `PORTAL_RELEASE=<newer>` (or
`./manage.sh upgrade <newer>`). Accounts, history and settings are kept.
**Remove:** in the install folder, `docker compose down -v` (`podman compose down -v`). This **deletes** the
accounts and history; without `-v` the data stays. Your dbt project is never deleted.

### 2a. A Linux server, as a Docker Compose stack

**You need:** a Linux server with Docker Engine + the Compose plugin, or Podman + a compose provider, and
`curl` and `unzip` (or `python3`). Run as **root** (`sudo`), or as a user who can use Docker or rootless Podman.

```bash
curl -fsSL $R | sudo env PORTAL_TOKEN=$T PORTAL_MODE=server bash
```

1. It installs into **`/opt/dbt-portal`** (as a normal user: `~/dbt-portal`), pulls the images, starts the
   stack and prints the **admin password** once. It does not open a browser.
2. Open **`http://<server address>:8080`** from your own machine and sign in as `admin`. The port is open on
   every interface: put a **firewall** or a TLS reverse proxy in front of it for anything beyond a trial.
3. Finish in the portal's **Setup Assistant**, as above.

Docker restarts the containers when the server reboots; **Podman does not**. If the server must come back by
itself after a reboot with Podman (or you want a managed unit), use case 2b.

**Day to day** (`cd /opt/dbt-portal`): `./manage.sh status | logs <service> | stop | start | backup`.
**Upgrade:** repeat the command with `PORTAL_RELEASE=<newer>`. **Remove:** `docker compose down -v` there (it
deletes the data).

### 2b. A Linux server, as a service that starts at boot

The same Compose stack, run by a **systemd** unit (`dbt-portal`): it starts at boot and stops cleanly.

**You need:** a Linux server with systemd, Docker or Podman with Compose, `curl`, `unzip` (or `python3`).

```bash
# Docker, or rootful Podman: as root
curl -fsSL $R | sudo env PORTAL_TOKEN=$T PORTAL_MODE=service bash

# rootless Podman: as your own user, no sudo (a user service; lingering is turned on for you)
curl -fsSL $R | PORTAL_TOKEN=$T PORTAL_MODE=service bash
```

It installs the stack into `/opt/dbt-portal` (rootless: `~/dbt-portal`), starts it, then installs and
enables the unit. Docker is a system service, so Docker needs the root form.

1. **Check the service:** `sudo systemctl status dbt-portal` (rootless: `systemctl --user status dbt-portal`).
2. **Open** `http://<server address>:8080`, sign in as `admin` with the password printed at the end of the
   install, and finish in the **Setup Assistant**. Firewall the port as in 2a.
3. **Prove it survives a reboot:** `sudo reboot`, then open the portal again.

**Day to day:** `sudo systemctl restart|stop|start dbt-portal`, plus `./manage.sh status | logs | backup` in the
install folder. **More dbt jobs at once:** `sudo ./manage.sh service install --workers 3`.
**Upgrade:** repeat the command with `PORTAL_RELEASE=<newer>`.
**Remove the service:** `sudo ./manage.sh service uninstall` (containers and data stay), then
`docker compose down -v` in the folder if you also want the data gone.

### 3. On Kubernetes, with Helm

**You need:** a cluster with a default **StorageClass** (the volumes), **`helm` 3** and **`kubectl`** on your
machine and **pointed at that cluster** (`kubectl config current-context` shows which one), and the access token.
The images are pulled by the cluster: the installer makes a pull Secret `ghcr-pull` from your token for you.

**Trial** (bundled PostgreSQL and Redis, one pod and one disk each: to look at the portal, not for production):

```bash
curl -fsSL $R | PORTAL_TOKEN=$T PORTAL_MODE=kubernetes bash
```

1. It unpacks the kit into `~/dbt-portal`, creates the namespace `dbt-portal` and the pull Secret, shows the
   cluster it is about to use and **asks you to type `yes`**, then runs `helm install` and waits (up to 10 minutes)
   until everything is ready.
2. **Reach it:** `kubectl -n dbt-portal port-forward svc/dbt-portal-frontend 8080:8080`, then open
   **http://localhost:8080**.
3. **Sign in:** `kubectl -n dbt-portal logs deploy/dbt-portal-backend | grep -A6 "GENERATED INITIAL CREDENTIALS"`
   prints the `admin` password (once); finish in the **Setup Assistant**.

**Production** (your own PostgreSQL and Redis, your Secret, your ingress): do not run the trial first,
it uses a different Secret and bundled databases. From a machine with `helm` and `kubectl`:

1. **Get the kit** of a release: download `dbt-portal-client-kit-<release>.zip` from the `portal-<release>`
   GitHub release of this repository and unzip it (`~/dbt-portal`). It holds the chart and `portal.sh`.
2. **Create the namespace and your Secret** (JWT and Cube keys, the portal key, your database and Redis URLs):

   ```bash
   kubectl create namespace dbt-portal
   kubectl -n dbt-portal create secret generic dbt-portal-secrets \
     --from-literal=JWT_SECRET="$(openssl rand -base64 48 | tr -d '/+=\n')" \
     --from-literal=CUBE_API_SECRET="$(openssl rand -base64 48 | tr -d '/+=\n')" \
     --from-literal=PORTAL_SECRET_KEY="$(openssl rand -base64 32 | tr '+/' '-_')" \
     --from-literal=DATABASE_URL='postgresql+psycopg2://portal:<password>@<host>:5432/portal' \
     --from-literal=REDIS_URL='redis://:<password>@<host>:6379/0'
   ```

   Keep `PORTAL_SECRET_KEY` in your secret manager: losing it makes the stored warehouse logins unreadable.
   A private dbt Git repository also needs the key `DBT_PROJECT_GIT_TOKEN` in this Secret.
3. **Write your values file** `my-prod.yaml` (keep it out of git). Start from
   `deploy/helm/dbt-portal/values-prod.yaml` in the kit: copy it and add your Git URL, storage class and ingress:

   ```yaml
   project: {git: {url: https://github.com/<org>/<repo>.git, ref: main}}
   workspace: {persistence: {storageClass: <a ReadWriteMany class>}}
   ingress:
     enabled: true
     className: <your ingress class>
     hosts: [{host: portal.example.com}]
     tls: [{secretName: <tls secret>, hosts: [portal.example.com]}]
   ```

4. **Read what will be installed, then install:**

   ```bash
   cd ~/dbt-portal
   ./portal.sh helm-template --values my-prod.yaml                        # renders only, touches nothing
   PORTAL_TOKEN=$T ./portal.sh helm-install --pull-secret --values my-prod.yaml   # shows the cluster, asks 'yes'
   ```

5. **Open** `https://portal.example.com` (your ingress host) and read the first `admin` password from the
   backend log (`kubectl -n dbt-portal logs deploy/dbt-portal-backend | grep -A6 "GENERATED INITIAL CREDENTIALS"`).

**Day to day:** `./portal.sh helm-status`, `helm-rollback`, `helm-uninstall` (the volumes are kept unless you add
`--volumes`). **Upgrade:** unzip the newer release's kit over the folder and run
`PORTAL_TOKEN=$T ./portal.sh helm-upgrade --pull-secret --values my-prod.yaml` (the trial: run the same install
command again with `PORTAL_RELEASE=<newer>`; it sees the release and upgrades). The same chart is also on
the registry: [docs/KUBERNETES.md](docs/KUBERNETES.md#installing-the-chart-from-the-registry-no-zip-no-checkout).
Every setting, storage, ingress, security and the Secret keys: [docs/KUBERNETES.md](docs/KUBERNETES.md).

More on each case (backups and restore, troubleshooting, settings): [deploy/client/README.md](deploy/client/README.md).

The kit these scripts download is built by `scripts/build-kit.sh` (compose files, scripts, the chart, the release's
tags; no build files) and attached to a `portal-<release>` GitHub release; the same workflow publishes the chart to
GHCR as `oci://ghcr.io/<owner>/charts/dbt-portal`, version = the release. The
[download page](deploy/client/download/index.html) builds the command for you.

The kit these scripts download is built by `scripts/build-kit.sh` (compose files, scripts, the chart, the release's tags; no
build files) and attached to a `portal-<release>` GitHub release; the same workflow publishes the chart to GHCR as
`oci://ghcr.io/<owner>/charts/dbt-portal`, version = the release. The [download page](deploy/client/download/index.html)
builds the command for you.

## Run it from this repo (developers and operators)

Images are always **pulled** from the registry by default; building from source is an explicit
option (`--build`).

| Where | How | Guide |
|---|---|---|
| One machine, Docker **or** Podman Compose | `scripts/portal.sh init && scripts/portal.sh up` | [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) |
| One laptop, a demo (SQLite, no Redis, no worker) | `scripts/portal.sh --single up` | [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#the-two-modes) |
| From source, the three repos side by side | `scripts/portal.sh --build up` | [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#images-published-or-built-from-source) |
| Kubernetes | `scripts/portal.sh helm-install --values deploy/helm/dbt-portal/values-dev.yaml` | [docs/KUBERNETES.md](docs/KUBERNETES.md) |
| Kubernetes, chart from the registry | `helm install dbt-portal oci://ghcr.io/<owner>/charts/dbt-portal --version <release> -f ...` | [docs/KUBERNETES.md](docs/KUBERNETES.md#installing-the-chart-from-the-registry-no-zip-no-checkout) |
| **A client, without this repo** | download one script, `install.sh` (Windows: `Install-DbtPortal.cmd` or `install.ps1`) | [Install it as a client](#install-it-as-a-client-step-by-step) |

```bash
scripts/portal.sh init      # .env from .env.example; the empty secrets are generated, never printed
scripts/portal.sh check     # tools, settings, project source, image tags, Compose rendering
scripts/portal.sh up        # docker compose, else podman compose; then http://localhost:8080
```

Only the frontend is published: the backend, Cube, PostgreSQL and Redis stay on the internal
network (Cube's SQL API for BI tools is on `127.0.0.1` only, until you open it). Every path, every
setting, upgrades and moving an existing single-node portal over:
[docs/ONBOARDING.md](docs/ONBOARDING.md).

## What is in this repo

```
compose.yaml  compose.single.yaml        the full stack, and one node (SQLite, no Redis, no worker)
compose.build.yaml  compose.single.build.yaml  build from ../capgemini-dbt-portal-{backend,frontend,cube}
compose.cube-sql.yaml                    publish Cube's SQL API (BI tools)
.env.example                             every setting (copy to .env: git-ignored)
releases.yml                             tested backend + frontend + Cube combinations
images/                                  the newest image of each component per environment (dev, test, prod)
scripts/                                 portal.sh, release-tags.sh, build-kit.sh, validate.sh,
                                         add-release.sh, sync-release.sh, check_manifests.py, record_image.py
deploy/helm/dbt-portal/                  the Helm chart (values for dev, test and prod; schema)
deploy/client/                           the client kit: setup, manage, install (.sh and .ps1), the download page
postgres/upgrade.sh                      one-off migration from the pre-2026.11 layout (Compose runs it; on Kubernetes it
                                         is the chart's optional pre-upgrade hook, `legacyMigration.enabled`)
e2e/                                     Playwright smoke test of a whole stack
docs/                                    architecture, deployment, Kubernetes, onboarding, guides
```

Check the deployment assets before you push: `scripts/validate.sh` (what CI runs; every check ends
PASSED, FAILED or NOT RUN, and a missing tool is never reported as a pass).

## Releases and image records

**A portal release** is a combination of backend, frontend and Cube images that passed
[the e2e smoke test](.github/workflows/e2e-smoke.yml) together, listed in
[releases.yml](releases.yml). It is the tested compatibility map; nothing else decides which tags go
together.

All three images follow the same convention, so a release pins each one to the `prod-<commit-sha>`
its pipeline published:

```yaml
latest: "2026.10.19"
releases:
  "2026.10.19":
    backend: "prod-<backend commit sha>"
    frontend: "prod-<frontend commit sha>"
    cube: "prod-<cube commit sha>"
    notes: >-
      What changed, and which components must be upgraded together.
```

In [releases.yml](releases.yml) the two newest entries pin backend and frontend that way (older ones use
release versions such as `1.7.1`), and every entry still lists Cube as `1.0.1`, from before its pipeline
published `prod-<sha>`. Tools take whatever tag the entry holds, so the next entry can use Cube's
`prod-<sha>` with no other change.

`scripts/release-tags.sh` turns a release into the three tags (`--list` shows them all, `--format
helm-values` and `--write-env .env` feed Helm and Compose).

**To cut a release**, let the component publish workflows finish, then run
[New Release](.github/workflows/new-release.yml) (Actions > New Release > Run workflow; a name such as
`2026.11.0`, optional notes). It takes the newest `prod` images recorded in `images/prod.yaml` (or tags you
type), adds the entry at the top of `releases.yml`, makes it `latest`, updates what repeats the latest
release (`.env.example`'s image tags and the chart's `appVersion`) and opens a pull request into `dev`.
That pull request's e2e-smoke run starts a real stack from exactly the tags of the new entry: merge it
only when that passes, then promote it like any change. The same thing locally:
`scripts/add-release.sh --name 2026.11.0 --from-images --notes "..."`; `scripts/sync-release.sh` re-syncs
the repeated places from `releases.yml` (`--check` only reports), and `scripts/validate.sh releases` fails
until they match. Merging to `main` builds the client kit and publishes the chart
([client-kit.yml](.github/workflows/client-kit.yml)).

**Image records.** Whenever a component pipeline pushes an image, its last job, *Record the image in the
deploy repo*, sends an `image-published` event here, and
[record-image.yml](.github/workflows/record-image.yml) writes it into `images/<environment>.yaml`
through a pull request:

| Pipeline | Records in | Pull request into |
|---|---|---|
| `publish-dev` | `images/dev.yaml` | `dev` |
| `publish-test` | `images/test.yaml` | `test` |
| `publish-prod` | `images/prod.yaml` | `main` |

Each file keeps the newest `image`, `tag`, `commit`, `published` time and pipeline run of every
component, and a newer image of the same component updates the open pull request. The records show what
each environment last published; they are not a tested combination (that is `releases.yml`). How it works
and how it is checked: [docs/DEVELOPER_GUIDE.md](docs/DEVELOPER_GUIDE.md#image-records).

## Repository secrets

| Secret | Repo | Used for |
|---|---|---|
| `DEPLOY_REPO_TOKEN` | backend, frontend, cube | their pipelines tell this repo which image they published (`image-published`). A fine-grained token for **this** repo: Contents read and write, which the dispatch API requires. Without it the job warns and the image is published anyway |
| `IMAGE_PR_TOKEN` | this repo | `record-image.yml` and `new-release.yml` open their pull requests with it, so the checks run on them (fine-grained token for this repo: Contents and Pull requests read and write). Optional: without it the built-in token opens the pull request, its checks do not start on their own, and the setting "Allow GitHub Actions to create and approve pull requests" must be on |
| `GHCR_READ_TOKEN` | this repo | pulling the private images in the e2e tests, Compose and kind (a token with `read:packages`), unless the packages grant this repo read access |
| `TEAMS_WEBHOOK_URL` | backend, frontend, cube | pipeline notifications (optional) |

## Branches and CI

Every repo uses the same flow: working branch → `dev` → `test` → `main` (pull requests, checked by
`pre-check.yml`). Pushes to `dev`, `test` and `main` publish `<env>-<sha>` images; a `vX.Y.Z` tag on
`main` marks a release.

| Workflow | Runs on | Does |
|---|---|---|
| [pre-check.yml](.github/workflows/pre-check.yml) | pull requests | promotion path, Gitleaks, ShellCheck; image-record pull requests may change only their own file |
| [validate.yml](.github/workflows/validate.yml) | pull requests and pushes | `scripts/validate.sh`: YAML, ShellCheck, Compose and Helm rendered and checked, the client kit, image records, `releases.yml` consistency, no secret files. Renders only: it deploys nothing |
| [e2e-smoke.yml](.github/workflows/e2e-smoke.yml) | component releases, pull requests, on demand | starts a real stack from published images and signs in |
| [kubernetes-smoke.yml](.github/workflows/kubernetes-smoke.yml) | pull requests touching the chart or its scripts, on demand | installs the chart on a throwaway kind cluster with `portal.sh helm-install` and runs the same Playwright smoke test. Validation only: the cluster disappears with the job |
| [client-kit.yml](.github/workflows/client-kit.yml) | `releases.yml` changed on `main`, on demand | builds and attaches the client kit and the Windows launcher; publishes the chart to GHCR (OCI) |
| [new-release.yml](.github/workflows/new-release.yml) | on demand | opens the pull request that adds a release to `releases.yml` and syncs `.env.example` and the chart's `appVersion` |
| [record-image.yml](.github/workflows/record-image.yml) | `image-published` from a component pipeline, on demand | opens or updates the image-record pull request |
