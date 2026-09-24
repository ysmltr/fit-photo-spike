import SwiftUI

struct PhotoPreview: View {
    let urls: [URL]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(urls: [URL], initialIndex: Int) {
        self.urls = urls
        _index = State(initialValue: initialIndex)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if urls.indices.contains(index) {
                    FileThumbnail(url: urls[index], maximumPixelSize: 1536)
                        .accessibilityLabel("Converted photo \(index + 1) of \(urls.count)")
                }
                ViewThatFits(in: .horizontal) {
                    controls
                    VStack(spacing: 8) {
                        Text("\(index + 1) of \(urls.count)").monospacedDigit()
                        HStack {
                            previous
                            Spacer()
                            next
                        }
                    }
                }
            }.padding(16)
                .navigationTitle("Preview").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var controls: some View {
        HStack {
            previous
            Spacer()
            Text("\(index + 1) of \(urls.count)").monospacedDigit()
            Spacer()
            next
        }
    }
    private var previous: some View {
        Button("Previous") { index -= 1 }.disabled(index == 0).frame(minHeight: 44)
    }
    private var next: some View {
        Button("Next") { index += 1 }.disabled(index + 1 >= urls.count).frame(minHeight: 44)
    }
}
