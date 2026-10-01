import Defaults
import Foundation
import Observation
import OverboardMac

public struct FileSearchConfiguration: Sendable, Equatable {
    public let roots: [String]
    public let exclusions: String

    public init(roots: [String], exclusions: String) {
        self.roots = roots
        self.exclusions = exclusions
    }
}

enum FileSearchDraftKeys {
    static let roots = Defaults.Key<String?>(
        "fileSearch.roots.uiDraft",
        default: nil,
        suite: AppPreferenceStorage.suite
    )
    static let exclusions = Defaults.Key<String?>(
        "fileSearch.exclusions.uiDraft",
        default: nil,
        suite: AppPreferenceStorage.suite
    )
}

nonisolated enum FileSearchConfigurationValidation {
    static func issues(rootsText: String, exclusions: String) -> [String] {
        let roots = rootsText.components(separatedBy: .newlines)
        let invalidRoots = roots.enumerated().compactMap { index, raw -> String? in
            let path = raw.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~/") else { return nil }
            return "Included folder line \(index + 1) must be an absolute path or start with ~/."
        }
        let exclusionsLines = exclusions.components(separatedBy: .newlines)
        let invalidExclusions = exclusionsLines.enumerated().compactMap { index, raw -> String? in
            let path = raw.trimmingCharacters(in: .whitespaces)
            guard path.contains("/"), !path.hasPrefix("/"), !path.hasPrefix("~/") else { return nil }
            return "Excluded folder line \(index + 1) must be a folder name or an absolute path."
        }
        return invalidRoots + invalidExclusions
    }
}

@Observable
public final class TypedSettingsCoordinator {
    public let navigation: SettingsNavigation
    public var onFileSearchConfigurationChanged: (FileSearchConfiguration) -> Void
    public private(set) var pendingTab: SettingsTab?
    @ObservationIgnored private var presentation: (() -> Void)?

    public init(
        navigation: SettingsNavigation = SettingsNavigation(),
        onFileSearchConfigurationChanged: @escaping (FileSearchConfiguration) -> Void = { _ in }
    ) {
        self.navigation = navigation
        self.onFileSearchConfigurationChanged = onFileSearchConfigurationChanged
    }

    public func navigate(to tab: SettingsTab) {
        self.navigation.selectedTab = tab
    }

    public func show(tab: SettingsTab = .general) {
        self.navigate(to: tab)
        guard let presentation else {
            self.pendingTab = tab
            return
        }
        self.pendingTab = nil
        presentation()
    }

    public func installPresentation(_ presentation: @escaping () -> Void) {
        self.presentation = presentation
        guard let pendingTab else { return }
        self.show(tab: pendingTab)
    }

    public func applyFileSearchConfiguration(_ configuration: FileSearchConfiguration) {
        Defaults[.fileSearchRoots] = configuration.roots
        Defaults[.fileSearchExclusions] = configuration.exclusions
        Defaults[.fileSearchRootsDraft] = ""
        Defaults[.fileSearchExclusionsDraft] = ""
        Defaults[FileSearchDraftKeys.roots] = nil
        Defaults[FileSearchDraftKeys.exclusions] = nil
        self.onFileSearchConfigurationChanged(configuration)
    }
}
