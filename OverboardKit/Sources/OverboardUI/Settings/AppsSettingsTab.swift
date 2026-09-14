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
                SettingsTextListEditor(
                    text: self.$autoTransformRules,
                    height: 72,
                    accessibilityLabel: "Transform rules, one bundle ID equals transform per line"
                )
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
            .frame(width: 520, height: 580)
    }
#endif
