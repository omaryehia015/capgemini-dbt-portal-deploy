# Running the dbt Portal

Two pre-built container images. No source code, no build step, nothing to
install besides Docker (or Podman).

## Quickstart

```bash
cp .env.example .env
# open .env, set DBT_PROJECT_PATH to your dbt project folder (or use
# DBT_PROJECT_GIT_URL instead -- see the comments in .env.example)

docker compose pull
docker compose up -d

docker compose logs backend | grep -A6 "GENERATED INITIAL CREDENTIALS"
# -> first-login username/passwords, printed once
```

Open **http://localhost:8080** and log in with one of those accounts.
Change the password from the Account page after first login.

That's it. There is no other required setup: warehouse credentials come from
your dbt project's own `.env` (the same file `profiles.yml` already reads via
`env_var(...)`), because that project needs them anyway to run `dbt` by
itself.

## Common follow-ups

- **Different port**: `PORTAL_PORT=8081` in `.env`, then `docker compose up -d`.
- **Upgrade to a new version**: set `IMAGE_TAG` in `.env`, then
  `docker compose pull && docker compose up -d`. Your accounts, audit log,
  run history and session secret are all on the `portal_data` volume and
  survive the upgrade.
- **Point at a different project** (e.g. moving from a demo to the real one):
  change `DBT_PROJECT_PATH` (or the `DBT_PROJECT_GIT_URL` block) in `.env`,
  then `docker compose up -d`. Nothing else changes.
- **Lost the printed passwords**: `docker compose logs backend` still has
  them if the container hasn't restarted since; otherwise reset a user's
  password from another admin account, or from the database directly.
- **Something looks wrong**: `docker compose logs backend` — the first
  `[OK]`/`[WARN]`/`[FAIL]` block on every start is a self-check of the
  project, warehouse connection and configuration. It's usually more
  specific than anything below it.

## What you're NOT expected to do

- Clone the app's source repository.
- Install Python, Node, or dbt on this machine.
- Edit anything inside the images.
- Write or generate a secret key by hand.

If any of the above turns out to be necessary, that's a bug in the install,
not something the deployer should have to work around.

## Uninstall

```bash
docker compose down        # stop and remove the containers
docker compose down -v     # also delete portal_data (accounts, run history, session secret)
```

Your dbt project (wherever `DBT_PROJECT_PATH` points, or the `workspace`
volume in git mode) is never touched by this.
