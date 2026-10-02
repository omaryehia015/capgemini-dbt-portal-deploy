# Running the dbt Portal

Pre-built container images, one compose file and a setup script. You don't
build anything or install Python, Node or dbt. All you need is **Docker
Desktop** (or Docker Engine with the compose plugin), or **Podman** with a
compose provider, running.

The portal runs as a set of small services: sign-in, the dbt runner and its
**workers** (where dbt actually runs), the read-only report pages, the
semantic layer, a PostgreSQL database and Redis. You don't manage them one by
one: the script starts them all and they restart on their own.

## Quickstart (one command)

You need:

- The folder of your dbt project, the one with `dbt_project.yml` in it.
- Your warehouse credentials in that project's own `.env`. The portal reads
  them from there, the same way your `profiles.yml` does.
- A registry username and read-only token, if the images are private. The
  script asks for them the first time.

**Windows (PowerShell):**

```powershell
.\setup.ps1 -Project C:\work\my-dbt-project
```

If Windows blocks the script, run
`powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Project C:\work\my-dbt-project`.

**Linux / macOS:**

```bash
./setup.sh ~/work/my-dbt-project
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

Open the address, sign in as `admin`, change the password under **My
account**, then open **Onboarding** and run its steps. The portal doesn't
install packages (`dbt deps`) or build anything until you run those steps.

| Option | Windows | Linux / macOS |
|---|---|---|
| Another port | `-Port 8081` | `--port 8081` |
| A specific portal release (see `releases.yml`) | `-Release 2026.10.0` | `--release 2026.10.0` |
| Run more dbt jobs at once | `-Workers 3` | `--workers 3` |
| Images already loaded with `docker load` (no registry) | `-SkipPull` | `--skip-pull` |

Run the script again at any time to upgrade (`--release <newer>`) or change
the port. Accounts, run history and settings are kept.

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

**Data ingestion (Airbyte):** install Airbyte on the same server with
`abctl local install --host <this-server>`, put the `AIRBYTE_*` lines in
`.env` (the id/secret come from `abctl local credentials`) and run the script
again. The portal's **Airbyte** page then lists your connections and runs
syncs; **Tools & Services** shows whether every integration is working.

## Managing it

From the folder with `compose.yaml` (use `podman compose` if that's what you run):

```bash
docker compose ps                         # every service and whether it is healthy
docker compose logs -f execution worker   # dbt runs
docker compose up -d --scale worker=3     # more dbt jobs at once
docker compose stop                       # stop (docker compose start to resume)
```

- **Lost the first passwords:** another admin can set a new one in
  Governance → Users. `docker compose logs identity` still shows them until
  the container is recreated.
- **Something looks wrong:** `docker compose ps` shows which service is not
  healthy; read its log. The execution service's log starts with an
  `[OK]`/`[WARN]`/`[FAIL]` self-check of the project, the warehouse
  connection and the configuration.
- **Uninstall:** `docker compose down -v` (deletes the accounts and history).
  Your dbt project is never deleted.

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
