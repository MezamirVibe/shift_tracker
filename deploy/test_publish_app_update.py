"""Narrow tests for the publishing boundary; never contacts Docker or production."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("publisher", Path(__file__).with_name("publish-app-update.py"))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublisherTests(unittest.TestCase):
    def test_host_changes_are_preserved_and_insertion_is_idempotent(self):
        deploy = Path(__file__).parent
        caddy = (deploy / "Caddyfile").read_text("utf-8").replace(publisher.HANDLER, "")
        caddy = caddy.replace("\timport /etc/caddy/organizations/*.caddy",
                              "\t# Keep an administrator's existing change\n\timport /etc/caddy/organizations/*.caddy")
        compose = (deploy / "compose.yaml").read_text("utf-8").replace(publisher.MOUNT, "")
        patched = publisher.patch_config(caddy, compose)
        self.assertEqual(patched[0].replace(publisher.HANDLER, ""), caddy)
        self.assertEqual(patched[1].replace(publisher.MOUNT, ""), compose)
        self.assertEqual(publisher.patch_config(*patched), patched)

    def test_unknown_existing_handler_is_rejected(self):
        deploy = Path(__file__).parent
        caddy = (deploy / "Caddyfile").read_text("utf-8").replace("/srv/app-updates", "/srv/unknown")
        with self.assertRaisesRegex(RuntimeError, "handler differs"):
            publisher.patch_config(caddy, (deploy / "compose.yaml").read_text("utf-8"))

    def bundle(self, directory, *, tamper=False, extra=False):
        files = {}
        manifest = {"schema": 1}
        for platform, extension in (("android", "apk"), ("windows", "zip")):
            name = f"1.7.0/Chereda-1.7.0-{platform}.{extension}"
            content = (platform + "-test-fixture").encode()
            files[name] = content
            manifest[platform] = {"version": "1.7.0", "build": 13,
                                  "url": publisher.ORIGIN + "/updates/" + name,
                                  "sha256": hashlib.sha256(content).hexdigest(),
                                  "size": len(content), "notes": ["Обновление"]}
        if tamper:
            manifest["android"]["sha256"] = "0" * 64
        files["stable.json"] = json.dumps(manifest).encode()
        if extra:
            files["../private.txt"] = b"must not be published"
        target = directory / "release.tar.gz"
        with tarfile.open(target, "w:gz") as archive:
            for name, content in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
        release = directory / "release"
        release.mkdir()
        return target, release

    def test_valid_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive, release = self.bundle(Path(temporary))
            staging, manifest = publisher.unpack(archive, release, "1.7.0", 13)
            self.assertEqual(manifest["android"]["build"], 13)
            self.assertTrue((staging / "1.7.0/Chereda-1.7.0-windows.zip").exists())

    def test_tampered_package_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive, release = self.bundle(Path(temporary), tamper=True)
            with self.assertRaisesRegex(RuntimeError, "size/hash mismatch"):
                publisher.unpack(archive, release, "1.7.0", 13)

    def test_extra_or_traversal_member_is_rejected_before_extracting(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive, release = self.bundle(Path(temporary), extra=True)
            with self.assertRaisesRegex(RuntimeError, "exactly"):
                publisher.unpack(archive, release, "1.7.0", 13)
            self.assertFalse((release / "private.txt").exists())


if __name__ == "__main__":
    unittest.main()
