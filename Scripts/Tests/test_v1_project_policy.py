"""Synthetic V1 privilege-boundary regressions; no Photos, network, or signing."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_project import check_source_policy


SAVER = 'Platform/PhotoLibrarySaver.swift'


def synthetic_project():
    return {
        SAVER: '''import Photos
func saveOnlyAfterUserTap() async {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    try await PHPhotoLibrary.shared().performChanges {
        for output in outputs {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: output, options: nil)
        }
    }
}
''',
        'Platform/OrderedPhotoPicker.swift': 'import PhotosUI\nlet picker = PHPickerConfiguration()',
    }, {'NSPhotoLibraryAddUsageDescription': 'Add only when Save All is tapped.'}


class V1SourcePolicyTests(unittest.TestCase):
    def test_native_picker_and_explicit_add_only_saver_are_allowed(self):
        check_source_policy(*synthetic_project())

    def test_full_library_usage_description_is_rejected(self):
        sources, info = synthetic_project()
        info['NSPhotoLibraryUsageDescription'] = 'Synthetic permission escalation'
        with self.assertRaisesRegex(AssertionError, 'FULL_LIBRARY_PERMISSION'):
            check_source_policy(sources, info)

    def test_missing_or_empty_add_only_description_is_rejected(self):
        for info in ({}, {'NSPhotoLibraryAddUsageDescription': ''},
                     {'NSPhotoLibraryAddUsageDescription': 1}):
            with self.subTest(info=info):
                with self.assertRaisesRegex(AssertionError, 'ADD_ONLY_DESCRIPTION'):
                    check_source_policy(synthetic_project()[0], info)

    def test_photokit_is_restricted_to_the_explicit_saver(self):
        for escalation in ('import Photos', 'PHPhotoLibrary.shared()',
                           'PHAssetCreationRequest.forAsset()', 'PHAuthorizationStatus.authorized'):
            sources, info = synthetic_project()
            sources['Views/Synthetic.swift'] = escalation
            with self.subTest(escalation=escalation):
                with self.assertRaisesRegex(AssertionError, 'SAVE_OUTSIDE_EXPLICIT_SAVER'):
                    check_source_policy(sources, info)

    def test_full_read_authorization_or_legacy_authorization_is_rejected(self):
        for replacement in ('requestAuthorization(for: .readWrite)', 'requestAuthorization()'):
            sources, info = synthetic_project()
            sources[SAVER] = sources[SAVER].replace('requestAuthorization(for: .addOnly)', replacement)
            with self.subTest(replacement=replacement):
                with self.assertRaises(AssertionError):
                    check_source_policy(sources, info)

    def test_existing_asset_access_and_mutation_are_rejected_even_in_saver(self):
        for escalation in ('PHAsset.fetchAssets()', 'PHAssetResource.assetResources()',
                           'PHAssetChangeRequest(for: original)', 'deleteAssets(originals)',
                           'PHAssetCreationRequest.forAsset()', 'PHImageManager.default()'):
            sources, info = synthetic_project()
            sources[SAVER] += '\n' + escalation
            with self.subTest(escalation=escalation):
                with self.assertRaises(AssertionError):
                    check_source_policy(sources, info)

    def test_only_the_new_photo_file_resource_path_is_allowed(self):
        for previous, replacement in (
            ('with: .photo', 'with: .video'),
            ('fileURL: output', 'data: payload'),
            ('options: nil', 'options: resourceOptions'),
            ('request.addResource', 'otherRequest.addResource'),
            ('PHAssetCreationRequest.forAsset()', 'PHAssetCreationRequest()'),
        ):
            sources, info = synthetic_project()
            sources[SAVER] = sources[SAVER].replace(previous, replacement)
            with self.subTest(replacement=replacement):
                with self.assertRaisesRegex(AssertionError, 'NEW_ASSET_CREATION_ONLY'):
                    check_source_policy(sources, info)

    def test_unapproved_photokit_types_are_rejected(self):
        for escalation in ('PHCollectionList.fetchCollectionLists()',
                           'PHLivePhoto.request()', 'PHCloudIdentifier()'):
            sources, info = synthetic_project()
            sources[SAVER] += '\n' + escalation
            with self.subTest(escalation=escalation):
                with self.assertRaisesRegex(AssertionError, 'UNAPPROVED_PHOTOKIT_API'):
                    check_source_policy(sources, info)

    def test_extra_save_transaction_is_rejected(self):
        sources, info = synthetic_project()
        sources[SAVER] += '\nPHPhotoLibrary.shared().performChanges {}'
        with self.assertRaisesRegex(AssertionError, 'SINGLE_SAVE_TRANSACTION'):
            check_source_policy(sources, info)

    def test_network_apis_remain_rejected(self):
        for escalation in ('URLSession.shared', 'URLRequest(url: endpoint)', 'NWConnection()',
                           'import Network', 'import CFNetwork'):
            sources, info = synthetic_project()
            sources['Views/Synthetic.swift'] = escalation
            with self.subTest(escalation=escalation):
                with self.assertRaisesRegex(AssertionError, 'PROHIBITED_SOURCE_API'):
                    check_source_policy(sources, info)



if __name__ == '__main__':
    unittest.main()
