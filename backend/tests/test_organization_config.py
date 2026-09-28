import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('prepare_organization',
    Path(__file__).resolve().parents[2] / 'deploy' / 'prepare_organization.py')
prepare_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare_module)


class OrganizationConfigTests(unittest.TestCase):
    def test_configs_are_private_distinct_and_never_overwritten(self):
        with tempfile.TemporaryDirectory(prefix='chereda-config-test-') as temporary:
            root = Path(temporary)
            env_a, route_a = prepare_module.prepare(root, 'company-a', 'ООО «А»')
            env_b, _ = prepare_module.prepare(root, 'company-b', 'ООО «Б»')
            values_a = dict(line.split('=', 1) for line in env_a.read_text(encoding='utf-8').splitlines())
            values_b = dict(line.split('=', 1) for line in env_b.read_text(encoding='utf-8').splitlines())
            for key in ('POSTGRES_PASSWORD', 'JWT_SECRET', 'BOOTSTRAP_TOKEN'):
                self.assertNotEqual(values_a[key], values_b[key])
            self.assertEqual(route_a.suffix, '.pending')
            self.assertIn('org-company-a-api:8000', route_a.read_text())
            before = env_a.read_bytes()
            with self.assertRaises(FileExistsError):
                prepare_module.prepare(root, 'company-a', 'Replacement')
            self.assertEqual(env_a.read_bytes(), before)

    def test_unsafe_and_reserved_selectors_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix='chereda-config-test-') as temporary:
            root = Path(temporary)
            for code in ('../escape', 'tehnodor-sk', 'a/b', 'x', 'abc\nxyz'):
                with self.assertRaises(ValueError):
                    prepare_module.prepare(root, code, 'Name')
            for name in ('', 'bad\nname', '${JWT_SECRET}', 'bad\\name'):
                with self.assertRaises(ValueError):
                    prepare_module.prepare(root, 'company-a', name)
            self.assertEqual(list(root.iterdir()), [])
