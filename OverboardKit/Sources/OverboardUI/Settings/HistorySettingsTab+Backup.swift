import AppKit
import OverboardCore
import OverboardMac
import SwiftUI

// MARK: - Backup

extension HistorySettingsTab {
    func exportHistory() {
        let warning = NSAlert()
        warning.messageText = String(localized: "Export an unencrypted library backup?")
        warning
            .informativeText =
            String(
                localized: """
                This folder contains readable clipboard payloads, pins, snippets, preferences, quicklinks, \
                aliases, shortcuts and learned ranking. It is not encrypted. Detected secrets are excluded \
                unless you explicitly include them. Store it somewhere private. \
                macOS permission grants are never exported.
                """
            )
        warning.addButton(withTitle: String(localized: "Export Without Detected Secrets"))
        warning.addButton(withTitle: String(localized: "Cancel"))
        warning.addButton(withTitle: String(localized: "Include Detected Secrets in Plaintext"))
        let response = warning.runModal()
        guard response != .alertSecondButtonReturn else { return }
        let includeSecrets = response == .alertThirdButtonReturn
        // AppKit panels rather than `.fileExporter`: the archive is a folder we
        // write ourselves (JSON + blob files), not a single document SwiftUI
        // can hand off.
        let panel = NSSavePanel()
        panel.title = String(localized: "Export History")
        panel.prompt = String(localized: "Export")
        panel.nameFieldStringValue = String(localized: "Overboard Export")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        self.isArchiving = true
        Task {
            defer { self.isArchiving = false }
            do {
                let summary = try await self.store.export(
                    to: url, includeSecrets: includeSecrets, settings: ArchivePreferencesAdapter.capture()
                )
                self.archiveOutcome = ArchiveOutcome(
                    title: String(localized: "Export Complete"),
                    message: Self.exportMessage(for: summary)
                )
            } catch {
                settingsLogger.error("library archive export failed")
                self.archiveOutcome = ArchiveOutcome(
                    title: String(localized: "Export Failed"), message: error.localizedDescription
                )
            }
        }
    }

    func importHistory() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import History")
        panel.prompt = String(localized: "Import")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let confirmation = NSAlert()
        confirmation.messageText = String(localized: "Import library and app settings?")
        confirmation
            .informativeText =
            String(
                localized: """
                Clips and snippets are merged without deleting existing content. Archived preferences, \
                quicklinks, aliases, shortcuts and learned ranking replace matching app settings. \
                Missing payloads can be repaired by importing a complete copy later. \
                macOS permissions are not restored.
                """
            )
        confirmation.addButton(withTitle: String(localized: "Import"))
        confirmation.addButton(withTitle: String(localized: "Cancel"))
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        self.isArchiving = true
        Task {
            defer { self.isArchiving = false }
            do {
                let summary = try await self.store.import(
                    from: url, validateSettings: ArchivePreferencesAdapter.validate
                )
                try ArchivePreferencesAdapter.apply(summary.settings)
                self.archiveOutcome = ArchiveOutcome(
                    title: String(localized: "Import Complete"),
                    message: Self.importMessage(for: summary)
                )
                await self.refresh()
            } catch {
                settingsLogger.error("library archive import failed")
                self.archiveOutcome = ArchiveOutcome(
                    title: String(localized: "Import Failed"),
                    // "Pick a folder written by Export History" is the whole
                    // point of the message; `localizedDescription` on a plain
                    // Swift error would flatten it to "The operation couldn't
                    // be completed."
                    message: (error as? ClipArchive.Failure)?.description ?? error.localizedDescription
                )
            }
        }
    }

    /// Builds the "Wrote N clips to Foo. …" summary for an export, noting any
    /// secrets or payloads left out so the backup never looks silently complete.
    private static func exportMessage(for summary: ExportSummary) -> String {
        var message = String(
            localized: """
            Wrote \(CountPhrase.string(summary.itemCount, of: String(localized: "clip"))) \
            to \(summary.directory.lastPathComponent).
            """
        )
        if summary.secretsExcluded > 0 {
            message += " " + String(
                localized: """
                \(CountPhrase.string(summary.secretsExcluded, of: String(localized: "detected secret"))) \
                excluded.
                """
            )
        }
        if summary.blobsMissing > 0 {
            message += " " + String(
                localized: """
                \(CountPhrase.string(summary.blobsMissing, of: String(localized: "attachment"))) could \
                not be copied.
                """
            )
        }
        message += " " + String(localized: "Included \(summary.snippetCount) snippets.")
        if summary
            .includesSettings
        {
            message += " " + String(localized: "App settings included; macOS permissions excluded.")
        }
        return message
    }

    /// Builds the "Added N clips. Skipped N duplicates. …" summary for an
    /// import. Damage is reported rather than hidden: an archive with bad
    /// lines or missing payloads still imported everything it could.
    private static func importMessage(for summary: ImportSummary) -> String {
        var parts = [
            String(
                localized: "Added \(CountPhrase.string(summary.imported, of: String(localized: "clip")))."
            ),
        ]
        if summary.duplicatesSkipped > 0 {
            parts.append(String(
                localized: """
                Skipped \(CountPhrase.string(summary.duplicatesSkipped, of: String(localized: "duplicate"))).
                """
            ))
        }
        if !summary.malformedLines.isEmpty {
            parts.append(String(
                localized: """
                Couldn’t read \
                \(CountPhrase.string(summary.malformedLines.count, of: String(localized: "line"))).
                """
            ))
        }
        if summary.missingBlobs > 0 {
            parts.append(String(
                localized: """
                \(CountPhrase.string(summary.missingBlobs, of: String(localized: "payload file"))) missing \
                from the archive.
                """
            ))
        }
        if summary.representationsRepaired > 0 {
            parts.append(String(localized: "Repaired \(summary.representationsRepaired) representations."))
        }
        if summary
            .snippetsImported > 0
        {
            parts.append(String(localized: "Added \(summary.snippetsImported) snippets."))
        }
        if summary
            .settings != nil
        {
            parts.append(String(localized: "App settings restored; macOS permissions unchanged."))
        }
        return parts.joined(separator: " ")
    }
}
