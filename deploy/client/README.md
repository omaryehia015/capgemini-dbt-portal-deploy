# Running the dbt Portal

Two pre-built container images, a backend and a frontend. You don't build
anything or install Python, Node or dbt. All you need is **Docker Desktop**
or **Podman Desktop**, running.

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

The script pulls both images, starts them, waits until the portal answers, and
prints the first-login passwords:

```
==> Portal is up: http://localhost:8080
GENERATED INITIAL CREDENTIALS (shown once; change them after first login)
  admin      DDFY-bEs-3qItiQg
  ...
```

Open the address, sign in as `admin`, change the password under **My
account**, then open **Onboarding** and run its steps. The portal doesn't
install packages (`dbt deps`) or build anything until you run those steps.
On start it only checks the connection.

| Option | Windows | Linux / macOS |
|---|---|---|
| Another port | `-Port 8081` | `--port 8081` |
| A specific version | `-Tag 1.2.0` | `--tag 1.2.0` |
| Images already loaded with `docker load` (no registry) | `-SkipPull` | `--skip-pull` |

Run the script again at any time to upgrade or change the port. Accounts,
audit log and run history are kept.

## How the portal finds your project

The path you give the script is mounted into the backend container as
`/workspace`, and the backend is told `DBT_PROJECT_DIR=/workspace`. That's
the only link between the portal and your project. Specifically:

- **Where you set it:** `-Project` / the first argument of `setup.sh`. To
  switch projects, run the script again with the other path.
- **Credentials:** the backend loads `<project>/.env` on every start, so your
  `env_var(...)` values reach dbt. Nothing is copied into the image.
- **profiles.yml:** found automatically in `<project>/`,
  `<project>/profiles/`, or your own `~/.dbt/`.
- **Changes to the project:** your edits on disk are visible to the portal
  immediately. Files dbt writes (`target/`, `dbt_packages/`) appear in your
  folder.
- **Several projects on one machine:** each project gets its own containers
  and data (`dbt-portal-<folder name>-*`). Give each one its own `-Port`.

## Optional settings

For sign-in with your company directory (LDAP), emailed sign-in codes, AI
keys and similar settings, copy `.env.example` to `.env` **next to the
script**, uncomment what you need, and run the script again.

**Data ingestion (Airbyte):** install Airbyte on the same server with
`abctl local install --host <this-server>`, put the `AIRBYTE_*` lines from
`.env.example` in `.env` (the id/secret come from `abctl local credentials`)
and run the script again. The portal's **Airbyte** page then lists your
connections and runs syncs; **Tools & Services** shows whether every
integration is working.

## Managing it

The script prints these with your project's names filled in:

```bash
docker logs -f dbt-portal-<project>-backend           # what the backend is doing
docker stop dbt-portal-<project>-frontend dbt-portal-<project>-backend
docker start dbt-portal-<project>-backend dbt-portal-<project>-frontend
```

Use `podman` in place of `docker` if that's what you run.

- **Lost the first passwords:** another admin can set a new one in
  Governance → Users. `docker logs dbt-portal-<project>-backend` still shows
  them until the container is recreated.
- **Something looks wrong:** read `docker logs dbt-portal-<project>-backend`.
  Every start begins with an `[OK]`/`[WARN]`/`[FAIL]` self-check of the
  project, the warehouse connection and the configuration.
- **Uninstall:** `docker rm -f dbt-portal-<project>-frontend dbt-portal-<project>-backend`,
  then `docker volume rm dbt-portal-<project>-data` to also delete the
  accounts. Your dbt project is never deleted.

## Prefer Docker Compose?

`compose.yaml` runs the same two images. Copy `.env.example` to `.env`, set
`DBT_PROJECT_PATH` to your project folder (or `DBT_PROJECT_GIT_URL` to have
the container clone it), then run:

```bash
docker compose up -d
docker compose logs backend | grep -A6 "GENERATED INITIAL CREDENTIALS"
```

## What you're NOT expected to do

- Clone the app's source repository or build images.
- Install Python, Node, or dbt on this machine.
- Write or generate a secret key by hand.

If any of these turns out to be necessary, that's a bug in the install, not
something you should have to work around.
