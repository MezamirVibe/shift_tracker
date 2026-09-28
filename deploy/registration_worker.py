"""Host-only signup provisioner. Public API never receives the Docker socket."""
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

from prepare_organization import prepare

ROOT = Path(__file__).resolve().parent
ORGS = ROOT / 'organizations'
CONTROL = 'deploy-api-1'


def run(args, *, data=None, timeout=180):
    # Capture output: configuration errors can include secrets. Never forward it to journals.
    result = subprocess.run(args, input=data, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('Provisioning command failed')
    return result.stdout


def private(action, data=None, container=CONTROL):
    return json.loads(run(['docker', 'exec', '-i', container, 'python', '-m',
                           'app.registration', action], data=json.dumps(data or {}).encode()))


def provision(job):
    code = job['code']
    assert re.fullmatch(r'org-[a-f0-9]{16}', code)
    assert re.fullmatch(r'[a-f0-9-]{36}', job['request_id'])
    ORGS.mkdir(mode=0o700, exist_ok=True)
    marker = ORGS / (code + '.registration')
    if marker.exists():
        assert marker.read_text() == job['request_id']
    else:
        assert not any((ORGS / (code + ext)).exists() for ext in ('.env', '.pending', '.caddy'))
        with os.fdopen(os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as stream:
            stream.write(job['request_id'])
    env_path = ORGS / (code + '.env')
    if not env_path.exists():
        prepare(ORGS, code, job['name'])
    pending = ORGS / (code + '.pending')
    published = ORGS / (code + '.caddy')
    assert pending.exists() or published.exists()
    compose = ['docker', 'compose', '-p', 'chereda-' + code, '--env-file', str(env_path),
               '-f', str(ROOT / 'compose.organization.yaml')]
    run(compose + ['up', '-d', '--no-build'])
    api = 'chereda-' + code + '-api-1'
    info_script = "import json,urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/api/v1/organization').read().decode())"
    for attempt in range(35):
        try:
            info = json.loads(run(['docker', 'exec', api, 'python', '-c', info_script], timeout=10))
            assert info == {'code': code, 'name': job['name']}
            break
        except (RuntimeError, subprocess.TimeoutExpired):
            if attempt == 34:
                raise
            time.sleep(1)
    private('install-owner', job, container=api)
    expected_route = f'handle_path /o/{code}/* {{\n\treverse_proxy org-{code}-api:8000\n}}\n'
    if published.exists():
        assert published.read_text() == expected_route
    else:
        assert pending.read_text() == expected_route
        with os.fdopen(os.open(published, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as stream:
            stream.write(expected_route)
    caddy = ['docker', 'exec', 'deploy-caddy-1', 'caddy']
    run(caddy + ['validate', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile'])
    run(caddy + ['reload', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile'])
    # Read through the actual shared HTTPS gateway before reporting success.
    gateway_script = "import json,urllib.request; print(urllib.request.urlopen('https://api.mezamir.com/o/" + code + "/api/v1/organization',timeout=10).read().decode())"
    info = json.loads(run(['docker', 'exec', CONTROL, 'python', '-c', gateway_script], timeout=15))
    assert info == {'code': code, 'name': job['name']}
    private('ready', job)


def main():
    # One process for this host; SQL also guards the durable job queue.
    with (ROOT / '.registration-worker.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        job = private('claim')
        if not job:
            return
        try:
            provision(job)
            print('Organization registration completed', job['request_id'], flush=True)
        except Exception:
            # A crash is retried after a lease expires. Do not erase any tenant data or config.
            print('Organization registration requires retry', job['request_id'], file=sys.stderr, flush=True)
            raise SystemExit(1) from None


if __name__ == '__main__':
    main()
