import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Icon and colour for each kind of collection. Colour is never the only cue:
/// every use pairs it with the symbol and the collection's text label.
public extension BinCollectionType {
    var symbolName: String {
        switch self {
        case .food: "carrot.fill"
        case .recycling: "arrow.3.trianglepath"
        case .paper: "newspaper.fill"
        case .refuse: "trash.fill"
        case .garden: "leaf.fill"
        case .other: "shippingbox.fill"
        }
    }

    var tint: Color {
        switch self {
        case .food: Color(red: 0.13, green: 0.60, blue: 0.40)
        case .recycling: Color(red: 0.10, green: 0.45, blue: 0.80)
        case .paper: Color(red: 0.85, green: 0.50, blue: 0.10)
        case .refuse: Color(red: 0.40, green: 0.42, blue: 0.45)
        case .garden: Color(red: 0.45, green: 0.55, blue: 0.15)
        case .other: Color(red: 0.55, green: 0.35, blue: 0.75)
        }
    }
}

public extension Color {
    /// Bromley Bins' green: the brand's dark green in light mode, lifted in dark
    /// mode so it stays readable on black.
    static let binsBrand: Color = {
        #if canImport(UIKit)
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.30, green: 0.75, blue: 0.50, alpha: 1)
                : UIColor(red: 0.0, green: 0.41, blue: 0.22, alpha: 1)
        })
        #else
        Color(red: 0.0, green: 0.41, blue: 0.22)
        #endif
    }()

    /// Card surface that stands out from the grouped background in both modes.
    static let binsCard: Color = {
        #if canImport(UIKit)
        Color(UIColor.secondarySystemGroupedBackground)
        #else
        Color.white
        #endif
    }()
}

/// The container a collection goes out in, drawn to match the pictures on
/// Bromley's bin collection pages so people recognise their bins at a glance.
/// Unknown collection types fall back to a tinted symbol badge.
public struct BinBadge: View {
    let type: BinCollectionType
    let size: CGFloat

    public init(_ type: BinCollectionType, size: CGFloat = 36) {
        self.type = type
        self.size = size
    }

    public var body: some View {
        Group {
            if type == .other {
                Image(systemName: type.symbolName)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(type.tint.gradient, in: Circle())
            } else {
                BinIllustration(type: type)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}
