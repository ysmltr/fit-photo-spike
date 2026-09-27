"""Check the IPA contains exactly the verified device app, without extracting it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import zipfile


def digest(stream):
    checksum = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        checksum.update(chunk)
    return checksum.hexdigest()


def verify_ipa(app, ipa, app_report):
    if app_report.get('verification') != 'passed':
        raise ValueError('Device app verification must pass before IPA verification.')
    if Path(app_report['app']).resolve() != app.resolve():
        raise ValueError('Device verification report belongs to a different app.')
    if app.name != 'FitPhotoSpike.app':
        raise ValueError('Expected the existing FitPhotoSpike.app product.')
    expected = {}
    prefix = 'Payload/FitPhotoSpike.app/'
    for path in app.rglob('*'):
        if path.is_symlink() or path.is_file():
            expected[prefix + path.relative_to(app).as_posix()] = path
    if not expected:
        raise ValueError('The device application is empty.')
    with zipfile.ZipFile(ipa) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if len(set(names)) != len(names):
            raise ValueError('Duplicate paths in IPA.')
        for entry in entries:
            if entry.filename not in {'Payload/', prefix} and not entry.filename.startswith(prefix):
                raise ValueError('IPA contains a path outside Payload/FitPhotoSpike.app.')
            if '..' in entry.filename.split('/') or '\\' in entry.filename:
                raise ValueError('Unsafe archive path.')
        actual = {entry.filename: entry for entry in entries if not entry.is_dir()}
        if set(actual) != set(expected):
            raise ValueError('Packaged file list differs from the verified device app.')
        for name, path in expected.items():
            entry = actual[name]
            mode = entry.external_attr >> 16
            if path.is_symlink():
                # Preserve an internal framework symlink as a link, not a copy
                # to an arbitrary path outside this bundle.
                if not path.resolve().is_relative_to(app.resolve()):
                    raise ValueError('Bundle symlink leaves the application.')
                if not stat.S_ISLNK(mode) or archive.read(entry) != os.readlink(path).encode('utf-8'):
                    raise ValueError('Symlink changed while packaging.')
            else:
                if not stat.S_ISREG(mode):
                    raise ValueError('Regular file lost its Unix file type in the IPA.')
                with path.open('rb') as original, archive.open(entry) as packaged:
                    if digest(original) != digest(packaged):
                        raise ValueError('Packaged bytes differ: ' + name)
        executable = actual[prefix + app_report['executable']]
        if not ((executable.external_attr >> 16) & stat.S_IXUSR):
            raise ValueError('IPA lost the executable permission bit.')
        if archive.testzip() is not None:
            raise ValueError('IPA CRC check failed.')
    with ipa.open('rb') as stream:
        ipa_hash = digest(stream)
    return {
        **app_report,
        'ipa_verification': 'passed',
        'ipa_filename': ipa.name,
        'ipa_sha256': ipa_hash,
        'packaged_file_count': len(expected),
        'layout': 'Payload/FitPhotoSpike.app',
        'all_packaged_bytes_match_verified_app': True,
        're_signing': 'not_run',
        'physical_device_testing': 'not_run',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--ipa', type=Path, required=True)
    parser.add_argument('--app-report', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify_ipa(args.app, args.ipa, json.loads(args.app_report.read_text()))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, RuntimeError) as error:
        print('IPA verification failed: ' + str(error))
        return 1
    args.report.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
