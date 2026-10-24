import Foundation
import SwiftUI
import UIKit

/// Ways to reach the developer with no server of our own: the user's email
/// app, an App Store review, or sharing the app's App Store page.
enum FeedbackLinks {
    static let email = "yesimilter@yahoo.com"

    /// The app's Apple ID from App Store Connect → App Information (digits
    /// only). Rating and sharing appear once it is set.
    static let appStoreID: String? = nil

    static var appStoreURL: URL? {
        appStoreID.flatMap { URL(string: "https://apps.apple.com/app/id\($0)") }
    }

    static var writeReviewURL: URL? {
        appStoreID.flatMap { URL(string: "https://apps.apple.com/app/id\($0)?action=write-review") }
    }

    /// For example "2.0 (12.1.0)".
    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// A new message to the developer. The version details sit below the
    /// space for the user's own words, so bug reports are easy to act on.
    static func mailURL() -> URL? {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let details = "Fit Photos \(versionText) · iOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion) · \(deviceModel)"
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Fit Photos feedback"),
            URLQueryItem(name: "body", value: "\n\n\n—\n" + details)
        ]
        return components.url
    }

    /// The hardware identifier, such as "iPhone16,2".
    private static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showsMailFallback = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Feedback")
                        .font(.fitDisplay(.title2))
                        .accessibilityAddTraits(.isHeader)
                    Text("An idea, a problem, or something you love? Send a quick note.")
                        .font(.body)
                        .foregroundStyle(Theme.inkQuiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 10) {
                    Button { writeEmail() } label: {
                        Label("Write an email", systemImage: "envelope")
                    }
                    .buttonStyle(InkButtonStyle())
                    if let review = FeedbackLinks.writeReviewURL {
                        Button { openURL(review) } label: {
                            Label("Rate on the App Store", systemImage: "star")
                        }
                        .buttonStyle(InkButtonStyle(prominent: false))
                    }
                    if let page = FeedbackLinks.appStoreURL {
                        ShareLink(item: page) {
                            Label("Share Fit Photos", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(InkButtonStyle(prominent: false))
                    }
                }
                Spacer(minLength: 0)
                Text("Version \(FeedbackLinks.versionText)")
                    .font(.fitMono(.caption))
                    .foregroundStyle(Theme.inkQuiet)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.table.ignoresSafeArea())
            .foregroundStyle(Theme.ink)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Email isn’t set up", isPresented: $showsMailFallback) {
                Button("Copy address") { UIPasteboard.general.string = FeedbackLinks.email }
                Button("OK", role: .cancel) { }
            } message: {
                Text("Write to \(FeedbackLinks.email) from any email app.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func writeEmail() {
        guard let url = FeedbackLinks.mailURL() else {
            showsMailFallback = true
            return
        }
        openURL(url) { accepted in
            if !accepted { showsMailFallback = true }
        }
    }
}
