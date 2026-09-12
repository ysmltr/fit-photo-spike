# Static source/project policy checks. Does not compile or run Swift.
from pathlib import Path
import json
import plistlib
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
project_path = root / 'FitPhotoSpike.xcodeproj' / 'project.pbxproj'
source = re.sub(r'//[^\n]*|/\*.*?\*/', '', project_path.read_text(), flags=re.S)
tokens = re.findall(r'"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', source)
index = 0

def pop(expected=None):
    global index
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
assert 'NSPhotoLibraryUsageDescription' not in plists[0]
assert 'NSPhotoLibraryAddUsageDescription' not in plists[0]
assert plists[1]['NSPrivacyTracking'] is False
assert plists[1]['NSPrivacyCollectedDataTypes'] == []
for xml in (root / 'FitPhotoSpike.xcodeproj').rglob('*'):
    if xml.suffix == '.xcscheme' or xml.name == 'contents.xcworkspacedata':
        tree = ET.parse(xml)
        for reference in tree.iter('BuildableReference'):
            assert reference.attrib['BlueprintIdentifier'] in objects

app_sources = '\n'.join(path.read_text() for path in (root / 'FitPhotoSpike').rglob('*.swift'))
for prohibited in ['import Photos', 'PHAsset', 'PHPhotoLibrary', 'UIImageWriteToSavedPhotosAlbum',
                   'creationRequestForAsset', 'deleteAssets(', 'URLSession', 'CryptoKit',
                   'TestPhotoAssetIdentityIntent', 'FitViewModel', 'FitAdjustment']:
    assert prohibited not in app_sources, prohibited
intent_sources = '\n'.join(path.read_text() for path in (root / 'FitPhotoSpike' / 'AppIntents').glob('*.swift'))
assert 'struct FitPhotosIntent: AppIntent' in intent_sources
assert '[IntentFile]' in intent_sources
assert 'Fit Photos to 4:5' in intent_sources
assert 'removedOnCompletion = true' in app_sources
assert 'CODE_SIGN_ENTITLEMENTS' not in project_path.read_text()
test_count = sum(len(re.findall(r'func test\w+\(', path.read_text()))
                 for path in (root / 'FitPhotoSpikeTests').glob('*.swift'))
result = {'project_objects': len(objects), 'swift_sources': source_counts,
          'xctest_methods_present_not_executed': test_count,
          'project_references': 'passed', 'xml_and_plists': 'passed',
          'source_policy_scan': 'passed', 'xcode_build': 'not_run',
          'native_tests': 'not_run', 'physical_iphone': 'not_run'}
print(json.dumps(result, indent=2))
