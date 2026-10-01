import Defaults
import OverboardMac
@testable import OverboardUI
import Testing

@Suite(.serialized)
@MainActor
struct TypedSettingsCoordinatorTests {
    @Test func presentationQueuesTheLatestTabAndDrainsOnce() {
        let coordinator = TypedSettingsCoordinator()
        var shown: [SettingsTab] = []
        coordinator.show(tab: .files)
        coordinator.show(tab: .permissions)
        #expect(coordinator.navigation.selectedTab == .permissions)
        #expect(coordinator.pendingTab == .permissions)
        coordinator.installPresentation { shown.append(coordinator.navigation.selectedTab) }
        #expect(shown == [.permissions])
        #expect(coordinator.pendingTab == nil)
        coordinator.installPresentation { shown.append(coordinator.navigation.selectedTab) }
        #expect(shown == [.permissions])
        coordinator.navigate(to: .history)
        #expect(shown == [.permissions])
        coordinator.show(tab: .actions)
        #expect(shown == [.permissions, .actions])
    }

    @Test func appliesConfigurationBeforeNotifyingOwner() {
        let priorRoots = Defaults[.fileSearchRoots]
        let priorExclusions = Defaults[.fileSearchExclusions]
        let priorRootsDraft = Defaults[.fileSearchRootsDraft]
        let priorExclusionsDraft = Defaults[.fileSearchExclusionsDraft]
        let priorUIRoots = Defaults[FileSearchDraftKeys.roots]
        let priorUIExclusions = Defaults[FileSearchDraftKeys.exclusions]
        defer {
            Defaults[.fileSearchRoots] = priorRoots
            Defaults[.fileSearchExclusions] = priorExclusions
            Defaults[.fileSearchRootsDraft] = priorRootsDraft
            Defaults[.fileSearchExclusionsDraft] = priorExclusionsDraft
            Defaults[FileSearchDraftKeys.roots] = priorUIRoots
            Defaults[FileSearchDraftKeys.exclusions] = priorUIExclusions
        }
        Defaults[FileSearchDraftKeys.roots] = ""
        Defaults[FileSearchDraftKeys.exclusions] = "invalid/path"
        let configuration = FileSearchConfiguration(roots: ["~/Documents"], exclusions: "node_modules")
        var notifications: [FileSearchConfiguration] = []
        let coordinator = TypedSettingsCoordinator { changed in
            #expect(Defaults[.fileSearchRoots] == changed.roots)
            #expect(Defaults[.fileSearchExclusions] == changed.exclusions)
            notifications.append(changed)
        }
        coordinator.applyFileSearchConfiguration(configuration)
        #expect(notifications == [configuration])
        #expect(Defaults[FileSearchDraftKeys.roots] == nil)
        #expect(Defaults[FileSearchDraftKeys.exclusions] == nil)
    }

    @Test func fileDraftValidationAndRetentionCopyAreExplicit() {
        #expect(FileSearchConfigurationValidation.issues(
            rootsText: "/Users/demo\n~/Documents\n", exclusions: "node_modules\n/tmp"
        ).isEmpty)
        #expect(FileSearchConfigurationValidation.issues(rootsText: "Documents", exclusions: "other/path").count == 2)
        #expect(ClearHistoryPrompt.message.contains("Pinned items and detected secrets are kept"))
    }
}
