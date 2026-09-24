# Static source/project policy checks. Does not compile or run Swift.
from pathlib import Path
import json
import plistlib
import re
import xml.etree.ElementTree as ET


def check_source_policy(sources, info):
    """Static guardrails, not a substitute for compilation or a privacy audit."""
    saver_path = 'Platform/PhotoLibrarySaver.swift'
    assert 'NSPhotoLibraryUsageDescription' not in info, 'FULL_LIBRARY_PERMISSION'
    assert isinstance(info.get('NSPhotoLibraryAddUsageDescription'), str), 'ADD_ONLY_DESCRIPTION'
    assert info['NSPhotoLibraryAddUsageDescription'].strip(), 'ADD_ONLY_DESCRIPTION'
    assert saver_path in sources, 'EXPLICIT_SAVER_MISSING'

    prohibited = [
        r'\bURLSession\b', r'\bURLRequest\b', r'\bNWConnection\b',
        r'^\s*import\s+(?:Network|CFNetwork)\s*$',
        r'\bCryptoKit\b', r'\bTestPhotoAssetIdentityIntent\b',
        r'\bFitViewModel\b', r'\bFitAdjustment\b',
        r'\bPHAsset\b', r'\bPHAssetResource\w*\b', r'\bPHAssetCollection\w*\b',
        r'\bPHAssetChangeRequest\b',
        r'\bPHImageManager\b', r'\bPHCachingImageManager\b', r'\bPHFetchOptions\b',
        r'\bPHContentEditing\w*\b', r'\bPHAdjustmentData\b',
        r'\brequestContentEditingInput\b', r'\bdeleteAssets\s*\(',
        r'\bUIImageWriteToSavedPhotosAlbum\b', r'\.readWrite\b',
    ]
    # Ignore explanatory comments when checking identifiers, while retaining
    # literals so that a string containing a prohibited API remains fail-closed.
    code = {path: re.sub(r'//[^\n]*|/\*.*?\*/', '', source, flags=re.S)
            for path, source in sources.items()}
    picker_types = {'PHPickerConfiguration', 'PHPickerResult', 'PHPickerViewController',
                    'PHPickerViewControllerDelegate', 'PHPickerFilter'}
    saver_types = {'PHPhotoLibrary', 'PHAuthorizationStatus', 'PHPhotosError',
                   'PHAssetCreationRequest'}
    for relative_path, source in code.items():
        for pattern in prohibited:
            assert not re.search(pattern, source, re.M), 'PROHIBITED_SOURCE_API'
        imports_photos = re.search(r'^\s*import\s+Photos\s*$', source, re.M)
        photos_types = set(re.findall(r'\bPH[A-Z]\w*\b', source)) - picker_types
        if relative_path != saver_path:
            assert not imports_photos and not photos_types, 'SAVE_OUTSIDE_EXPLICIT_SAVER'
        else:
            assert photos_types <= saver_types, 'UNAPPROVED_PHOTOKIT_API'

    saver = code[saver_path]
    assert re.search(r'^\s*import\s+Photos\s*$', saver, re.M), 'SAVER_PHOTOS_IMPORT'
    request_calls = re.findall(r'\brequestAuthorization\s*\(', saver)
    add_only_calls = re.findall(r'\brequestAuthorization\s*\(\s*for:\s*\.addOnly\s*\)', saver)
    assert request_calls and len(request_calls) == len(add_only_calls), 'ADD_ONLY_AUTHORIZATION'
    # Permit only the exact new-photo resource path used by the batch saver.
    # Existing-asset change requests and other resource types remain forbidden.
    create_photo = (
        r'\blet\s+(\w+)\s*=\s*PHAssetCreationRequest\s*\.\s*forAsset\s*\(\s*\)\s*'
        r'\1\s*\.\s*addResource\s*\(\s*with:\s*\.photo\s*,\s*'
        r'fileURL:\s*\w+\s*,\s*options:\s*nil\s*\)'
    )
    assert len(re.findall(create_photo, saver)) == 1, 'NEW_ASSET_CREATION_ONLY'
    remaining = re.sub(create_photo, '', saver)
    assert not re.search(r'\bPHAssetCreationRequest\b|\baddResource\s*\(', remaining), \
        'NEW_ASSET_CREATION_ONLY'
    assert len(re.findall(r'\bperformChanges\s*\{', saver)) == 1, 'SINGLE_SAVE_TRANSACTION'

    intent = sources['AppIntents/FitPhotosIntent.swift']
    for required in [
        'struct FitPhotosIntent: AppIntent',
        'static let title: LocalizedStringResource = "Fit Photos to 4:5"',
        'static let openAppWhenRun = false',
        '@Parameter(title: "Photos", supportedContentTypes: [.image])',
        'var photos: [IntentFile]',
        'ReturnsValue<[IntentFile]>',
        'TemporaryImageProcessor().process(photos)',
        'return .result(value: outputs)',
    ]:
        assert required in intent, 'SHORTCUT_CONTRACT_CHANGED'
    assert 'PhotoLibrarySaver' not in intent, 'SHORTCUT_MUST_NOT_SAVE'
    assert 'removedOnCompletion = true' in '\n'.join(sources.values()), 'SHORTCUT_TEMPORARY_OUTPUT'


def main():
    root = Path(__file__).resolve().parents[1]
    project_path = root / 'FitPhotoSpike.xcodeproj' / 'project.pbxproj'
    source = re.sub(r'//[^\n]*|/\*.*?\*/', '', project_path.read_text(), flags=re.S)
    tokens = re.findall(r'"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', source)
    index = 0

    def pop(expected=None):
        nonlocal index
        value = tokens[index]
        index += 1
        if expected is not None:
            assert value == expected, (value, expected)
        return value

    def scalar():
        value = pop()
        return json.loads(value) if value.startswith('"') else value

    def parse():
        if tokens[index] == '{':
            pop('{')
            result = {}
            while tokens[index] != '}':
                key = scalar()
                pop('=')
                assert key not in result, key
                result[key] = parse()
                pop(';')
            pop('}')
            return result
        if tokens[index] == '(':
            pop('(')
            result = []
            while tokens[index] != ')':
                result.append(parse())
                if tokens[index] == ',':
                    pop(',')
            pop(')')
            return result
        return scalar()

    project = parse()
    assert index == len(tokens)
    objects = project['objects']
    project_object = objects[project['rootObject']]
    assert project_object['isa'] == 'PBXProject'

    def check_refs(value):
        if isinstance(value, dict):
            for nested in value.values():
                check_refs(nested)
        elif isinstance(value, list):
            for nested in value:
                check_refs(nested)
        elif re.fullmatch('[A-F0-9]{24}', str(value)):
            assert value in objects, value

    check_refs(project)
    resolved = {}

    def walk_group(object_id, parent):
        item = objects[object_id]
        if item.get('sourceTree') == 'BUILT_PRODUCTS_DIR':
            return
        path = parent / item.get('path', '')
        if item['isa'] == 'PBXGroup':
            for child in item['children']:
                walk_group(child, path)
        else:
            if item.get('lastKnownFileType') == 'folder.assetcatalog':
                assert path.is_dir() and (path / 'Contents.json').is_file(), path
            else:
                assert path.is_file(), path
            resolved[object_id] = path

    walk_group(project_object['mainGroup'], root)
    targets = [objects[ident] for ident in project_object['targets']]
    assert {target['name'] for target in targets} == {'FitPhotoSpike', 'FitPhotoSpikeTests'}
    source_counts = {}
    for target in targets:
        actual = []
        for phase_id in target['buildPhases']:
            phase = objects[phase_id]
            if phase['isa'] == 'PBXSourcesBuildPhase':
                actual.extend(resolved[objects[build_file]['fileRef']] for build_file in phase['files'])
        expected = set((root / target['name']).rglob('*.swift'))
        assert set(actual) == expected, (target['name'], set(actual) ^ expected)
        assert len(actual) == len(set(actual))
        source_counts[target['name']] = len(actual)

    plist_paths = [root / 'FitPhotoSpike' / 'App' / name for name in ['Info.plist', 'PrivacyInfo.xcprivacy']]
    plists = [plistlib.loads(path.read_bytes()) for path in plist_paths]
    assert plists[1]['NSPrivacyTracking'] is False
    assert plists[1]['NSPrivacyCollectedDataTypes'] == []
    for xml in (root / 'FitPhotoSpike.xcodeproj').rglob('*'):
        if xml.suffix == '.xcscheme' or xml.name == 'contents.xcworkspacedata':
            tree = ET.parse(xml)
            for reference in tree.iter('BuildableReference'):
                assert reference.attrib['BlueprintIdentifier'] in objects

    app_sources = {path.relative_to(root / 'FitPhotoSpike').as_posix(): path.read_text()
                   for path in (root / 'FitPhotoSpike').rglob('*.swift')}
    check_source_policy(app_sources, plists[0])
    assert 'CODE_SIGN_ENTITLEMENTS' not in project_path.read_text()
    test_count = sum(len(re.findall(r'func test\w+\(', path.read_text()))
                     for path in (root / 'FitPhotoSpikeTests').glob('*.swift'))
    result = {'project_objects': len(objects), 'swift_sources': source_counts,
              'xctest_methods_present_not_executed': test_count,
              'project_references': 'passed', 'xml_and_plists': 'passed',
              'source_policy_scan': 'passed', 'xcode_build': 'not_run',
              'native_tests': 'not_run', 'physical_iphone': 'not_run'}
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
