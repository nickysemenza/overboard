import OverboardCore
import SwiftUI

extension Color {
    /// The single place a Core `KindTint` name becomes a drawable color, so the
    /// kind-identity ramp (DESIGN.md § Colors) has exactly one definition and
    /// `OverboardCore` stays free of SwiftUI.
    init(_ tint: KindTint) {
        switch tint {
        case .gray: self = .gray
        case .blue: self = .blue
        case .purple: self = .purple
        case .teal: self = .teal
        case .orange: self = .orange
        }
    }
}
