import SwiftUI

/// Marks protected clipboard content: a filled orange capsule with a white
/// lock glyph and label. DESIGN.md § Colors, "Secret badge" — the one place
/// the kind-identity ramp is a warning rather than a label, so it is filled
/// rather than tinted type, and it survives Increase Contrast unchanged.
/// A yellow glyph on glass was easy to miss on the one card where misreading
/// the content matters most; a filled capsule reads as a warning at any
/// contrast setting.
struct SecretBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
            Text("Secret")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(.orange, in: Capsule())
        .accessibilityHidden(true)
    }
}

#if DEBUG
    #Preview("Secret badge") {
        SecretBadge()
            .padding()
    }
#endif
