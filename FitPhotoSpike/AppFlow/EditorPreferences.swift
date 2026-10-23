import Foundation

/// Remembers the last size and background between launches. Only these two
/// small settings are stored on the device, never photos or file paths.
struct EditorPreferences {
    private static let ratioKey = "editor.lastRatio"
    private static let backgroundKey = "editor.lastBackground"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var ratio: OutputRatio {
        get { defaults.string(forKey: Self.ratioKey).flatMap(OutputRatio.init(rawValue:)) ?? .fourFive }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.ratioKey) }
    }

    var background: CanvasBackground {
        get {
            guard let data = defaults.data(forKey: Self.backgroundKey),
                  let value = try? JSONDecoder().decode(CanvasBackground.self, from: data) else {
                return .color(.white)
            }
            return value
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.backgroundKey)
        }
    }
}
