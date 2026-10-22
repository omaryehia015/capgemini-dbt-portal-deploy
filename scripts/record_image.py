#!/usr/bin/env python3
"""Record the image a component pipeline published, in images/<environment>.yaml.

    record_image.py record --file images/dev.yaml --environment dev --component backend \
        --tag dev-<sha> --commit <sha> [--image ghcr.io/<owner>/capgemini-dbt-portal-backend] \
        [--registry ghcr.io/<owner>] [--run-url URL] [--published-at 2026-10-22T10:00:00Z]
    record_image.py check images/dev.yaml images/test.yaml images/prod.yaml

`record` replaces the entry of that component in the file (the newest image of each component is
the record) and prints "recorded" or "unchanged". It refuses anything that is not exactly what the
component pipelines publish, so a malformed or hostile event cannot write odd text into the repo:

  environment  dev | test | prod
  component    backend | frontend | cube
  image        <registry>/capgemini-dbt-portal-<component>   (registry default ghcr.io/omaryehia015)
  tag          <environment>-<commit>      e.g. prod-4c8c4a9e...   (the pipelines' convention)
  commit       7 to 40 hex characters
  run url      https://github.com/<owner>/<repo>/actions/runs/<id>

`check` validates existing files (used by scripts/validate.sh and CI). Reads and writes only the
files it is given. Needs PyYAML.
"""

from __future__ import annotations

import argparse
import datetime
import re
import sys
from pathlib import Path

import yaml

COMPONENTS = ("backend", "frontend", "cube")
ENVIRONMENTS = ("dev", "test", "prod")
DEFAULT_REGISTRY = "ghcr.io/omaryehia015"
HEADER = """# Images published for the {env} environment: the newest one of each component.
# Written by .github/workflows/record-image.yml from the component pipelines' image-published
# event, one pull request per environment and component. Do not edit by hand.
"""

COMMIT_RE = re.compile(r"^[a-f0-9]{7,40}$")
RUN_RE = re.compile(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+(/attempts/[0-9]+)?$")
TIME_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
REGISTRY_RE = re.compile(r"^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$")


def problems(environment: str, component: str, entry: dict, registry: str) -> list[str]:
    """What is wrong with one entry (empty: nothing)."""
    found: list[str] = []
    if environment not in ENVIRONMENTS:
        found.append(f"environment '{environment}' is not one of {', '.join(ENVIRONMENTS)}")
    if component not in COMPONENTS:
        found.append(f"component '{component}' is not one of {', '.join(COMPONENTS)}")
        return found
    image, tag, commit = (str(entry.get(k, "")) for k in ("image", "tag", "commit"))
    expected = f"{registry}/capgemini-dbt-portal-{component}"
    if image != expected:
        found.append(f"{component}: image '{image}' is not '{expected}'")
    if not COMMIT_RE.match(commit):
        found.append(f"{component}: commit is not 7 to 40 hex characters")
    if tag != f"{environment}-{commit}":
        found.append(f"{component}: tag '{tag}' is not '{environment}-<commit>' ({environment}-{commit})")
    published = str(entry.get("published", ""))
    if not TIME_RE.match(published):
        found.append(f"{component}: published '{published}' is not a UTC time like 2026-10-22T10:00:00Z")
    run = entry.get("run")
    if run is not None and not RUN_RE.match(str(run)):
        found.append(f"{component}: run '{run}' is not a GitHub Actions run URL")
    unknown = set(entry) - {"image", "tag", "commit", "published", "run"}
    if unknown:
        found.append(f"{component}: unexpected keys {sorted(unknown)}")
    return found


def load(path: Path, environment: str | None = None) -> dict:
    if not path.exists():
        return {"environment": environment, "images": {}}
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(data, dict):
        raise ValueError(f"{path}: not a mapping")
    data.setdefault("images", {})
    return data


def dump(path: Path, data: dict) -> None:
    ordered = {c: data["images"][c] for c in COMPONENTS if c in data["images"]}
    body = yaml.safe_dump({"environment": data["environment"], "images": ordered}, sort_keys=False, default_flow_style=False)
    if not ordered:
        body = f"environment: {data['environment']}\nimages: {{}}\n"
    path.write_text(HEADER.format(env=data["environment"]) + body, encoding="utf-8")


def cmd_record(args: argparse.Namespace) -> int:
    registry = args.registry.rstrip("/")
    if not REGISTRY_RE.match(registry):
        print(f"record_image: '{registry}' is not a registry path", file=sys.stderr)
        return 2
    entry = {
        "image": args.image or f"{registry}/capgemini-dbt-portal-{args.component}",
        "tag": args.tag,
        "commit": args.commit,
        "published": args.published_at or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    if args.run_url:
        entry["run"] = args.run_url
    bad = problems(args.environment, args.component, entry, registry)
    if bad:
        for line in bad:
            print(f"record_image: {line}", file=sys.stderr)
        return 2
    path = Path(args.file)
    if path.stem != args.environment:
        print(f"record_image: {path} is not the file of environment {args.environment}", file=sys.stderr)
        return 2
    data = load(path, args.environment)
    if data.get("environment") not in (None, args.environment):
        print(f"record_image: {path} belongs to environment {data.get('environment')}", file=sys.stderr)
        return 2
    data["environment"] = args.environment
    before = dict(data["images"].get(args.component) or {})
    # Same image and commit: only the run and time differ. That is not a change worth a pull request.
    if before.get("tag") == entry["tag"] and before.get("image") == entry["image"]:
        print("unchanged")
        return 0
    data["images"][args.component] = entry
    path.parent.mkdir(parents=True, exist_ok=True)
    dump(path, data)
    print("recorded")
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    failed = 0
    for name in args.files:
        path = Path(name)
        try:
            data = load(path)
        except Exception as exc:  # noqa: BLE001 - report any parse error with the file name
            print(f"FAIL {name}: {exc}")
            failed += 1
            continue
        env = path.stem
        errors: list[str] = []
        if data.get("environment") != env:
            errors.append(f"environment is '{data.get('environment')}', the file is for '{env}'")
        if not isinstance(data["images"], dict):
            errors.append("images is not a mapping")
        else:
            for component, entry in data["images"].items():
                if not isinstance(entry, dict):
                    errors.append(f"{component}: not a mapping")
                    continue
                errors += problems(env, str(component), entry, args.registry.rstrip("/"))
        for line in errors:
            print(f"FAIL {name}: {line}")
        failed += bool(errors)
    if not failed:
        print(f"ok   {len(args.files)} image record(s)")
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    rec = sub.add_parser("record")
    rec.add_argument("--file", required=True)
    rec.add_argument("--environment", required=True)
    rec.add_argument("--component", required=True)
    rec.add_argument("--tag", required=True)
    rec.add_argument("--commit", required=True)
    rec.add_argument("--image", default="")
    rec.add_argument("--registry", default=DEFAULT_REGISTRY)
    rec.add_argument("--run-url", default="")
    rec.add_argument("--published-at", default="")
    rec.set_defaults(func=cmd_record)
    chk = sub.add_parser("check")
    chk.add_argument("files", nargs="+")
    chk.add_argument("--registry", default=DEFAULT_REGISTRY)
    chk.set_defaults(func=cmd_check)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
