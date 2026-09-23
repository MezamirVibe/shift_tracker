"""Package already verified Android/Windows builds for the update publisher."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import tarfile
import zipfile


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--windows', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', type=int, required=True)
    parser.add_argument('--note', action='append', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version) or not 0 < args.build <= 65535:
        parser.error('Invalid version/build')
    for path in (args.apk, args.windows):
        if not path.is_file() or not 0 < path.stat().st_size <= 250 * 1024 * 1024:
            parser.error(f'Invalid build file: {path}')
    with zipfile.ZipFile(args.windows) as archive:
        required = {'shift_tracker.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat'}
        if not required.issubset(set(archive.namelist())):
            parser.error('Windows ZIP must contain the app at its root')
    args.output.mkdir(parents=True, exist_ok=False)
    version_dir = args.output / args.version
    version_dir.mkdir()
    manifest = {'schema': 1}
    files = []
    for platform, source, extension in [('android', args.apk, 'apk'), ('windows', args.windows, 'zip')]:
        name = f'Chereda-{args.version}-{platform}.{extension}'
        target = version_dir / name
        shutil.copyfile(source, target)
        manifest[platform] = {
            'version': args.version, 'build': args.build,
            'url': f'https://api.mezamir.com/updates/{args.version}/{name}',
            'sha256': digest(target), 'size': target.stat().st_size, 'notes': args.note,
        }
        files.append(target)
    metadata = args.output / 'stable.json'
    metadata.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    bundle = args.output / f'app-updates-{args.version}.tar.gz'
    with tarfile.open(bundle, 'w:gz') as archive:
        for path in [metadata, *files]:
            archive.add(path, arcname=path.relative_to(args.output).as_posix(), recursive=False)
    print(json.dumps({'archive': str(bundle), 'sha256': digest(bundle), 'manifest': manifest}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
