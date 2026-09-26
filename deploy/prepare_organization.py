"""Generate private configuration only; does not start containers or publish routes."""
import argparse
import os
from pathlib import Path
import re
import secrets


def prepare(directory: Path, code: str, name: str):
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{1,47}', code) or code == 'tehnodor-sk':
        raise ValueError('Use a new organization code (2-48 lowercase letters, digits, hyphens)')
    if not name.strip() or len(name) > 200 or any(c in name for c in "\r\n\0$'\\"):
        raise ValueError('Invalid organization name for a deployment environment file')
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    env_path, route_path = directory / f'{code}.env', directory / f'{code}.pending'
    if env_path.exists() or route_path.exists() or (directory / f'{code}.caddy').exists():
        raise FileExistsError('Organization configuration already exists; never overwrite its secrets')
    values = {'ORGANIZATION_CODE': code, 'ORGANIZATION_NAME': name.strip(),
              'POSTGRES_DB': 'chereda', 'POSTGRES_USER': 'chereda',
              'POSTGRES_PASSWORD': secrets.token_hex(32), 'JWT_SECRET': secrets.token_hex(48),
              'BOOTSTRAP_TOKEN': secrets.token_hex(48)}
    # O_EXCL prevents accidental overwrites and mode 0600 applies at creation.
    with os.fdopen(os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w', encoding='utf-8') as stream:
        stream.write(''.join(f"{key}='{value}'\n" for key, value in values.items()))
    with os.fdopen(os.open(route_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w', encoding='utf-8') as stream:
        stream.write(f'handle_path /o/{code}/* {{\n\treverse_proxy org-{code}-api:8000\n}}\n')
    return env_path, route_path


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('code')
    parser.add_argument('name')
    args = parser.parse_args()
    env_path, route_path = prepare(Path(__file__).resolve().parent / 'organizations', args.code, args.name)
    print('Prepared private configuration:', env_path)
    print('Unpublished route:', route_path)
    print('Follow deploy/ORGANIZATIONS.md to start, bootstrap, verify and publish.')
