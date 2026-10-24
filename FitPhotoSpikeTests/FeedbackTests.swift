import Foundation
import XCTest
@testable import FitPhotoSpike

/// Feedback links and the small settings remembered between launches.
final class FeedbackTests: XCTestCase {
    func testFeedbackEmailIsAddressedAndCarriesVersionDetails() throws {
        let url = try XCTUnwrap(FeedbackLinks.mailURL())
        XCTAssertEqual(url.scheme, "mailto")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, FeedbackLinks.email)
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["subject"], "Fit Photos feedback")
        XCTAssertTrue(items["body"]?.contains("iOS ") == true)
    }

    func testPreferencesRememberSizeBackgroundAndSaveCount() throws {
        let suite = "FitPhotosTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = EditorPreferences(defaults: defaults)
        XCTAssertEqual(preferences.ratio, .fourFive)
        XCTAssertEqual(preferences.background, .color(.white))
        XCTAssertEqual(preferences.successfulSaves, 0)
        preferences.ratio = .landscape
        preferences.background = .blur
        preferences.successfulSaves += 1
        let reloaded = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.ratio, .landscape)
        XCTAssertEqual(reloaded.background, .blur)
        XCTAssertEqual(reloaded.successfulSaves, 1)
    }
}
