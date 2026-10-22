#!/usr/bin/env python3
"""Assertions on rendered deployment manifests (used by scripts/validate.sh and CI).

    check_manifests.py compose-full|compose-single|compose-build|compose-single-build FILE.json \
        --backend-tag T --frontend-tag T --cube-tag T
    check_manifests.py helm FILE.yaml --backend-tag T --frontend-tag T --cube-tag T \
        (--bundled | --external) (--secret-created | --secret-existing NAME) [--ingress] [--cube-sql]
    check_manifests.py yaml FILE...      every YAML document parses
    check_manifests.py json FILE...      every file is valid JSON

Compose input is `docker compose ... config --format json`; Helm input is `helm template` output.
Reads only. Prints one line per failed assertion and exits 1 if there is any; never prints a
secret value (the inputs it is given hold placeholders only).
"""

from __future__ import annotations

import argparse
import json
import re
import sys

REGISTRY = "ghcr.io/omaryehia015"
BACKEND = f"{REGISTRY}/capgemini-dbt-portal-backend"
FRONTEND = f"{REGISTRY}/capgemini-dbt-portal-frontend"
CUBE = f"{REGISTRY}/capgemini-dbt-portal-cube"

errors: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


# ── Compose ──────────────────────────────────────────────────────────────────
def published(service: dict) -> list[dict]:
    return service.get("ports", []) or []


def mounts(service: dict) -> dict[str, dict]:
    return {v["target"]: v for v in service.get("volumes", []) or []}


def compose(kind: str, data: dict, args: argparse.Namespace) -> None:
    services = data["services"]
    names = set(services)
    full = kind in ("compose-full", "compose-build")
    build = kind in ("compose-build", "compose-single-build")

    if full:
        check(names == {"postgres", "redis", "upgrade", "backend", "worker", "cube", "frontend"}, f"full stack services are {sorted(names)}")
    else:
        check(names == {"backup-folder", "backend", "cube", "frontend"}, f"single-node services are {sorted(names)}")
        for gone in ("worker", "redis", "postgres"):
            check(gone not in names, f"single-node stack has a '{gone}' service")

    # Host ports: only the frontend, plus (full stack) Cube's SQL API on loopback.
    for name, svc in services.items():
        for port in published(svc):
            if name == "frontend" and port["target"] in (8080, 8082):
                if kind.startswith("compose-single"):
                    check(port.get("host_ip") == "127.0.0.1", f"single-node frontend port {port['target']} is not bound to 127.0.0.1")
            elif name == "cube" and port["target"] == 15432 and full:
                check(port.get("host_ip") == "127.0.0.1", "Cube SQL port is not bound to 127.0.0.1 by default")
            else:
                errors.append(f"service '{name}' publishes host port {port.get('published')}->{port['target']}")

    # Images: names, and one independent tag each.
    backend = services["backend"]
    if build:
        check(backend["image"] == "capgemini-dbt-portal-backend:source", f"backend image is {backend['image']}")
        check("build" in backend, "backend has no build section")
        check(backend["build"]["context"].replace("\\", "/").rstrip("/").endswith("capgemini-dbt-portal-backend"), "backend build context is not the sibling backend repo")
        check("build" not in services.get("worker", {}), "worker has a build section: the backend image would be built twice")
        for name, source in (("frontend", "capgemini-dbt-portal-frontend"), ("cube", "capgemini-dbt-portal-cube")):
            check("build" in services[name], f"{name} has no build section")
            check(services[name]["build"]["context"].replace("\\", "/").rstrip("/").endswith(source), f"{name} build context is not the sibling {source} repo")
            check(services[name]["build"]["args"].get("APP_VERSION") is not None, f"{name} build has no APP_VERSION argument")
        check(services["backend"]["build"]["args"].get("APP_VERSION") is not None, "backend build has no APP_VERSION argument")
    else:
        check(backend["image"] == f"{BACKEND}:{args.backend_tag}", f"backend image is {backend['image']}")
        check(services["frontend"]["image"] == f"{FRONTEND}:{args.frontend_tag}", f"frontend image is {services['frontend']['image']}")
        check(services["cube"]["image"] == f"{CUBE}:{args.cube_tag}", f"cube image is {services['cube']['image']}")
        check(len({args.backend_tag, args.frontend_tag, args.cube_tag}) == 3, "test tags are not three different values: independence not shown")

    env = backend.get("environment", {})
    for name in ("backend", "frontend", "cube"):
        check(services[name].get("security_opt") == ["no-new-privileges:true"], f"{name}: no-new-privileges is not set")
        check(services[name].get("cap_drop") == ["ALL"], f"{name}: capabilities are not dropped")

    if full:
        worker = services["worker"]
        check(worker["image"] == backend["image"], "worker and backend run different images")
        check(worker.get("command") == ["python", "-m", "app.worker"], f"worker command is {worker.get('command')}")
        check(worker["healthcheck"]["test"] == ["CMD", "python", "-m", "app.worker", "--check"], "worker healthcheck is not the app.worker --check command")
        check(env.get("EXECUTION_ROLE") == "api", f"backend EXECUTION_ROLE is {env.get('EXECUTION_ROLE')}")
        for service in ("backend", "worker"):
            m = mounts(services[service])
            check("/workspace" in m, f"{service} has no /workspace mount")
            check(m.get("/data", {}).get("source") == "portal_data", f"{service} does not mount portal_data at /data")
        check(mounts(backend)["/workspace"] == mounts(worker)["/workspace"], "backend and worker mount different workspaces")
        check(services["redis"].get("ports") in (None, []), "redis publishes a port")
        check(services["postgres"].get("ports") in (None, []), "postgres publishes a port")
        check(services["worker"].get("ports") in (None, []), "worker publishes a port")
        check("redis_data" in data.get("volumes", {}), "no redis_data volume")
        check("postgres_data" in data.get("volumes", {}), "no postgres_data volume")
        check(env.get("DATABASE_URL", "").startswith("postgresql+psycopg2://portal:"), "backend DATABASE_URL does not use the bundled PostgreSQL")
    else:
        check(env.get("EXECUTION_ROLE") == "all", f"single-node EXECUTION_ROLE is {env.get('EXECUTION_ROLE')}")
        check(env.get("REDIS_URL") == "", "single-node REDIS_URL is not forced empty")
        check(env.get("DATABASE_URL", "").startswith("sqlite:"), "single-node DATABASE_URL is not SQLite")
        check(backend.get("command") is None, "single-node backend has a command (it must run the API and the jobs itself)")

    # The frontend never receives secrets.
    frontend_env = services["frontend"].get("environment", {})
    for key in frontend_env:
        check(not re.search(r"SECRET|PASSWORD|TOKEN|KEY", key), f"frontend environment has {key}")
    check("env_file" not in services["frontend"], "frontend has an env_file (it could carry secrets)")
    cube_env = set(services["cube"].get("environment", {}))
    check(cube_env == {"CUBEJS_API_SECRET", "PORTAL_SEMANTIC_URL"}, f"cube environment is {sorted(cube_env)}")
    check(env.get("CUBE_API_URL") == "http://cube:4000", "backend does not reach Cube at http://cube:4000")
    check(frontend_env.get("BACKEND_UPSTREAM") == "backend:8000", "frontend upstream is not backend:8000")


# ── Helm ─────────────────────────────────────────────────────────────────────
def load_yaml(path: str) -> list[dict]:
    import yaml  # PyYAML

    with open(path, encoding="utf-8") as handle:
        return [d for d in yaml.safe_load_all(handle) if d]


def containers(deployment: dict) -> list[dict]:
    return deployment["spec"]["template"]["spec"]["containers"]


def env_of(container: dict) -> dict[str, dict]:
    return {e["name"]: e for e in container.get("env", []) or []}


def pod_spec(workload: dict) -> dict:
    return workload["spec"]["template"]["spec"]


def helm(path: str, args: argparse.Namespace) -> None:
    docs = load_yaml(path)
    kinds: dict[str, list[dict]] = {}
    for d in docs:
        kinds.setdefault(d["kind"], []).append(d)
    deployments = {d["metadata"]["name"]: d for d in kinds.get("Deployment", [])}
    services = {s["metadata"]["name"]: s for s in kinds.get("Service", [])}

    for name in ("dbt-portal-backend", "dbt-portal-worker", "dbt-portal-frontend", "dbt-portal-cube"):
        check(name in deployments, f"no Deployment {name}")
    if errors:
        return
    backend, worker, frontend, cube = (deployments[n] for n in ("dbt-portal-backend", "dbt-portal-worker", "dbt-portal-frontend", "dbt-portal-cube"))
    bc, wc, fc, cc = (containers(d)[0] for d in (backend, worker, frontend, cube))

    # Images: names and independent tags; one image for backend and worker.
    check(bc["image"] == f"{BACKEND}:{args.backend_tag}", f"backend image is {bc['image']}")
    check(wc["image"] == bc["image"], "worker and backend use different images")
    check(fc["image"] == f"{FRONTEND}:{args.frontend_tag}", f"frontend image is {fc['image']}")
    check(cc["image"] == f"{CUBE}:{args.cube_tag}", f"cube image is {cc['image']}")
    check(len({args.backend_tag, args.frontend_tag, args.cube_tag}) == 3, "test tags are not three different values: independence not shown")

    # Worker command and health check.
    check(wc.get("args") == ["python", "-m", "app.worker"], f"worker args are {wc.get('args')}")
    for probe in ("startupProbe", "livenessProbe"):
        check(wc.get(probe, {}).get("exec", {}).get("command") == ["python", "-m", "app.worker", "--check"], f"worker {probe} is not app.worker --check")
        check(wc.get(probe, {}).get("timeoutSeconds", 1) >= 5, f"worker {probe} timeout is too short for a Python start")
    check("readinessProbe" not in wc, "worker has a readiness probe (it has no Service)")
    check(env_of(bc)["EXECUTION_ROLE"]["value"] == "api", "backend EXECUTION_ROLE is not api")

    # Backend and worker share ONE workspace volume.
    def claim(workload: dict, volume: str) -> str | None:
        for v in pod_spec(workload).get("volumes", []):
            if v["name"] == volume:
                return v.get("persistentVolumeClaim", {}).get("claimName")
        return None

    check(claim(backend, "workspace") is not None and claim(backend, "workspace") == claim(worker, "workspace"), "backend and worker do not share the same workspace claim")
    check(claim(worker, "data") is None, "worker mounts the backend's data volume")
    check(any(m["mountPath"] == "/workspace" for m in bc["volumeMounts"]) and any(m["mountPath"] == "/workspace" for m in wc["volumeMounts"]), "workspace is not mounted at /workspace in both")

    # Probes.
    for label, c, names in (("backend", bc, ("startupProbe", "readinessProbe", "livenessProbe")), ("frontend", fc, ("startupProbe", "readinessProbe", "livenessProbe")), ("cube", cc, ("startupProbe", "readinessProbe", "livenessProbe"))):
        for n in names:
            check(n in c, f"{label} has no {n}")
    check(bc["livenessProbe"]["httpGet"]["path"] == "/api/health", "backend probes do not use /api/health")
    check(fc["livenessProbe"]["httpGet"]["path"] == "/", "frontend probe path is not /")
    check(cc["livenessProbe"]["httpGet"]["path"] == "/livez" and cc["readinessProbe"]["httpGet"]["path"] == "/readyz", "cube probes are not /livez and /readyz")

    # Nothing but the frontend is reachable: no public Service types, no host networking, no host ports.
    for name, svc in services.items():
        stype = svc["spec"].get("type", "ClusterIP")
        check(stype == "ClusterIP", f"Service {name} is of type {stype}")
    check("dbt-portal-worker" not in services, "worker has a Service")
    for d in deployments.values():
        spec = pod_spec(d)
        check(not spec.get("hostNetwork"), f"{d['metadata']['name']} uses hostNetwork")
        for c in spec["containers"]:
            check(not any("hostPort" in p for p in c.get("ports", [])), f"{d['metadata']['name']} uses a hostPort")
    sql_ports = [p for p in services["dbt-portal-cube"]["spec"]["ports"] if p["port"] == 15432]
    if not args.cube_sql:
        check(not sql_ports, "Cube SQL port is in the Service without cube.service.sql.enabled")
    if args.ingress:
        check(len(kinds.get("Ingress", [])) == 1, "no Ingress, though one was asked for")
    for ing in kinds.get("Ingress", []):
        targets = {path["backend"]["service"]["name"] for rule in ing["spec"]["rules"] for path in rule["http"]["paths"]}
        check(targets == {"dbt-portal-frontend"}, f"Ingress routes to {sorted(targets)}")
    if not args.ingress:
        check("Ingress" not in kinds, "an Ingress is rendered although none was asked for")

    # Secrets: none in ConfigMaps; the frontend and Cube see the least possible.
    cm = kinds["ConfigMap"][0]["data"]
    for key in cm:
        check(not re.search(r"SECRET|PASSWORD|TOKEN|PRIVATE|_KEY|DATABASE_URL|REDIS_URL", key), f"ConfigMap has {key}")
    check("envFrom" not in fc, "frontend has envFrom")
    check(not any("valueFrom" in e for e in fc.get("env", [])), "frontend has a valueFrom env")
    cube_secret_refs = [e["valueFrom"]["secretKeyRef"]["key"] for e in cc["env"] if "valueFrom" in e]
    check(cube_secret_refs == ["CUBE_API_SECRET"], f"cube secret keys are {cube_secret_refs}")

    secret_name = None
    if args.secret_created:
        check(len(kinds.get("Secret", [])) == 1, "secrets.create=true should render exactly one Secret")
        secret_name = kinds["Secret"][0]["metadata"]["name"]
        keys = set(kinds["Secret"][0]["data"])
        check({"JWT_SECRET", "CUBE_API_SECRET", "PORTAL_SECRET_KEY"} <= keys, f"generated Secret keys are {sorted(keys)}")
    else:
        check("Secret" not in kinds, "secrets.create=false but the chart renders a Secret")
        secret_name = args.secret_existing
    for label, c in (("backend", bc), ("worker", wc)):
        refs = [e["secretRef"]["name"] for e in c["envFrom"] if "secretRef" in e]
        check(refs == [secret_name], f"{label} envFrom secrets are {refs}, expected {secret_name}")
        env = env_of(c)
        for key in ("JWT_SECRET", "CUBE_API_SECRET", "PORTAL_SECRET_KEY"):
            check(env.get(key, {}).get("valueFrom", {}).get("secretKeyRef", {}).get("name") == secret_name, f"{label} {key} is not read from the Secret")
        check(env["DATABASE_URL"].get("value", "x") != "" and env["REDIS_URL"].get("value", "x") != "", f"{label} has an empty DATABASE_URL or REDIS_URL")
        if args.bundled:
            check("$(POSTGRES_PASSWORD)" in env["DATABASE_URL"].get("value", ""), f"{label} DATABASE_URL is not built from POSTGRES_PASSWORD")
            check("dbt-portal-postgres:5432" in env["DATABASE_URL"]["value"], f"{label} DATABASE_URL does not use the internal service")
            check("$(REDIS_PASSWORD)" in env["REDIS_URL"].get("value", ""), f"{label} REDIS_URL is not built from REDIS_PASSWORD")
            check("dbt-portal-redis:6379" in env["REDIS_URL"]["value"], f"{label} REDIS_URL does not use the internal service")
        else:
            check("secretKeyRef" in env["DATABASE_URL"].get("valueFrom", {}), f"{label} DATABASE_URL is not read from the Secret")
            check("secretKeyRef" in env["REDIS_URL"].get("valueFrom", {}), f"{label} REDIS_URL is not read from the Secret")
    check(env_of(wc)["DBT_PROJECT_GIT_URL"].get("value") == "", "worker may clone the project (DBT_PROJECT_GIT_URL is not empty)")

    # Bundled data services: persistent PostgreSQL, ClusterIP only.
    sts = {s["metadata"]["name"]: s for s in kinds.get("StatefulSet", [])}
    if args.bundled:
        check("dbt-portal-postgres" in sts and sts["dbt-portal-postgres"]["spec"].get("volumeClaimTemplates"), "bundled PostgreSQL has no persistent volume")
        check("dbt-portal-postgres" in services and "dbt-portal-redis" in services, "bundled services have no Service")
        check("dbt-portal-redis" in deployments, "bundled Redis is not deployed")
        redis_args = containers(deployments["dbt-portal-redis"])[0]["args"]
        check("--requirepass" in redis_args, "bundled Redis has no password")
    else:
        check(not sts, "StatefulSet rendered although postgresql.enabled=false")
        check("dbt-portal-redis" not in deployments, "Redis rendered although redis.enabled=false")
        check("dbt-portal-postgres" not in services and "dbt-portal-redis" not in services, "data-service Service rendered although they are disabled")

    # Pod hardening of every workload.
    for d in list(deployments.values()) + list(sts.values()):
        name = d["metadata"]["name"]
        spec = pod_spec(d)
        check(spec.get("automountServiceAccountToken") is False, f"{name}: the service account token is mounted")
        psc = spec.get("securityContext", {})
        check(psc.get("runAsNonRoot") is True, f"{name}: runAsNonRoot is not set")
        check(psc.get("seccompProfile", {}).get("type") == "RuntimeDefault", f"{name}: seccomp is not RuntimeDefault")
        for c in spec["containers"]:
            sc = c.get("securityContext", {})
            check(sc.get("allowPrivilegeEscalation") is False, f"{name}: privilege escalation is allowed")
            check(sc.get("capabilities", {}).get("drop") == ["ALL"], f"{name}: capabilities are not dropped")
            check("privileged" not in sc, f"{name}: privileged is set")
        check(spec.get("securityContext", {}).get("runAsUser") not in (0,), f"{name}: runs as root")
    check(pod_spec(backend)["securityContext"].get("runAsUser") == 10001, "backend is not run as the image's uid 10001")
    check(pod_spec(cube)["securityContext"].get("runAsUser") == 1000, "cube is not run as the node user (uid 1000)")


def parse_only(kind: str, files: list[str]) -> None:
    """yaml: every document of every file parses; json: every file parses."""
    for path in files:
        try:
            if kind == "yaml":
                load_yaml(path)
            else:
                with open(path, encoding="utf-8") as handle:
                    json.load(handle)
        except Exception as exc:  # noqa: BLE001 - report any parse error with the file name
            errors.append(f"{path}: {str(exc).splitlines()[0] if str(exc) else type(exc).__name__}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("kind", choices=["compose-full", "compose-single", "compose-build", "compose-single-build", "helm", "yaml", "json"])
    parser.add_argument("file", nargs="+", help="one file (yaml and json: any number)")
    parser.add_argument("--backend-tag", default="")
    parser.add_argument("--frontend-tag", default="")
    parser.add_argument("--cube-tag", default="")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--bundled", action="store_true")
    group.add_argument("--external", action="store_true")
    secret = parser.add_mutually_exclusive_group()
    secret.add_argument("--secret-created", action="store_true")
    secret.add_argument("--secret-existing", default="")
    parser.add_argument("--ingress", action="store_true", help="helm: an Ingress is expected")
    parser.add_argument("--cube-sql", action="store_true", help="helm: the Cube SQL Service port is expected")
    args = parser.parse_args()

    if args.kind in ("yaml", "json"):
        parse_only(args.kind, args.file)
    else:
        if len(args.file) != 1:
            parser.error(f"{args.kind} takes exactly one file")
        if args.kind == "helm":
            if not (args.bundled or args.external):
                parser.error("helm needs --bundled or --external")
            if not (args.secret_created or args.secret_existing):
                parser.error("helm needs --secret-created or --secret-existing NAME")
            helm(args.file[0], args)
        else:
            with open(args.file[0], encoding="utf-8") as handle:
                compose(args.kind, json.load(handle), args)

    for message in errors:
        print(f"FAIL {args.kind}: {message}")
    if errors:
        return 1
    print(f"ok   {args.kind}" + (f" ({len(args.file)} files)" if args.kind in ("yaml", "json") else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
