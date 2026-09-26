"""Minimal synthetic app bundles; no Apple tools, credentials, or real binaries."""

import contextlib
import io
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import testflight_release as release
from verify_device_app import ARM64, LC_BUILD_VERSION, VerificationError, verify_app


class StandaloneDeviceVerificationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.app = Path(temporary.name) / "FitPhotoSpike.app"
        self.app.mkdir()
        self.settings = {
            "PRODUCT_BUNDLE_IDENTIFIER": "org.synthetic.fixture",
            "MARKETING_VERSION": "0.1.0",
        }
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": self.settings["PRODUCT_BUNDLE_IDENTIFIER"],
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1.1.0",
            "CFBundleSupportedPlatforms": ["iPhoneOS"], "DTPlatformName": "iphoneos",
            "CFBundleExecutable": "FitPhotoSpike", "CFBundlePackageType": "APPL",
            "UIDeviceFamily": [1],
        }))
        self.write_binary()

    def write_binary(self, cpu=ARM64, platform=2):
        # Header + one LC_BUILD_VERSION command; this is not runnable code.
        header = struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0)
        build = struct.pack("<6I", LC_BUILD_VERSION, 24, platform, 18 << 16, 26 << 16, 0)
        (self.app / "FitPhotoSpike").write_bytes(header + build)

    def test_minimal_standalone_bundle_passes_device_inspection(self):
        self.assertEqual({path.name for path in self.app.iterdir()},
                         {"Info.plist", "FitPhotoSpike"})
        report = verify_app(self.app)
        self.assertEqual(report["verification"], "passed")
        self.assertEqual(report["macho_slices"][0]["architecture"], "arm64")
        self.assertEqual(report["macho_slices"][0]["platform"], "iOS")
        self.assertEqual(report["physical_device_testing"], "not_run")

    def test_arm64_simulator_binary_remains_rejected(self):
        self.write_binary(platform=7)
        with self.assertRaisesRegex(VerificationError, "not iOS device"):
            verify_app(self.app)

    def test_non_arm64_binary_remains_rejected(self):
        self.write_binary(cpu=0x01000007)
        with self.assertRaisesRegex(VerificationError, "arm64 is required"):
            verify_app(self.app)

    def test_unsigned_artifact_still_rejects_signature_directory(self):
        (self.app / "_CodeSignature").mkdir()
        with self.assertRaisesRegex(VerificationError, "Unexpected code-signature"):
            verify_app(self.app)

    def test_minimal_bundle_still_requires_signature_verification_for_release(self):
        tool = Mock(work=self.app.parent)
        tool.run.side_effect = release.ReleaseError("CODE_SIGNATURE_INVALID")
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaisesRegex(release.ReleaseError, "^CODE_SIGNATURE_INVALID$"):
                release.verify_signed_app(tool, self.app, self.settings, "1.1.0",
                                          SimpleNamespace(), b"synthetic", "Archive")
        tool.run.assert_called_once_with("CODE_SIGNATURE_INVALID",
                                        ["codesign", "--verify", "--deep", "--strict", self.app])
        self.assertEqual(output.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
