import Foundation

/// Fixed output choices for the standalone app. The existing Shortcut keeps
/// its source-dependent 4:5 sizing through ImageRenderer's original overload.
enum OutputRatio: String, CaseIterable, Identifiable, Sendable {
    case fourFive
    case threeFour
    case nineSixteen
    case square

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourFive: return "4:5"
        case .threeFour: return "3:4"
        case .nineSixteen: return "9:16"
        case .square: return "1:1"
        }
    }

    var label: String {
        switch self {
        case .fourFive: return "Portrait"
        case .threeFour: return "Classic portrait"
        case .nineSixteen: return "Tall portrait"
        case .square: return "Square"
        }
    }

    var width: Int { 1080 }

    var height: Int {
        switch self {
        case .fourFive: return 1350
        case .threeFour: return 1440
        case .nineSixteen: return 1920
        case .square: return 1080
        }
    }
}
