import AppIntents
import Foundation
import UniformTypeIdentifiers

struct FitPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Fit Photos to 4:5"
    static let description = IntentDescription(
        "Fits 1–20 images into white 4:5 canvases without cropping. Returns temporary JPEG images for the next action, such as Share. Does not save to Photos."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Photos", supportedContentTypes: [.image])
    var photos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Fit \(\.$photos) to 4:5")
    }

    init() { }

    init(photos: [IntentFile]) {
        self.photos = photos
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let outputs = try await TemporaryImageProcessor().process(photos)
        return .result(value: outputs)
    }
}
