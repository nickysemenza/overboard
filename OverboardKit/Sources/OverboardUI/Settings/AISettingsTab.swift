import Defaults
import OverboardCore
import SwiftUI

struct AISettingsTab: View {
    @Default(.aiFeatures) private var aiFeatures

    var body: some View {
        Form {
            Section {
                Toggle("Apple Intelligence titles, categories & transforms", isOn: self.$aiFeatures)
                    .disabled(!ClipEnricher.isAvailable)
            } footer: {
                Text(ClipEnricher.isAvailable
                    ? """
                    Clips get short titles, category badges, and one-line summaries, and the \
                    card menu gains AI transforms (summarize, fix grammar, …). Everything runs \
                    on-device — nothing leaves this Mac.
                    """
                    : "Requires Apple Silicon with Apple Intelligence enabled. Image OCR works regardless.")
            }

            Section {
                LabeledContent("Image OCR", value: "Always on")
            } footer: {
                Text(
                    """
                    Copied images and screenshots are text-recognized on-device so you can search \
                    them by their contents.
                    """
                )
            }
        }
        .formStyle(.grouped)
    }
}

#if DEBUG
    #Preview("AI") {
        AISettingsTab()
            .frame(width: 600, height: 500)
    }
#endif
