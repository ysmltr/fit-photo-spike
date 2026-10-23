import CoreGraphics
import Foundation

/// Canvas presets, Instagram's own first. Raw values are stored as the last
/// used size, so existing ones must not change.
enum OutputRatio: String, CaseIterable, Identifiable, Sendable {
    case fourFive
    case square
    case landscape
    case nineSixteen
    case threeFour
    case twoThree
    case sixteenNine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourFive: return "4:5"
        case .square: return "1:1"
        case .landscape: return "1.91:1"
        case .nineSixteen: return "9:16"
        case .threeFour: return "3:4"
        case .twoThree: return "2:3"
        case .sixteenNine: return "16:9"
        }
    }

    var label: String {
        switch self {
        case .fourFive: return "Portrait"
        case .square: return "Square"
        case .landscape: return "Landscape"
        case .nineSixteen: return "Story · Reels"
        case .threeFour: return "Classic"
        case .twoThree: return "Pinterest"
        case .sixteenNine: return "Widescreen"
        }
    }

    /// Instagram's post and story sizes; the others appear under More sizes.
    var isInstagram: Bool {
        switch self {
        case .fourFive, .square, .landscape, .nineSixteen: return true
        case .threeFour, .twoThree, .sixteenNine: return false
        }
    }

    var width: Int { self == .sixteenNine ? 1920 : 1080 }

    var height: Int {
        switch self {
        case .fourFive: return 1350
        case .square: return 1080
        case .landscape: return 566
        case .nineSixteen: return 1920
        case .threeFour: return 1440
        case .twoThree: return 1620
        case .sixteenNine: return 1080
        }
    }

    var canvasSize: CGSize { CGSize(width: width, height: height) }
}
