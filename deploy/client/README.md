# Running the dbt Portal

Pre-built container images, one compose file and a setup script. You don't
build anything or install Python, Node or dbt. All you need is **Docker
Desktop** (or Docker Engine with the compose plugin), or **Podman** with a
compose provider, running.

The portal runs as a few containers: the portal API, its **workers** (where
dbt actually runs), the web app, the semantic layer engine (Cube), a
PostgreSQL database and Redis. You don't manage them one by one: the script
starts them all and they restart on their own.

## Quickstart on Windows: download and double-click

Download **Install-DbtPortal.cmd** (from the download page,
`deploy/client/download/`, or the portal release on GitHub) and open it. A
window asks for one thing, the access token you were sent, then installs
everything, showing each step (More options: a project folder on this computer,
another install location). The dbt project is connected afterwards in the
portal's Setup Assistant. It starts Docker Desktop or Podman if they are installed but
not running, opens the portal, shows the admin password and puts a
**dbt Portal** shortcut on the desktop. Run it again later to upgrade.

The dbt project is chosen afterwards in the portal's Setup Assistant, with no
commands: a **Git repository**; a **folder on this computer** (type its path:
the app shares the main drive, C:\, with the portal unless More options names
another folder); or a **Docker image** with the project in it, on this computer
(Podman) or in a registry, with a user and token for a private one.

With Podman, the setup runs inside the Podman machine (Linux): its own podman,
registry login and paths, so nothing on the Windows side gets in the way. The
install lives in `~/dbt-portal` there (`podman machine ssh ~/dbt-portal/manage.sh status`).
An install made earlier on the Windows side is moved in, with its accounts.

Windows may warn that it protected your PC (the file is not signed yet): click
**More info**, then **Run anyway**.

## Quickstart (one command)

You need:

- The **access token** you were sent. It lets this machine download the
  private images; the script signs in with it for you.
- Optional: the folder of your dbt project (the one with `dbt_project.yml`).
  Without one, you connect a **Git repository** inside the portal's Setup
  Assistant, so there is nothing to prepare on this machine.

The easiest way is the download page (`deploy/client/download/index.html`):
paste the token, copy the command it builds for your OS, run it. Or by hand:

```bash
# macOS / Linux / WSL / a Linux VM
curl -fsSL -H "Authorization: Bearer $PORTAL_TOKEN" https://raw.githubusercontent.com/omaryehia015/capgemini-dbt-portal-deploy/main/deploy/client/install.sh | PORTAL_TOKEN=$PORTAL_TOKEN bash
```

```powershell
# Windows
$env:PORTAL_TOKEN = "<token you were sent>"
irm -Headers @{ Authorization = "Bearer $env:PORTAL_TOKEN" } https://raw.githubusercontent.com/omaryehia015/capgemini-dbt-portal-deploy/main/deploy/client/install.ps1 | iex
```

It downloads the kit, signs in to the registry, pulls the images, starts the
portal and opens it in your browser. To use a folder on this machine instead
of Git, add its path: `PORTAL_PROJECT` (Windows) or `bash -s -- <folder>`
(macOS / Linux). `PORTAL_RELEASE` picks a release and `PORTAL_DIR` the folder
(default `~/dbt-portal`). For a registry user other than `portal`, set
`PORTAL_USER_NAME`.

**From the unpacked kit:**

**Windows (PowerShell):**

```powershell
.\setup.ps1                                    # connect the project (Git) in the portal
.\setup.ps1 -Project C:\work\my-dbt-project    # or use a folder on this machine
```

If Windows blocks the script, run
`powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Project C:\work\my-dbt-project`.

**Linux / macOS:**

```bash
./setup.sh                          # connect the project (Git) in the portal
./setup.sh ~/work/my-dbt-project    # or use a folder on this machine
```

The first run writes a `.env` next to the script with generated secrets
(keep it: it is what lets you upgrade without losing accounts), pulls the
images, starts everything, waits until the portal answers, and prints the
first-login passwords:

```
==> Portal is up: http://localhost:8080
GENERATED INITIAL CREDENTIALS (shown once; change them after first login)
  admin      DDFY-bEs-3qItiQg
  ...
```

Open the address it prints (`/setup`) and sign in as `admin`. The **Setup
Assistant** walks through the workspace name, the warehouse connection, the
dbt project (packages, metadata database, reports), the modules (Airbyte,
Airflow, ...) and inviting your team. Change the admin password under **My
account**. The portal doesn't install packages (`dbt deps`) or build anything
until you run those steps.

Before installing, `./setup.sh --check` (or `.\setup.ps1 -Check`) only checks
the machine: OS, CPU, memory, disk and Docker/Podman, with the install command
for anything missing.

| Option | Windows | Linux / macOS |
|---|---|---|
| Another port | `-Port 8081` | `--port 8081` |
| A specific portal release (see `releases.yml`) | `-Release 2026.10.0` | `--release 2026.10.0` |
| Run more dbt jobs at once | `-Workers 3` | `--workers 3` |
| Images already loaded with `docker load` (no registry) | `-SkipPull` | `--skip-pull` |
| No questions: everything from a file (`portal.answers.example`) | `-Answers portal.answers` | `--answers portal.answers` |
| Only check this machine | `-Check` | `--check` |

Run the script again at any time to upgrade (`--release <newer>`) or change
the port. Accounts, run history and settings are kept. An upgrade also fetches
the current `releases.yml`, `compose.yaml` and `compose.single.yaml`, so new
ports and services (such as the semantic layer's SQL port, 15432) arrive with
it; a replaced compose file is kept as `<name>.bak`. Put your own changes in
`compose.override.yaml`, not in `compose.yaml`.

## How the portal finds your project

The path you give the script is written to `.env` as `DBT_PROJECT_PATH` and
mounted into the services as `/workspace`. That's the only link between the
portal and your project:

- **Where you set it:** `-Project` / the first argument of `setup.sh`. To
  switch projects, run the script again with the other path.
- **Credentials:** the services load `<project>/.env` on every start, so your
  `env_var(...)` values reach dbt. Nothing is copied into the images.
- **profiles.yml:** found automatically in `<project>/`,
  `<project>/profiles/`, or your own `~/.dbt/`.
- **Changes to the project:** your edits on disk are visible to the portal
  immediately. Files dbt writes (`target/`, `dbt_packages/`) appear in your
  folder.
- **Several projects on one machine:** unpack the kit into one folder per
  project and give each its own `-Port`.

## Optional settings

For sign-in with your company directory (LDAP), emailed sign-in codes, AI
keys and similar settings, edit `.env` next to the script (the commented
lines explain each one) and run the script again.

**Modules (Airbyte, Airflow):** open **Modules** in
the portal. Each module is *connected* to an instance you already run, or
*off* (its pages disappear). The module page has the install commands for
running it on this server, a form for the URL and credentials, and **Test
connection**, which checks each step (reachable, signed in, can see data).
For a zero-touch install, put `AIRFLOW_MODE`, `AIRFLOW_URL`... in the answers
file or `.env` instead (see `.env.example`).

## Managing it

From the folder with `compose.yaml` (on Windows: `.\manage.ps1 <command>`):

```bash
./manage.sh status              # every service, whether the portal answers, the modules
./manage.sh logs backend        # follow a service's log (all of them without a name)
./manage.sh restart worker      # restart one service (or all of them)
./manage.sh stop | start        # stop everything, start again
./manage.sh doctor              # check this machine, the containers and the project
./manage.sh upgrade 2026.11.0   # move to a release from releases.yml (default: latest)
./manage.sh backup              # write a backup now (the portal also makes one every day)
./manage.sh backups             # the backups, newest first
./manage.sh restore             # bring back the newest backup (or: restore <file name>)
./manage.sh reset-password      # a new admin password (or: reset-password <user>), shown once
./manage.sh services            # what each service does
```

More dbt jobs at once: `./setup.sh <project> --workers 3`.

### Backups

Your data (accounts, run history, schedules, settings, the saved warehouse
logins, the engineers' work) is safe when a container stops, crashes, is
deleted or is upgraded: it lives in volumes, not in the containers. To also
survive the volumes being deleted (`docker compose down -v`, resetting Docker
Desktop or the Podman machine) or a broken database, **the portal backs itself
up every day** into a normal folder on this computer:

| Installed with | Backups folder |
|---|---|
| setup.sh / setup.ps1 | `backups/` next to `compose.yaml` |
| the Windows setup window, with Podman | `%USERPROFILE%\dbt-portal\backups` (on the Windows side) |

It keeps the 14 newest. Admins see them under **Users & Access → Backups**,
with *Back up now* and a **Download** button for each.

**The backups folder is on the same disk as the portal.** If that disk or this
computer is lost, the backups go with it. Download a backup now and then and
keep it somewhere else (your laptop, OneDrive, SharePoint), or point
`PORTAL_BACKUP_DIR` in `.env` at a second disk or a network share and run the
setup again. A backup contains every login the portal stores: keep it as safe
as a password.

**To restore**, from the folder with `compose.yaml`:

```bash
./manage.sh restore                       # the newest backup
./manage.sh restore portal-backup-...gz   # a given one (put a downloaded file in the backups folder first)
```

Windows: `.\manage.ps1 restore`. Podman machine: `podman machine ssh "cd ~/dbt-portal && ./manage.sh restore"`.
It asks before replacing anything, stops the portal, restores and starts it
again. After a reinstall the setup says when it finds an earlier install's
backups, so you can bring that data back.

### Troubleshooting

| What you see | What to do |
|---|---|
| `doctor` says Docker/Podman is not running | Start Docker Desktop / Podman Desktop, then run the command again. |
| A service is `unhealthy` or keeps restarting | `./manage.sh logs <service>`. The backend's log starts with an `[OK]`/`[WARN]`/`[FAIL]` self-check of the project, the warehouse connection and the configuration. |
| The portal does not answer | `./manage.sh logs frontend backend`; check nothing else uses the port (`--port 8081` to move it). |
| Lost the admin password | Run the setup app again and click **Forgot the admin password?**, or `./manage.sh reset-password` (`.\manage.ps1 reset-password`; inside the Podman machine: `podman machine ssh "cd ~/dbt-portal && ./manage.sh reset-password"`). It prints a new one, once. Another admin can also set one in Governance → Users. |
| A module's Test connection fails | The failing line says why; its setup guide on the module page lists the usual fixes. |

**Uninstall:** `docker compose down -v` (deletes the accounts and history).
Your dbt project is never deleted, and neither is the backups folder: delete
it yourself if you no longer need it.

## Just one laptop?

`compose.single.yaml` runs every backend service in one container on SQLite:
fewer moving parts, but it does not scale past one machine.

```bash
docker compose -f compose.single.yaml up -d
docker compose -f compose.single.yaml logs backend | grep -A6 "GENERATED INITIAL CREDENTIALS"
```

## What you're NOT expected to do

- Clone the app's source repositories or build images.
- Install Python, Node, or dbt on this machine.
- Write or generate a secret key by hand.

If any of these turns out to be necessary, that's a bug in the install, not
something you should have to work around.
