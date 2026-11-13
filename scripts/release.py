#!/usr/bin/env python3
"""Immutable package snapshots, clean local repositories and portable installers."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
UPSTREAM = '3215497d2e8c5fea90e185affcf973dfa2cf790b'


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def capture(args):
    return run(args, stdout=subprocess.PIPE, text=True).stdout


def sha(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    run(['cp', '--reflink=auto', '--', source, target])


def upstream_file(path):
    return subprocess.check_output(['git', '-C', str(ROOT / 'CachyOS-Live-ISO'), 'show', f'{UPSTREAM}:{path}'])


def check_upstream():
    head = capture(['git', '-C', ROOT / 'CachyOS-Live-ISO', 'rev-parse', 'HEAD']).strip()
    if head != UPSTREAM:
        raise ValueError(f'上游 HEAD {head} 与锁定 commit {UPSTREAM} 不一致')


def package_list(path):
    return [line.split('#', 1)[0].strip() for line in path.read_text().splitlines()
            if line.split('#', 1)[0].strip()]


def package_info(paths):
    paths = list(paths)
    if not paths:
        raise ValueError('空包集合')
    # pacman reads actual .PKGINFO, rather than trying to split hyphenated filenames.
    rows = capture(['pacman', '-Qp', *paths]).splitlines()
    if len(rows) != len(paths):
        raise ValueError('pacman -Qp 返回了不完整的包信息')
    return {p.name: dict(zip(('name', 'version'), row.split())) for p, row in zip(paths, rows)}


def local_conf(repo, name='offline'):
    return ('[options]\nArchitecture = auto\nSigLevel = Required DatabaseOptional\n'
            f'DisableSandbox\nCacheDir = {repo}/\n\n[{name}]\nServer = file://{repo}/\n')


def resolve(repo, packages):
    with tempfile.TemporaryDirectory(prefix='cachyos-resolve-') as tmp:
        tmp = Path(tmp)
        (tmp / 'db/sync').mkdir(parents=True)
        copy(repo / 'offline.db.tar.zst', tmp / 'db/sync/offline.db')
        (tmp / 'pacman.conf').write_text(local_conf(repo))
        return set(capture(['pacman', '-Sp', '--noconfirm', '--config', tmp / 'pacman.conf',
                            '--dbpath', tmp / 'db', '--print-format', '%f', *packages]).splitlines())


def read_db(repo):
    rows = {}
    with tarfile.open(repo / 'offline.db.tar.zst', 'r') as archive:
        for member in archive:
            if not member.name.endswith('/desc'):
                continue
            fields = {}
            for field in archive.extractfile(member).read().decode().strip().split('\n\n'):
                values = field.splitlines()
                fields[values[0]] = values[1:]
            name = fields['%NAME%'][0]
            if name in rows:
                raise ValueError(f'数据库中包名重复: {name}')
            rows[name] = (fields['%VERSION%'][0], fields['%FILENAME%'][0])
    return rows


def build_repo(destination, filenames, store, info, top_packages):
    """Never update an existing database: stage, validate, then publish a new directory."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.repo-', dir=destination.parent))
    try:
        names = set()
        for filename in filenames:
            if info[filename]['name'] in names:
                raise ValueError(f'同一个仓库包含重复包名: {filename}')
            names.add(info[filename]['name'])
            for suffix in ('', '.sig'):
                source = store / (filename + suffix)
                if not source.is_file():
                    raise ValueError(f'缺少文件: {source}')
                # Independent inodes keep a consumer from modifying the snapshot store.
                copy(source, stage / source.name)
        with open(stage / 'repo-add.log', 'w') as log:
            run(['repo-add', 'offline.db.tar.zst', *sorted(filenames)], cwd=stage,
                stdout=log, stderr=subprocess.STDOUT)
        expected = {info[f]['name']: (info[f]['version'], f) for f in filenames}
        if read_db(stage) != expected:
            raise ValueError('仓库数据库与版本清单不一致')
        if resolve(stage, top_packages) != set(filenames):
            raise ValueError('离线依赖闭包与版本清单不一致')
        if destination.exists():
            raise ValueError(f'拒绝覆盖已发布仓库: {destination}')
        stage.rename(destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def active_id(value=None):
    release = value or (ROOT / 'config/release').read_text().strip()
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*', release):
        raise ValueError('无效的发布编号')
    return release


def load(release=None):
    release = active_id(release)
    lock = json.loads((ROOT / 'releases' / f'{release}.json').read_text())
    return release, ROOT / 'snapshots' / release, lock


def validate_snapshot(snapshot, lock):
    for path, digest in lock['sha256'].items():
        if sha(snapshot / path) != digest:
            raise ValueError(f'快照校验失败: {path}')
    for scope in ('target', 'live'):
        filenames = lock['packages'][scope]
        repo = snapshot / f'{scope}-repo'
        actual_files = {p.name for p in repo.glob('*.pkg.tar.*') if not p.name.endswith('.sig')}
        if actual_files != set(filenames):
            raise ValueError(f'{scope} 仓库有缺失或多余包')
        for alias, target in (('offline.db', 'offline.db.tar.zst'), ('offline.files', 'offline.files.tar.zst')):
            link = repo / alias
            if not link.is_symlink() or os.readlink(link) != target:
                raise ValueError(f'{scope} 仓库别名被修改: {alias}')
        expected = {lock['info'][f]['name']: (lock['info'][f]['version'], f) for f in filenames}
        if read_db(repo) != expected:
            raise ValueError(f'{scope} 数据库与锁定包不一致')
        if resolve(repo, package_list(snapshot / f'inputs/{scope}.txt')) != set(filenames):
            raise ValueError(f'{scope} 依赖闭包改变')


def verify(release=None):
    check_upstream()
    release, snapshot, lock = load(release)
    if lock['upstream_commit'] != UPSTREAM:
        raise ValueError('快照锁定的上游 commit 不匹配')
    if (snapshot / 'inputs/target.txt').read_bytes() != (ROOT / 'config/packages.txt').read_bytes():
        raise ValueError('目标包清单已改变；请显式创建新发布快照')
    if (snapshot / 'inputs/target-pacman.conf').read_bytes() != (ROOT / 'config/pacman-v3.conf').read_bytes():
        raise ValueError('下载仓库配置已改变；请显式创建新发布快照')
    if (snapshot / 'inputs/live.txt').read_bytes() != upstream_file('archiso/packages_desktop.x86_64'):
        raise ValueError('Live 包清单与固定上游不一致')
    validate_snapshot(snapshot, lock)
    print(f'==> 快照 {release} 校验通过（target={len(lock["packages"]["target"])}, live={len(lock["packages"]["live"])}）')
    return release, snapshot, lock


def prepare_download(stage, scope, conf, top_packages):
    db = stage / f'source-db/{scope}'
    db.mkdir(parents=True)
    store = stage / f'download-{scope}'
    store.mkdir()
    prefix = [] if os.geteuid() == 0 else ['sudo']
    try:
        run([*prefix, 'pacman', '-Sy', '--config', conf, '--dbpath', db])
        filenames = capture(['pacman', '-Sp', '--noconfirm', '--config', conf, '--dbpath', db,
                             '--print-format', '%f', *top_packages]).splitlines()
        # The same isolated database resolves and downloads: never re-sync mid-transaction.
        run([*prefix, 'pacman', '-Sw', '--noconfirm', '--config', conf, '--dbpath', db,
             '--cachedir', store, *top_packages])
    finally:
        if prefix:
            run(['sudo', 'chown', '-R', f'{os.getuid()}:{os.getgid()}', db, store])
    return sorted(set(filenames)), store


def freeze(release, import_current=False):
    check_upstream()
    release = active_id(release)
    base = ROOT / 'snapshots'
    base.mkdir(exist_ok=True)
    destination = base / release
    metadata = ROOT / 'releases' / f'{release}.json'
    if destination.exists() or metadata.exists():
        raise ValueError('发布编号已存在；快照不可覆盖，请使用新编号')
    stage = Path(tempfile.mkdtemp(prefix='.snapshot-', dir=base))
    try:
        inputs = stage / 'inputs'
        inputs.mkdir()
        copy(ROOT / 'config/packages.txt', inputs / 'target.txt')
        copy(ROOT / 'config/pacman-v3.conf', inputs / 'target-pacman.conf')
        (inputs / 'live.txt').write_bytes(upstream_file('archiso/packages_desktop.x86_64'))
        (inputs / 'live-pacman.conf').write_bytes(upstream_file('archiso/pacman.conf'))
        (inputs / 'bootstrap.txt').write_bytes(upstream_file('archiso/bootstrap_packages.x86_64'))
        # Preserve the exact mirror configuration used when preparing this release.
        mirror_dir = inputs / 'mirrors'
        mirror_dir.mkdir()
        for name in ('mirrorlist', 'cachyos-mirrorlist', 'cachyos-v3-mirrorlist'):
            copy(Path('/etc/pacman.d') / name, mirror_dir / name)
        selected = {}
        stores = {}
        if import_current:
            selected['target'] = sorted(set((ROOT / 'logs/manifest.txt').read_text().splitlines()))
            stores['target'] = ROOT / 'repo'
            cache_info = package_info(sorted((ROOT / 'pkg-cache').glob('*.pkg.tar.zst')))
            installed = dict(line.split() for line in (ROOT / 'CachyOS-Live-ISO/build/iso/arch/pkglist.x86_64.txt').read_text().splitlines())
            selected['live'] = []
            for name, version in installed.items():
                matches = [f for f, item in cache_info.items() if item == {'name': name, 'version': version}]
                if len(matches) != 1:
                    raise ValueError(f'缓存不能唯一还原已安装 Live 包: {name} {version}')
                selected['live'].append(matches[0])
            selected['live'].sort()
            stores['live'] = ROOT / 'pkg-cache'
            shutil.copytree(ROOT / 'db/sync', stage / 'source-db/target/sync')
            copy(ROOT / 'CachyOS-Live-ISO/build/iso/arch/pkglist.x86_64.txt', inputs / 'imported-live-pkglist.txt')
        else:
            for scope in ('target', 'live'):
                conf = inputs / f'{scope}-pacman.conf'
                for name in ('mirrorlist', 'cachyos-mirrorlist', 'cachyos-v3-mirrorlist'):
                    conf.write_text(conf.read_text().replace(f'/etc/pacman.d/{name}', str(mirror_dir / name)))
                selected[scope], stores[scope] = prepare_download(stage, scope, conf, package_list(inputs / f'{scope}.txt'))
                # Restore portable provenance; the saved databases and packages are authoritative.
                conf.write_bytes((ROOT / 'config/pacman-v3.conf').read_bytes() if scope == 'target'
                                 else upstream_file('archiso/pacman.conf'))
        store = stage / 'packages'
        store.mkdir()
        for scope in ('target', 'live'):
            for filename in selected[scope]:
                for suffix in ('', '.sig'):
                    source = stores[scope] / (filename + suffix)
                    target = store / source.name
                    if target.exists():
                        if sha(target) != sha(source):
                            raise ValueError(f'同名文件内容不同: {source.name}')
                    else:
                        copy(source, target)
        info = package_info(sorted(store.glob('*.pkg.tar.zst')))
        for scope in ('target', 'live'):
            build_repo(stage / f'{scope}-repo', selected[scope], store, info, package_list(inputs / f'{scope}.txt'))
        for download in stage.glob('download-*'):
            shutil.rmtree(download)
        lock = {'schema': 1, 'release': release, 'upstream_commit': UPSTREAM,
                'source_date_epoch': int(time.time()), 'imported_existing': import_current,
                'packages': selected, 'info': info,
                'tools': {'packages': capture(['pacman', '-Q', 'pacman', 'archiso']).strip(),
                          'mkarchiso_sha256': sha('/usr/bin/mkarchiso')},
                'sha256': {str(p.relative_to(stage)): sha(p) for p in sorted(stage.rglob('*'))
                           if p.is_file() and not p.is_symlink()}}
        stage.rename(destination)
        metadata.parent.mkdir(exist_ok=True)
        metadata.write_text(json.dumps(lock, ensure_ascii=False, indent=2) + '\n')
        (ROOT / 'config/release').write_text(release + '\n')
        print(f'==> 已冻结发布快照 {release}；原始 Live 数据库不可恢复时以导入的 pkglist 和新本地数据库为准。'
              if import_current else f'==> 已冻结发布快照 {release}')
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def publish_repo():
    _, snapshot, _ = verify()
    link = ROOT / 'repo'
    # Migrate the old physical directory once, keeping a rollback copy.
    backup = None
    if link.exists() and not link.is_symlink():
        backup = ROOT / f'repo.legacy-{time.time_ns()}'
        link.rename(backup)
    temporary = ROOT / '.repo-link'
    try:
        temporary.unlink(missing_ok=True)
        temporary.symlink_to((snapshot / 'target-repo').relative_to(ROOT), target_is_directory=True)
        temporary.replace(link)
    except BaseException:
        if backup is not None:
            backup.rename(link)
        raise
    finally:
        temporary.unlink(missing_ok=True)
    print('==> repo 指向已校验的干净发布仓库；历史文件不会进入新数据库')


def checksums(directory):
    paths = [p for p in sorted(directory.rglob('*')) if p.is_file() and not p.is_symlink() and p.name != 'SHA256SUMS']
    (directory / 'SHA256SUMS').write_text(''.join(f'{sha(p)}  {p.relative_to(directory)}\n' for p in paths))


def bundle(verified=None):
    release, snapshot, lock = verified or verify()
    output = ROOT / 'output'
    output.mkdir(exist_ok=True)
    destination = output / f'CachyOS-Offline-{release}'
    stage = Path(tempfile.mkdtemp(prefix='.bundle-', dir=output))
    try:
        shutil.copytree(snapshot / 'target-repo', stage / 'offline-repo')
        installer = stage / 'offline-install'
        shutil.copytree(ROOT / 'installer', installer)
        copy(snapshot / 'inputs/target.txt', installer / 'packages.txt')
        (installer / 'target-versions.txt').write_text(''.join(
            f'{lock["info"][f]["name"]} {lock["info"][f]["version"]}\n' for f in lock['packages']['target']))
        copy(ROOT / 'releases' / f'{release}.json', stage / 'release-lock.json')
        (stage / 'README.txt').write_text(
            f'CachyOS offline bundle {release}\n'
            'Boot an official CachyOS Live ISO; extract this archive on a Linux filesystem with enough space.\n'
            'Do not run the installer from your daily system.\n'
            '先启动官方 CachyOS Live ISO，将离线包解压到空间足够的 Linux 文件系统。\n'
            'cd CachyOS-Offline-' + release + '\n'
            'sha256sum -c SHA256SUMS\n'
            'sudo bash offline-install/offline-install.sh\n'
            '安装目标：E5-2666 v3 / GT 1030 (Nouveau) / X99 / KDE。其它硬件、真实 Windows 双启动未实机验证。\n'
            '联网后：sudo cachyos-repo-mode online（禁用旧快照仓库并完整升级）\n')
        checksums(stage)
        if destination.exists():
            shutil.rmtree(destination)
        stage.rename(destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    archive = output / f'{destination.name}.tar'
    tmp_archive = archive.with_suffix('.tar.tmp')
    try:
        # Packages are already zstd-compressed; a plain tar avoids another costly compression pass.
        with tarfile.open(tmp_archive, 'w') as tar:
            tar.add(destination, arcname=destination.name)
        tmp_archive.replace(archive)
    finally:
        tmp_archive.unlink(missing_ok=True)
    archive.with_suffix('.tar.sha256').write_text(f'{sha(archive)}  {archive.name}\n')
    print(f'==> 独立离线包: {archive}')
    return destination


def live_package_list(lock):
    # mkarchiso checks boot requirements by exact package name, not pacman specs.
    # Versions are enforced by the single-version, hash-verified local repository
    # and by check_pkglist after the build.
    return ''.join(f'{lock["info"][f]["name"]}\n' for f in lock['packages']['live'])


def integrate():
    release, snapshot, lock = verify()
    payload = bundle((release, snapshot, lock))
    destination = ROOT / 'work/profile'
    destination.parent.mkdir(exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.profile-', dir=destination.parent))
    try:
        # Materialize the committed source, never copy a previously mutated upstream tree.
        archive = subprocess.check_output(['git', '-C', str(ROOT / 'CachyOS-Live-ISO'), 'archive', UPSTREAM, 'archiso'])
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(stage, filter='fully_trusted')  # trusted, pinned Git tree contains absolute rootfs symlinks
        profile = stage / 'archiso'
        airootfs = profile / 'airootfs'
        shutil.copytree(payload, airootfs / 'opt/cachyos-offline', symlinks=True)
        # Keep the existing desktop entry and command path working.
        for name, target in [('offline-install', 'cachyos-offline/offline-install'), ('offline-repo', 'cachyos-offline/offline-repo')]:
            (airootfs / 'opt' / name).symlink_to(target)
        install_dir = airootfs / 'opt/cachyos-offline/offline-install'
        for path in ('usr/share/applications', 'etc/skel/Desktop', 'etc/pacman.d/hooks'):
            (airootfs / path).mkdir(parents=True, exist_ok=True)
        copy(install_dir / 'cachyos-offline-installer.desktop', airootfs / 'usr/share/applications/cachyos-offline-installer.desktop')
        copy(install_dir / 'cachyos-offline-installer.desktop', airootfs / 'etc/skel/Desktop/cachyos-offline-installer.desktop')
        copy(install_dir / 'no-hello-autostart.hook', airootfs / 'etc/pacman.d/hooks/zz-offline-no-hello-autostart.hook')
        # The old wrapper patched the host mkarchiso to remove this live-only timer.
        timer = airootfs / 'etc/systemd/system/archlinux-keyring-wkd-sync.timer'
        timer.parent.mkdir(parents=True, exist_ok=True)
        timer.unlink(missing_ok=True)
        timer.symlink_to('/dev/null')
        for name in ('cachyos-rate-mirrors.timer',):
            (timer.parent / name).unlink(missing_ok=True)
            (timer.parent / name).symlink_to('/dev/null')
        display = timer.parent / 'display-manager.service'
        display.unlink(missing_ok=True)
        display.symlink_to('/usr/lib/systemd/system/plasmalogin.service')
        (airootfs / 'etc/environment').write_text('ZPOOL_VDEV_NAME_PATH=1\n')
        (airootfs / 'etc/version-tag').write_text(release + '\n')
        (airootfs / 'etc/edition-tag').write_text('desktop\n')
        for mirror in (snapshot / 'inputs/mirrors').iterdir():
            copy(mirror, airootfs / 'etc/pacman.d' / mirror.name)
        grub = profile / 'grub/grub.cfg'
        grub.write_text(re.sub(r'CACHYOS_VERSION="[^"]*"', f'CACHYOS_VERSION="{release}"', grub.read_text()))
        (profile / 'pacman.conf').write_text(local_conf(snapshot / 'live-repo'))
        (profile / 'packages.x86_64').write_text(live_package_list(lock))
        p = profile / 'profiledef.sh'
        text = p.read_text().replace('file_permissions=(', 'file_permissions=(\n'
             '  ["/opt/cachyos-offline/offline-install/offline-install.sh"]="0:0:755"\n'
             '  ["/etc/skel/Desktop/cachyos-offline-installer.desktop"]="0:0:755"')
        p.write_text(text)
        if destination.exists():
            shutil.rmtree(destination)
        profile.rename(destination)
    finally:
        shutil.rmtree(stage)
    print(f'==> ISO profile: {destination}（只使用锁定 Live 仓库）')


def check_pkglist(path):
    _, _, lock = load()
    expected = {lock['info'][f]['name']: lock['info'][f]['version'] for f in lock['packages']['live']}
    actual = dict(line.split() for line in Path(path).read_text().splitlines())
    if actual != expected:
        raise ValueError('ISO Live 包版本与发布锁不一致')
    print('==> ISO Live 包版本与发布锁完全一致')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('freeze', 'verify', 'repository', 'bundle', 'integrate', 'check-pkglist'))
    parser.add_argument('value', nargs='?')
    parser.add_argument('--import-current', action='store_true', help='首次迁移：冻结现有 repo、缓存和已构建 Live pkglist')
    args = parser.parse_args()
    if args.action == 'freeze':
        if not args.value:
            parser.error('freeze 需要新的发布编号')
        freeze(args.value, args.import_current)
    elif args.action == 'verify':
        verify(args.value)
    elif args.action == 'repository':
        publish_repo()
    elif args.action == 'bundle':
        bundle()
    elif args.action == 'integrate':
        integrate()
    else:
        if not args.value:
            parser.error('check-pkglist 需要 pkglist 文件')
        check_pkglist(args.value)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        sys.exit(f'错误: {error}')
