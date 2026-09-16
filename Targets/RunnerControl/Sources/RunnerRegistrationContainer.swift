import SwiftUI
import RunnerControlCore

/// Wizard composition root. Edits local draft fields, dispatches production
/// `RunnerRegistration.Effect`s, and never holds tokens.
struct RunnerRegistrationContainer: View {
    @ObservedObject var registration: RunnerRegistration.State
    @ObservedObject var github: GitHubAuth.State
    let close: () -> Void

    @State private var scopeKind: RunnerRegistrationPage.ScopeKind = .organization
    @State private var org = ""
    @State private var repoOwner = ""
    @State private var repoName = ""
    @State private var runnerName = Host.current().localizedName ?? ""
    @State private var labelsText = "self-hosted, macOS"
    @State private var installDirName = ""
    @State private var workFolder = "_work"
    @State private var groupName = RunnerRegistration.Draft.defaultGroupName(
        hostName: Host.current().localizedName ?? ""
    )
    @State private var allowGroupMutation = false
    @State private var allowGroupTakeover = false
    @State private var allowReplace = false
    @State private var selectedRepositoryIDs: Set<Int64> = []
    @State private var seeded = false

    /// Snapshots MainActor-owned form state through the pure Core builder.
    /// Callers must capture this value on the MainActor before crossing the
    /// Relux dispatcher boundary; the `action { }` factory runs off-main.
    private var currentDraft: RunnerRegistration.Draft {
        RunnerRegistration.DraftSnapshot.make(
            organizationScope: scopeKind == .organization,
            org: org,
            repoOwner: repoOwner,
            repoName: repoName,
            runnerName: runnerName,
            labelsText: labelsText,
            installDirName: installDirName,
            workFolder: workFolder,
            groupName: groupName,
            selectedRepositoryIDs: selectedRepositoryIDs,
            allowGroupMutation: allowGroupMutation,
            allowGroupTakeover: allowGroupTakeover,
            allowReplace: allowReplace
        )
    }

    var body: some View {
        RunnerRegistrationPage(
            props: .init(
                phase: registration.phase,
                working: registration.working,
                scopeKind: scopeKind,
                org: org,
                repoOwner: repoOwner,
                repoName: repoName,
                runnerName: runnerName,
                labelsText: labelsText,
                installDirName: installDirName,
                workFolder: workFolder,
                groupName: groupName,
                allowGroupMutation: allowGroupMutation,
                allowGroupTakeover: allowGroupTakeover,
                allowReplace: allowReplace,
                selectedRepositoryIDs: selectedRepositoryIDs,
                repositories: github.repositories,
                installations: github.installations,
                githubConnected: isConnected,
                githubUsername: github.username,
                group: registration.group,
                groupRepositoryIDs: registration.groupRepositoryIDs,
                assetFilename: registration.asset?.filename,
                installPath: registration.installPath,
                runnerID: registration.runnerID,
                localAgentID: registration.localAgentID,
                completedSteps: registration.completedSteps,
                error: registration.error,
                failedStep: registration.failedStep,
                permissionError: registration.permissionError
            ),
            reactions: .init(
                scopeKindChanged: { scopeKind = $0; pushDraft() },
                orgChanged: { org = $0; pushDraft() },
                repoOwnerChanged: { repoOwner = $0; pushDraft() },
                repoNameChanged: { repoName = $0; pushDraft() },
                runnerNameChanged: { runnerName = $0; pushDraft() },
                labelsChanged: { labelsText = $0; pushDraft() },
                installDirChanged: { installDirName = $0; pushDraft() },
                workFolderChanged: { workFolder = $0; pushDraft() },
                groupNameChanged: { groupName = $0; pushDraft() },
                allowGroupMutationChanged: { allowGroupMutation = $0; pushDraft() },
                allowGroupTakeoverChanged: { allowGroupTakeover = $0; pushDraft() },
                allowReplaceChanged: { allowReplace = $0; pushDraft() },
                repositoriesChanged: { ids in
                    selectedRepositoryIDs = ids
                    Task { await action { GitHubAuth.Effect.selectRepositories(ids) } }
                    pushDraft()
                },
                beginDraft: {
                    // Capture the MainActor-owned snapshot synchronously at
                    // click time through the production capture boundary,
                    // before crossing the dispatcher boundary: the queued
                    // factory runs off-main and holds only the immutable
                    // draft (dispatch actor-isolation crash, Begin
                    // 2026-09-16).
                    let makeAction = RunnerRegistration.BeginDraftCapture.makeBeginDraftAction(
                        readDraft: { currentDraft }
                    )
                    Task { await action(action: makeAction) }
                },
                resolveGroup: { Task { await action { RunnerRegistration.Effect.resolveGroup } } },
                downloadAndInstall: { Task { await action { RunnerRegistration.Effect.downloadAndInstall } } },
                registerRunner: { Task { await action { RunnerRegistration.Effect.registerRunner } } },
                setupService: { Task { await action { RunnerRegistration.Effect.setupService } } },
                applyRepositoryAccess: {
                    let target = registration.group?.id ?? -1
                    let effect = RunnerRegistration.Effect.applyRepositoryAccess(
                        groupID: target, repositories: selectedRepositoryIDs
                    )
                    Task { await action { effect } }
                },
                applyLabels: {
                    let labels = RunnerRegistration.DraftSnapshot.parseLabels(labelsText)
                    Task { await action { RunnerRegistration.Effect.applyLabels(labels) } }
                },
                retry: { Task { await action { RunnerRegistration.Effect.retry } } },
                cancel: { Task { await action { RunnerRegistration.Effect.cancel } } },
                reset: { Task { await action { RunnerRegistration.Effect.reset } } },
                dismissPermission: { Task { await action { RunnerRegistration.Effect.dismissPermission } } },
                close: close
            )
        )
        .onAppear(perform: seedFromGitHub)
    }

    private var isConnected: Bool {
        if case .connected = github.connection { return true }
        return false
    }

    /// Pushes field edits into the draft once the wizard has begun, so step
    /// buttons always run the visible values. Before the first begin the
    /// draft does not exist yet and edits stay local.
    private func pushDraft() {
        guard registration.phase != .idle else { return }
        let draft = currentDraft
        Task { await action { RunnerRegistration.Effect.updateDraft(draft) } }
    }

    /// Seeds org/owner from the selected GitHub installation once.
    private func seedFromGitHub() {
        guard !seeded else { return }
        seeded = true
        if installDirName.isEmpty {
            installDirName = (Host.current().localizedName ?? "runner")
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
        }
        guard let id = github.selectedInstallationID,
              let installation = github.installations.first(where: { $0.id == id }) else { return }
        if org.isEmpty, installation.accountType == "Organization" {
            org = installation.account
            scopeKind = .organization
        } else if repoOwner.isEmpty {
            repoOwner = installation.account
            scopeKind = .repository
        }
        if selectedRepositoryIDs.isEmpty {
            selectedRepositoryIDs = github.selectedRepositoryIDs
        }
    }
}
