"""Regression tests: package closure, stale databases, mode switching and boot safety."""
import importlib.util
import io
import json
import re
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('release', ROOT / 'scripts/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = self.root / 'packages'
        self.store.mkdir()

    def pkg(self, name, version, depends=()):
        filename = f'{name}-{version}-any.pkg.tar.zst'
        text = f'pkgname = {name}\npkgbase = {name}\npkgver = {version}\npkgdesc = test\narch = any\nsize = 1\n'
        text += ''.join(f'depend = {dep}\n' for dep in depends)
        # libarchive detects compression by content; uncompressed tiny fixtures avoid zstd dependency.
        with tarfile.open(self.store / filename, 'w') as tar:
            entry = tarfile.TarInfo('.PKGINFO')
            data = text.encode()
            entry.size = len(data)
            tar.addfile(entry, io.BytesIO(data))
        (self.store / (filename + '.sig')).write_bytes(b'test-signature')
        return filename

    def test_clean_repository_ignores_unselected_versions_and_packages(self):
        dep = self.pkg('dep', '1-1')
        app = self.pkg('app', '2-1', ('dep=1-1',))
        self.pkg('app', '1-1')
        self.pkg('stale', '1-1')
        dest = self.root / 'repo'
        info = release.package_info(self.store.glob('*.pkg.tar.zst'))
        release.build_repo(dest, [app, dep], self.store, info, ['app'])
        self.assertEqual(set(release.read_db(dest)), {'app', 'dep'})
        self.assertEqual(release.resolve(dest, ['app']), {app, dep})
        self.assertFalse((dest / 'stale-1-1-any.pkg.tar.zst').exists())

    def test_repository_path_with_spaces(self):
        app = self.pkg('app', '1-1')
        dest = self.root / 'portable bundle/repo'
        release.build_repo(dest, [app], self.store, release.package_info([self.store / app]), ['app'])
        self.assertEqual(release.resolve(dest, ['app']), {app})

    def test_failed_repository_does_not_replace_existing_database(self):
        app = self.pkg('app', '1-1', ('missing-dependency',))
        dest = self.root / 'repo'
        dest.mkdir()
        (dest / 'marker').write_text('old repo')
        info = release.package_info([self.store / app])
        with self.assertRaises(subprocess.CalledProcessError):
            release.build_repo(dest, [app], self.store, info, ['app'])
        self.assertEqual((dest / 'marker').read_text(), 'old repo')
        self.assertEqual(list(self.root.glob('.repo-*')), [])

    def test_duplicate_package_names_are_rejected(self):
        files = [self.pkg('app', '1-1'), self.pkg('app', '2-1')]
        info = release.package_info(self.store / f for f in files)
        with self.assertRaisesRegex(ValueError, '重复包名'):
            release.build_repo(self.root / 'repo', files, self.store, info, ['app'])

    def test_missing_signature_is_rejected(self):
        app = self.pkg('app', '1-1')
        (self.store / (app + '.sig')).unlink()
        with self.assertRaisesRegex(ValueError, '缺少文件'):
            release.build_repo(self.root / 'repo', [app], self.store,
                               release.package_info([self.store / app]), ['app'])

    def test_snapshot_detects_tampering(self):
        path = self.root / 'package'
        path.write_text('original')
        lock = {'sha256': {'package': release.sha(path)}}
        path.write_text('tampered')
        with self.assertRaisesRegex(ValueError, '快照校验失败'):
            release.validate_snapshot(self.root, lock)

    def test_frozen_release_cannot_be_overwritten(self):
        (self.root / 'snapshots/r1').mkdir(parents=True)
        with patch.object(release, 'ROOT', self.root), patch.object(release, 'check_upstream'):
            with self.assertRaisesRegex(ValueError, '不可覆盖'):
                release.freeze('r1')

    def test_package_list_drift_is_rejected_before_build(self):
        snapshot = self.root / 'snapshots/r1'
        (snapshot / 'inputs').mkdir(parents=True)
        (self.root / 'config').mkdir()
        (snapshot / 'inputs/target.txt').write_text('old\n')
        (self.root / 'config/packages.txt').write_text('changed\n')
        lock = {'upstream_commit': release.UPSTREAM}
        with patch.object(release, 'ROOT', self.root), patch.object(release, 'check_upstream'), patch.object(release, 'load', return_value=('r1', snapshot, lock)):
            with self.assertRaisesRegex(ValueError, '目标包清单已改变'):
                release.verify()

    def test_live_list_passes_real_mkarchiso_boot_package_validation(self):
        executable = shutil.which('mkarchiso')
        if not executable:
            self.skipTest('mkarchiso is not installed')
        source = Path(executable).read_text()
        validator = re.search(r'^_validate_requirements_bootmode_bios\.syslinux\(\) \{\n.*?^\}', source, re.M | re.S)
        self.assertIsNotNone(validator, 'mkarchiso BIOS validator changed; update the regression test')
        names = ['syslinux', 'memtest86+', 'memtest86+-efi', 'edk2-shell']
        lock = {'packages': {'live': names}, 'info': {n: {'name': n, 'version': '1-1'} for n in names}}
        (self.root / 'syslinux').mkdir()
        (self.root / 'syslinux/syslinux.cfg').touch()
        packages = self.root / 'packages.x86_64'
        script = (validator.group() + '\n'
                  '_validate_common_requirements_bootmode_bios() { return 0; }\n'
                  '_msg_error() { echo "$*" >&2; }\n'
                  '_msg_info() { echo "$*"; }\n'
                  'profile=$1; bootmode=bios.syslinux; validation_error=0\n'
                  'mapfile -t pkg_list < "$profile/packages.x86_64"\n'
                  '_validate_requirements_bootmode_bios.syslinux\n'
                  'exit "$validation_error"\n')
        # Reproduce the reported bug against the real installed validator.
        packages.write_text(''.join(f'{n}=1-1\n' for n in names))
        broken = subprocess.run(['bash', '-c', script, 'test', str(self.root)], capture_output=True, text=True)
        self.assertNotEqual(broken.returncode, 0)
        self.assertIn("'syslinux' package is missing", broken.stderr)
        packages.write_text(release.live_package_list(lock))
        fixed = subprocess.run(['bash', '-c', script, 'test', str(self.root)], capture_output=True, text=True)
        self.assertEqual(fixed.returncode, 0, fixed.stderr)
        self.assertEqual(packages.read_text().splitlines(), names)
        self.assertNotIn('not in the package list', fixed.stdout)

    def test_repository_aliases_are_local(self):
        app = self.pkg('app', '1-1')
        dest = self.root / 'repo'
        release.build_repo(dest, [app], self.store, release.package_info([self.store / app]), ['app'])
        self.assertTrue((dest / 'offline.db').is_file())
        self.assertEqual((dest / 'offline.db').read_bytes(), (dest / 'offline.db.tar.zst').read_bytes())


class InstallerTests(unittest.TestCase):
    def bash(self, code, *args):
        return subprocess.run(['bash', '-c', code, 'test', *map(str, args)], capture_output=True, text=True)

    def test_coexistence_firmware_matrix(self):
        cases = [
            ('uefi', 'gpt', 'no', '1', True),
            ('uefi', 'gpt', 'no', '0', False),
            ('uefi', 'gpt', 'yes', '2', False),
            ('bios', 'gpt', 'yes', '0', True),
            ('bios', 'gpt', 'no', '0', False),
            ('bios', 'gpt', 'yes', '1', False),
            ('bios', 'dos', 'no', '0', True),
            ('bios', 'unknown', 'no', '0', False),
        ]
        for firmware, table, bios, esps, success in cases:
            with self.subTest(firmware=firmware, table=table, bios=bios, esps=esps):
                result = self.bash('source "$1"; validate_coexistence_boot "$2" "$3" "$4" "$5"',
                                   ROOT / 'installer/boot-policy.sh', firmware, table, bios, esps)
                self.assertEqual(result.returncode == 0, success, result.stderr)

    def test_mode_switch_replaces_config_and_preserves_custom_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            for mode in ('offline', 'online'):
                shutil.copyfile(ROOT / f'installer/pacman-installed-{mode}.conf', tmp / f'pacman-{mode}.conf')
            config = tmp / 'pacman.conf'
            shutil.copyfile(tmp / 'pacman-offline.conf', config)
            call = 'source "$1"; write_repo_mode "$2" "$3" "$4"'
            result = self.bash(call, ROOT / 'installer/repo-mode.sh', 'online', config, tmp)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('[offline]', config.read_text())
            self.assertIn('[cachyos-v3]', config.read_text())
            self.assertIn('[offline]', Path(str(config) + '.before-mode-switch').read_text())
            config.write_text(config.read_text() + '\n# user custom configuration\n')
            original = config.read_text()
            result = self.bash(call, ROOT / 'installer/repo-mode.sh', 'offline', config, tmp)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(config.read_text(), original)

    def test_failed_online_upgrade_keeps_online_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            assets = root / 'assets'
            assets.mkdir()
            for mode in ('online', 'offline'):
                shutil.copyfile(ROOT / f'installer/pacman-installed-{mode}.conf', assets / f'pacman-{mode}.conf')
            config = root / 'pacman.conf'
            shutil.copyfile(assets / 'pacman-offline.conf', config)
            fake = root / 'pacman'
            fake.write_text('#!/bin/sh\n[ "$*" = "-Syu" ] || exit 99\nexit 17\n')
            fake.chmod(0o755)
            result = self.bash('export PATH="$2:$PATH"; source "$1"; switch_repo_mode online "$3" "$4" "$5"',
                               ROOT / 'installer/repo-mode.sh', root, config, assets, root / 'repo')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(config.read_bytes(), (assets / 'pacman-online.conf').read_bytes())
            self.assertIn('升级未完成', result.stderr)

    def test_changed_installed_version_blocks_return_to_old_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'target-versions.txt').write_text('app 1-1\n')
            (root / 'offline.db').touch()
            config = root / 'pacman.conf'
            config.write_text('online configuration')
            fake = root / 'pacman'
            fake.write_text('#!/bin/sh\necho "app 2-1"\n')
            fake.chmod(0o755)
            result = self.bash('export PATH="$2:$PATH"; source "$1"; switch_repo_mode offline "$3" "$2" "$2"',
                               ROOT / 'installer/repo-mode.sh', root, config)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(config.read_text(), 'online configuration')
            self.assertIn('拒绝切回旧仓库', result.stderr)

    def test_symlinked_installer_resolves_payload_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'payload/offline-install').mkdir(parents=True)
            (root / 'offline-install').symlink_to('payload/offline-install')
            result = self.bash('cd "$1"; pwd -P', root / 'offline-install')
            self.assertEqual(result.stdout.strip(), str(root / 'payload/offline-install'))


if __name__ == '__main__':
    unittest.main()
