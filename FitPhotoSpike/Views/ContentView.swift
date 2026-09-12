import SwiftUI

struct ContentView: View {
    @Environment(\.openURL) private var openURL
    @State private var couldNotOpenShortcuts = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Fit Photos")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)

            Text("Use Fit Photos to 4:5 from the Shortcuts app.")
                .font(.body)
                .multilineTextAlignment(.center)

            Button("Open Shortcuts") {
                if let url = URL(string: "shortcuts://") {
                    openURL(url) { accepted in
                        couldNotOpenShortcuts = !accepted
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Unable to open Shortcuts", isPresented: $couldNotOpenShortcuts) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Install or open Apple's Shortcuts app, then add the Fit Photos to 4:5 action.")
        }
    }
}
