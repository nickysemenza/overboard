import Defaults
import OverboardCore
import SwiftUI

struct AppsSettingsTab: View {
    @Default(.excludedBundleIDs) private var excludedBundleIDs
    @Default(.plainTextBundleIDs) private var plainTextBundleIDs
    @Default(.autoTransformRules) private var autoTransformRules

    private var transformList: String {
        ClipTransform.allCases.map(\.rawValue).joined(separator: ", ")
    }

    var body: some View {
        Form {
            Section {
                AppListEditor(rawList: self.$excludedBundleIDs)
            } header: {
                Text("Never capture from")
            } footer: {
                Text(
                    """
                    Copies made in these apps never enter history. Apps that mark their pasteboard \
                    as concealed (most password managers) are skipped automatically.
                    """
                )
            }

            Section {
                AppListEditor(rawList: self.$plainTextBundleIDs)
            } header: {
                Text("Always paste as plain text into")
            } footer: {
                Text("Pasting text into these apps (terminals, editors) strips formatting automatically.")
            }

            Section {
                TextEditor(text: self.$autoTransformRules)
                    .font(.body.monospaced())
                    .frame(height: 72)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            } header: {
                Text("Clean up copies from")
            } footer: {
                Text(
                    """
                    One “bundleID = transform” per line — e.g. “com.apple.Safari = \
                    stripTrackingParams” strips ?utm_… from every link you copy in Safari. \
                    Transforms run at capture time on the plain-text copy. Available: \
                    \(self.transformList).
                    """
                )
            }
        }
        .formStyle(.grouped)
    }
}

#if DEBUG
    #Preview("Apps") {
        AppsSettingsTab()
            .frame(width: 600, height: 500)
    }
#endif
