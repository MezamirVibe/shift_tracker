"""Publish verified client packages without replacing API, data, or tenant routing.

Run on the Linux host as its Docker-enabled deployment user. See APP_UPDATES.md.
The tar.gz must contain exactly stable.json and the two versioned packages.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import time
from urllib.request import Request, urlopen


ORIGIN = "https://api.mezamir.com"
MOUNT = "      - ./app-updates:/srv/app-updates:ro\n"
HANDLER = '''\t# Public application packages only; never mount backups or organization files here.
\thandle_path /updates/* {
\t\troot * /srv/app-updates
\t\t@manifest path /stable.json
\t\theader @manifest Cache-Control "no-cache, no-store, must-revalidate"
\t\t@packages path /*/*.apk /*/*.zip
\t\theader @packages Cache-Control "public, max-age=31536000, immutable"
\t\tfile_server
\t}

'''


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, **kwargs):
    # Docker configuration errors may contain environment values: don't echo them.
    result = subprocess.run(args, stderr=subprocess.PIPE, **kwargs)
    require(result.returncode == 0, "Command failed: " + " ".join(args[:3]))
    return result


def output(args):
    return run(args, stdout=subprocess.PIPE, text=True).stdout


def inspect(name):
    return json.loads(output(["docker", "inspect", name]))[0]


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_new(path, content, mode=0o600):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode), "wb") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())


def atomic_write(path, content, mode):
    temporary = path.with_name(path.name + ".publishing")
    write_new(temporary, content, mode)
    os.replace(temporary, path)


def patch_config(caddy, compose):
    """Add only our own handler/mount; retain any host-specific organization routes."""
    caddy = caddy.replace("\r\n", "\n")
    compose = compose.replace("\r\n", "\n")
    require(caddy.count("api.mezamir.com {") == 1, "Ambiguous Caddy host")
    if "/updates/" in caddy or "/srv/app-updates" in caddy:
        require(caddy.count(HANDLER) == 1, "Existing update handler differs; review it manually")
    else:
        anchor = "\thandle_path /o/tehnodor-sk/* {"
        require(caddy.count(anchor) == 1, "Cannot find the unique organization routing anchor")
        caddy = caddy.replace(anchor, HANDLER + anchor)
    blocks = list(re.finditer(r"(?m)^  ([a-zA-Z0-9_-]+):\s*$", compose))
    caddy_blocks = [item for item in blocks if item.group(1) == "caddy"]
    require(len(caddy_blocks) == 1, "Cannot find the unique Caddy service")
    start = caddy_blocks[0].start()
    end = next((item.start() for item in blocks if item.start() > start), len(compose))
    block = compose[start:end]
    if "/srv/app-updates" in compose or "./app-updates" in compose:
        require(compose.count(MOUNT) == 1 and MOUNT in block, "Existing update mount differs")
    else:
        anchor = "      - ./organizations:/etc/caddy/organizations:ro\n"
        require(block.count(anchor) == 1, "Cannot find the unique Caddy volume anchor")
        block = block.replace(anchor, anchor + MOUNT)
        compose = compose[:start] + block + compose[end:]
    return caddy, compose


def unpack(archive_path, release, version, build):
    expected = {"stable.json", f"{version}/Chereda-{version}-android.apk",
                f"{version}/Chereda-{version}-windows.zip"}
    staging = release / "packages"
    staging.mkdir(mode=0o700)
    with tarfile.open(archive_path, "r:gz") as archive:
        members = archive.getmembers()
        require(len(members) == 3 and {item.name for item in members} == expected,
                "Archive must contain exactly the manifest and two versioned files")
        for member in members:
            require(member.isfile() and 0 < member.size < 1024 * 1024 * 1024,
                    "Invalid package archive member")
            target = staging / member.name
            target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            with archive.extractfile(member) as source, target.open("xb") as destination:
                shutil.copyfileobj(source, destination)
            target.chmod(0o644)
    manifest = json.loads((staging / "stable.json").read_text("utf-8"))
    require(set(manifest) == {"schema", "android", "windows"} and manifest["schema"] == 1,
            "Unsupported manifest schema")
    for platform, extension in (("android", "apk"), ("windows", "zip")):
        item = manifest[platform]
        filename = f"{version}/Chereda-{version}-{platform}.{extension}"
        artifact = staging / filename
        require(set(item) == {"version", "build", "url", "sha256", "size", "notes"},
                "Unsupported platform manifest fields")
        require(item["version"] == version and item["build"] == build,
                "Package version/build mismatch")
        require(item["url"] == f"{ORIGIN}/updates/{filename}", "Unexpected artifact URL")
        require(item["size"] == artifact.stat().st_size and item["sha256"] == sha256(artifact),
                "Artifact size/hash mismatch")
        require(isinstance(item["notes"], list) and all(isinstance(note, str) for note in item["notes"]),
                "Invalid release notes")
    return staging, manifest


def databases():
    names = output(["docker", "ps", "--filter", "label=com.docker.compose.service=db",
                    "--format", "{{.Names}}"])
    result = []
    for name in names.splitlines():
        info = inspect(name)
        project = info["Config"]["Labels"].get("com.docker.compose.project", "")
        if project != "deploy" and not re.fullmatch(r"chereda-org-[a-f0-9]{16}", project):
            continue
        env = dict(item.split("=", 1) for item in info["Config"]["Env"] if "=" in item)
        result.append((name, env["POSTGRES_USER"], env["POSTGRES_DB"]))
    require(any(item[0] == "deploy-db-1" for item in result), "Main database not found")
    return sorted(result)


def sql(database, statement):
    name, user, db = database
    return output(["docker", "exec", name, "psql", "-X", "-U", user, "-d", db,
                   "-At", "-v", "ON_ERROR_STOP=1", "-c", statement])


def fingerprint(database):
    # Discover every current table, including requests, settings and future additions.
    tables = sql(database, "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename").splitlines()
    require(tables and all(re.fullmatch(r"[a-z_][a-z0-9_]*", table) for table in tables),
            "Unexpected database table names")
    statements = [f"SELECT '{table}', count(*), md5(COALESCE(string_agg(row_to_json(t)::text, E'\\n' "
                  f"ORDER BY row_to_json(t)::text), '')) FROM public.\"{table}\" t" for table in tables]
    rows = sql(database, "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; " +
               " UNION ALL ".join(statements) + "; COMMIT;")
    result = {}
    for row in rows.splitlines():
        parts = row.split("|")
        if len(parts) == 3:
            result[parts[0]] = {"rows": int(parts[1]), "md5": parts[2]}
    require(set(result) == set(tables), "Incomplete database comparison")
    return result


def backup(database, release):
    name, user, db = database
    target = release / (name + ".before.dump")
    with os.fdopen(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as stream:
        run(["docker", "exec", name, "pg_dump", "-U", user, "-d", db,
             "-Fc", "--no-owner", "--no-acl"], stdout=stream)
    with target.open("rb") as stream:
        run(["docker", "exec", "-i", name, "pg_restore", "--list"], stdin=stream, stdout=subprocess.DEVNULL)
    return {"path": str(target), "sha256": sha256(target)}


def health():
    for attempt in range(20):
        try:
            with urlopen(ORIGIN + "/health", timeout=3) as response:
                require(json.loads(response.read())["status"] == "ok", "API health failed")
            return
        except Exception:
            if attempt == 19:
                raise
            time.sleep(1)


def public_packages(manifest):
    # Exercise the real gateway without downloading a second full copy of each package.
    for item in (manifest["android"], manifest["windows"]):
        with urlopen(Request(item["url"], method="HEAD"), timeout=15) as response:
            require(int(response.headers["Content-Length"]) == item["size"], "Public package size mismatch")


def publish(args):
    require(re.fullmatch(r"\d+\.\d+\.\d+", args.version), "Invalid version")
    require(args.build > 0 and re.fullmatch(r"[a-z0-9.-]+", args.release), "Invalid release/build")
    archive = Path(args.archive).resolve()
    require(sha256(archive) == args.sha256.lower(), "Upload archive hash mismatch")
    root = Path(args.root).resolve()
    deploy = root / "deploy"
    public = deploy / "app-updates"
    require(not public.is_symlink(), "Update directory must not be a symlink")
    release = root / "releases" / args.release
    release.mkdir(mode=0o700, exist_ok=False)
    staging, manifest = unpack(archive, release, args.version, args.build)
    caddy_path, compose_path = deploy / "Caddyfile", deploy / "compose.yaml"
    originals = {path: path.read_bytes() for path in (caddy_path, compose_path)}
    changed_caddy, changed_compose = patch_config(originals[caddy_path].decode(), originals[compose_path].decode())
    candidates = {caddy_path: changed_caddy.encode(), compose_path: changed_compose.encode()}
    for path, data in originals.items():
        write_new(release / (path.name + ".before"), data)
        write_new(release / (path.name + ".candidate"), candidates[path])
    public.mkdir(mode=0o755, exist_ok=True)
    old_manifest = (public / "stable.json").read_bytes() if (public / "stable.json").exists() else None
    if old_manifest is not None:
        write_new(release / "stable.json.before", old_manifest)
        previous = json.loads(old_manifest)
        require(all(previous[p]["build"] <= args.build for p in ("android", "windows")), "Refusing a build downgrade")
    image = inspect("deploy-caddy-1")["Image"]
    run(["docker", "run", "--rm", "--network", "chereda_gateway", "--entrypoint", "caddy",
         "-v", f"{release / 'Caddyfile.candidate'}:/etc/caddy/Caddyfile:ro",
         "-v", f"{deploy / 'organizations'}:/etc/caddy/organizations:ro",
         "-v", f"{public}:/srv/app-updates:ro", image,
         "validate", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"], stdout=subprocess.DEVNULL)
    run(["docker", "compose", "--project-directory", str(deploy), "-f",
         str(release / "compose.yaml.candidate"), "config", "--quiet"], stdout=subprocess.DEVNULL)
    all_databases = databases()
    backups = {item[0]: backup(item, release) for item in all_databases}
    before = {item[0]: fingerprint(item) for item in all_databases}
    write_new(release / "data.before.json", json.dumps(before, indent=2).encode())
    print("BACKUPS_READY", json.dumps(backups), flush=True)
    version_dir = public / args.version
    if version_dir.exists():
        require(version_dir.is_dir() and not version_dir.is_symlink(), "Invalid existing version path")
        for path in (staging / args.version).iterdir():
            require((version_dir / path.name).is_file() and sha256(version_dir / path.name) == sha256(path),
                    "Immutable version already exists with different content")
    else:
        os.rename(staging / args.version, version_dir)
    modified_config = False
    published_manifest = False
    compose = ["docker", "compose", "-f", str(compose_path)]
    try:
        require(all(path.read_bytes() == content for path, content in originals.items()),
                "Server configuration changed during preparation")
        for path, content in candidates.items():
            if content != originals[path]:
                modified_config = True
                atomic_write(path, content, path.stat().st_mode & 0o777)
        mounted = any(item["Destination"] == "/srv/app-updates" and item["Source"] == str(public)
                      and item["RW"] is False for item in inspect("deploy-caddy-1")["Mounts"])
        if modified_config or not mounted:
            run(compose + ["up", "-d", "--no-build", "--no-deps", "--force-recreate", "caddy"], stdout=subprocess.DEVNULL)
        health()
        public_packages(manifest)
        # Publish stable.json last, only once both package URLs are reachable.
        atomic_write(public / "stable.json", (staging / "stable.json").read_bytes(), 0o644)
        published_manifest = True
        with urlopen(Request(ORIGIN + "/updates/stable.json", headers={"Cache-Control": "no-cache"}), timeout=15) as response:
            require(json.loads(response.read()) == manifest, "Published manifest verification failed")
    except Exception:
        if published_manifest:
            if old_manifest is None:
                (public / "stable.json").unlink()
            else:
                atomic_write(public / "stable.json", old_manifest, 0o644)
        if modified_config:
            for path, content in originals.items():
                atomic_write(path, content, path.stat().st_mode & 0o777)
            run(compose + ["up", "-d", "--no-build", "--no-deps", "--force-recreate", "caddy"], stdout=subprocess.DEVNULL)
        # Never restore a database: users may have entered new information meanwhile.
        raise
    after = {item[0]: fingerprint(item) for item in all_databases}
    write_new(release / "data.after.json", json.dumps(after, indent=2).encode())
    state = {"version": args.version, "build": args.build, "manifest": ORIGIN + "/updates/stable.json",
             "backups": backups, "data_unchanged": before == after, "api_recreated": False}
    write_new(release / "state.json", json.dumps(state, indent=2).encode())
    print("PUBLISHED", json.dumps(state), flush=True)
    require(before == after,
            "Records changed during publication. Compare private snapshots for concurrent user activity; nothing was restored.")


def main():
    import fcntl  # Host-only locking; config and archive helpers remain testable on Windows.
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--root", default="/opt/shift_tracker")
    args = parser.parse_args()
    deploy = Path(args.root).resolve() / "deploy"
    # Use the provisioner's existing lock so organization routes can't change midway.
    with (deploy / ".registration-worker.lock").open("a") as registration_lock, \
            (deploy / ".app-update-publisher.lock").open("a") as publisher_lock:
        for lock in (registration_lock, publisher_lock):
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError("Another publication/organization setup is running; retry when it finishes") from None
        publish(args)


if __name__ == "__main__":
    main()
