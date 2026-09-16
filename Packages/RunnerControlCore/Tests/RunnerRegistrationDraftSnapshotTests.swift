import Foundation
import Relux
import Testing
@testable import RunnerControlCore

// MARK: - Draft snapshot (Begin crash regression, no UI)

// The new-runner sheet crashed on Begin: the Relux `action { }` factory runs
// off-main, and it read MainActor-owned form state (`currentDraft`) across
// that boundary (dispatch actor-isolation trap, 2026-09-16). The container
// now snapshots through the pure `DraftSnapshot` builder on the MainActor
// and hands the `Sendable` value to the dispatcher. These tests pin the
// mapping and prove the production Begin entry point receives the exact
// clicked snapshot. Swift Testing runs off the main actor, so calling the
// builder here also proves it never touches actor-isolated state.

private func clickedOrgSnapshot() -> RunnerRegistration.Draft {
    RunnerRegistration.DraftSnapshot.make(
        organizationScope: true,
        org: "  relux-works ",
        repoOwner: "",
        repoName: "",
        runnerName: "\trc-smoke-260916 ",
        labelsText: "self-hosted, macOS, ARM64, rc-smoke",
        installDirName: " rc-smoke-260916 ",
        workFolder: " _work ",
        groupName: " rc-smoke-260916 ",
        selectedRepositoryIDs: [9],
        allowGroupMutation: true,
        allowGroupTakeover: false,
        allowReplace: false
    )
}

@Test func snapshotParseLabelsSplitsTrimsAndDropsEmpties() {
    #expect(
        RunnerRegistration.DraftSnapshot.parseLabels("self-hosted, macOS, ARM64, rc-smoke")
            == ["self-hosted", "macOS", "ARM64", "rc-smoke"]
    )
    #expect(RunnerRegistration.DraftSnapshot.parseLabels("  a ,\n,\tb ,, c  ") == ["a", "b", "c"])
}

@Test func snapshotParseLabelsBlankYieldsEmpty() {
    #expect(RunnerRegistration.DraftSnapshot.parseLabels("") == [])
    #expect(RunnerRegistration.DraftSnapshot.parseLabels(" , ,\n, ") == [])
}

@Test func snapshotMakeMapsOrganizationScopeAndTrimsEveryField() {
    #expect(clickedOrgSnapshot() == RunnerRegistration.Draft(
        scope: .organization(org: "relux-works"),
        runnerName: "rc-smoke-260916",
        labels: ["self-hosted", "macOS", "ARM64", "rc-smoke"],
        installDirName: "rc-smoke-260916",
        workFolder: "_work",
        groupName: "rc-smoke-260916",
        selectedRepositoryIDs: [9],
        allowGroupMutation: true,
        allowGroupTakeover: false,
        allowReplace: false
    ))
}

@Test func snapshotMakeMapsRepositoryScope() {
    let draft = RunnerRegistration.DraftSnapshot.make(
        organizationScope: false,
        org: "ignored",
        repoOwner: " octo ",
        repoName: " app ",
        runnerName: "personal-runner",
        labelsText: "self-hosted, macOS",
        installDirName: "personal-app",
        workFolder: "_work",
        groupName: "",
        selectedRepositoryIDs: [],
        allowGroupMutation: false,
        allowGroupTakeover: false,
        allowReplace: false
    )
    #expect(draft.scope == .repository(owner: "octo", name: "app"))
    #expect(draft.runnerName == "personal-runner")
    #expect(draft.labels == ["self-hosted", "macOS"])
}

@Test func beginDraftReceivesExactClickedSnapshot() async {
    let transport = TestTransport([])
    let harness = await registrationHarness(transport: transport)
    let snapshot = clickedOrgSnapshot()
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(snapshot))
    let began = registrationActions(harness.logger).compactMap { action -> RunnerRegistration.Draft? in
        if case .draftBegan(let draft) = action { draft } else { nil }
    }
    #expect(began.count == 1)
    #expect(began.first == snapshot)
    #expect(await transport.requests.isEmpty)
}

@Test func beginDraftRefusesBlankLabelsSnapshot() async {
    let transport = TestTransport([])
    let harness = await registrationHarness(transport: transport)
    let snapshot = RunnerRegistration.DraftSnapshot.make(
        organizationScope: true,
        org: "relux-works",
        repoOwner: "",
        repoName: "",
        runnerName: "rc-smoke-260916",
        labelsText: " , ,\n, ",
        installDirName: "rc-smoke-260916",
        workFolder: "_work",
        groupName: "rc-smoke-260916",
        selectedRepositoryIDs: [9],
        allowGroupMutation: true,
        allowGroupTakeover: false,
        allowReplace: false
    )
    #expect(snapshot.labels == [])
    _ = await harness.flow.apply(RunnerRegistration.Effect.beginDraft(snapshot))
    let failure = lastFailure(harness.logger)
    #expect(failure?.step == "beginDraft")
    #expect(failure?.message == "At least one label is required.")
    #expect(await transport.requests.isEmpty)
}

// MARK: - Production dispatch boundary (review F1)

private func distinctFlagSnapshot() -> RunnerRegistration.Draft {
    RunnerRegistration.DraftSnapshot.make(
        organizationScope: true,
        org: "relux-works",
        repoOwner: "",
        repoName: "",
        runnerName: "rc-smoke-260916",
        labelsText: "self-hosted, macOS, ARM64, rc-smoke",
        installDirName: "rc-smoke-260916",
        workFolder: "_work",
        groupName: "rc-smoke-260916",
        selectedRepositoryIDs: [7, 9],
        allowGroupMutation: true,
        allowGroupTakeover: true,
        allowReplace: true
    )
}

@MainActor @Test func dispatchBeginDraftThroughProductionDispatcherCarriesExactSnapshot() async {
    // Mirrors the fixed container call context (MainActor caller, eager
    // snapshot) and drives the production `Dispatcher.action { }` factory
    // path: the factory executes on the Dispatcher actor off-main — the
    // exact frame that trapped on Begin (Relux+Dispatcher+Interface
    // `_actions`). The dispatched effect must carry the exact snapshot.
    let snapshot = distinctFlagSnapshot()
    let logger = Relux.Testing.Logger()
    let dispatcher = Relux.Dispatcher(logger: logger)
    _ = await dispatcher.action { RunnerRegistration.Effect.beginDraft(snapshot) }
    let dispatched = logger.effects.compactMap { $0 as? RunnerRegistration.Effect }
    let carried = dispatched.compactMap { effect -> RunnerRegistration.Draft? in
        if case .beginDraft(let draft) = effect { draft } else { nil }
    }
    #expect(carried.count == 1)
    #expect(carried.first == snapshot)
}

@Test func snapshotMakeCapturesEveryFlagAndSelection() {
    // Omitted-capture negative: every UI flag and the repository selection
    // must survive the snapshot — a builder that hardcodes or drops any one
    // of them fails here.
    let draft = distinctFlagSnapshot()
    #expect(draft.allowGroupMutation == true)
    #expect(draft.allowGroupTakeover == true)
    #expect(draft.allowReplace == true)
    #expect(draft.selectedRepositoryIDs == [7, 9])
}

// MARK: - Production capture boundary (review F1, repeat-of revision 1)

// MainActor-owned mutable form fixture mirroring the container's
// MainActor-owned @State fields and `currentDraft` getter: the getter builds
// the draft through the same pure `DraftSnapshot.make` mapping and records
// every invocation, so the test observes capture timing, not just values.
@MainActor
final class BeginClickForm {
    var organizationScope = true
    var org = "  relux-works "
    var repoOwner = ""
    var repoName = ""
    var runnerName = "\trc-smoke-260916 "
    var labelsText = "self-hosted, macOS, ARM64, rc-smoke"
    var installDirName = " rc-smoke-260916 "
    var workFolder = " _work "
    var groupName = " rc-smoke-260916 "
    var selectedRepositoryIDs: Set<Int64> = [9]
    var allowGroupMutation = true
    var allowGroupTakeover = false
    var allowReplace = false
    private(set) var reads = 0
    private(set) var lastBuilt: RunnerRegistration.Draft?

    func currentDraft() -> RunnerRegistration.Draft {
        reads += 1
        let draft = RunnerRegistration.DraftSnapshot.make(
            organizationScope: organizationScope,
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
        lastBuilt = draft
        return draft
    }

    /// Simulates the user (or any post-click race) editing every field after
    /// the click but before the queued dispatcher factory runs.
    func mutateAfterClick() {
        organizationScope = false
        org = "mutated-org"
        repoOwner = "mutated-owner"
        repoName = "mutated-repo"
        runnerName = "mutated-after-click"
        labelsText = "mutated"
        installDirName = "mutated-dir"
        workFolder = "mutated-work"
        groupName = "mutated-group"
        selectedRepositoryIDs = [42]
        allowGroupMutation = false
        allowGroupTakeover = true
        allowReplace = true
    }
}

@MainActor @Test func beginDraftCaptureFactoryRetainsExactClickedSnapshotAcrossDispatch() async {
    // Calls the SAME production capture factory the container's beginDraft
    // reaction calls, with a getter reading MainActor-owned mutable form
    // state. Mutates the form after factory creation but before the queued
    // factory runs on the real Relux dispatcher: the dispatched beginDraft
    // must equal the exact clicked values, and the getter must have run
    // synchronously at click time — never again at dispatch.
    let form = BeginClickForm()
    let makeAction = RunnerRegistration.BeginDraftCapture.makeBeginDraftAction(readDraft: { form.currentDraft() })
    #expect(form.reads == 1)
    guard let expected = form.lastBuilt else {
        Issue.record("capture factory did not invoke the form getter synchronously at click time")
        return
    }
    form.mutateAfterClick()
    let logger = Relux.Testing.Logger()
    let dispatcher = Relux.Dispatcher(logger: logger)
    _ = await dispatcher.action(action: makeAction)
    let dispatched = logger.effects.compactMap { $0 as? RunnerRegistration.Effect }
    let carried = dispatched.compactMap { effect -> RunnerRegistration.Draft? in
        if case .beginDraft(let draft) = effect { draft } else { nil }
    }
    #expect(carried.count == 1)
    #expect(carried.first == expected)
    #expect(form.reads == 1)
}
