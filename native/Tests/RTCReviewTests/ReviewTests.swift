import Foundation
import RTCContracts
import RTCDomain
import RTCReview

private struct TestSource: AnchorArtifactSource {
    let valid: Bool
    func validate(_ anchor: ReviewAnchor) async throws -> Bool { valid }
}
private struct UnavailablePreflight: ReviewMutationPreflight {
    struct Failure: Error {}
    func currentHead(for revision: RevisionIdentity) async throws -> String { throw Failure() }
}
private actor StaticRepository: EventRepository {
    let stored: [ReviewEvent]
    init(_ stored: [ReviewEvent]) { self.stored=stored }
    func append(_ proposal: PendingReviewEvent, after expectedSequence: Int) async throws -> ReviewEvent { throw EventRepositoryError.reviewUnavailable }
    func events(after sequence: Int, reviewID: ReviewID) async throws -> [ReviewEvent] { stored.filter { $0.sequence > sequence } }
}

@main enum RTCReviewTests {
    static func main() async throws {
        let fixture=try Fixture()
        try await workflow(fixture)
        try await anchorAndPreflightGuards(fixture)
        try await terminalMatrix(fixture)
        try await corruptReplay(fixture)
        print("RTC review reducer and command checks passed")
    }

    private static func workflow(_ fixture: Fixture) async throws {
        let repository=MemoryReviewEventRepository()
        let handler=try await open(fixture, repository: repository)
        let operation=UUID()
        let threadID=try await handler.createDraft(anchor: fixture.anchor, body: fixture.body, promotedFrom: UUID(), messageID: UUID(), operationID: operation)
        precondition(threadID == operation)
        let draft=await handler.snapshot()
        precondition(draft.threads.first?.state == .draft && draft.cursor == 1)
        let changed=try RichText(runs: [RichTextRun(kind: .plain, text: "Changed operation contents")])
        do { _=try await handler.createDraft(anchor: fixture.anchor, body: changed, operationID: operation); preconditionFailure("changed idempotent operation succeeded") } catch { precondition(error as? EventRepositoryError == .idempotencyConflict) }
        let sent=try await handler.sendReview(threadIDs: [threadID])
        precondition(sent.kind == .feedback)
        _=try await handler.reply(threadID: threadID, body: fixture.body)
        _=try await handler.resolve(threadID: threadID)
        _=try await handler.reopen(threadID: threadID)
        _=try await handler.markViewed(path: fixture.artifact.path, expectedVersion: 0)
        let beforeRestart=await handler.snapshot()
        let restarted=try await open(fixture, repository: repository)
        let afterRestart=await restarted.snapshot()
        precondition(afterRestart == beforeRestart, "fresh handler must replay exact state")
        let approval=try await restarted.approveExactRevision()
        let approvedSnapshot=await restarted.snapshot()
        precondition(approval.kind == .approval && approvedSnapshot.status == .approved)
        let same=try await restarted.approveExactRevision(operationID: approval.id)
        precondition(same == approval, "same operation returns the canonical stored event")
        let events=try await repository.events(after: 0, reviewID: fixture.revision.reviewID)
        precondition(events.map(\.sequence) == Array(1...events.count))
        precondition(events.filter(ReviewDeliveryPolicy.isWorkerVisible).allSatisfy { $0.kind != .threadCreated && $0.kind != .fileProgressChanged })

        let changesRepo=MemoryReviewEventRepository()
        let changes=try await open(fixture, repository: changesRepo)
        let draftID=try await changes.createDraft(anchor: fixture.anchor, body: fixture.body)
        let summary=try RichText(runs: [RichTextRun(kind: .plain, text: "Needs the guarded branch.")])
        let event=try await changes.requestChanges(threadIDs: [draftID], summary: summary)
        precondition(event.sequence == 2)
        let restored=try await open(fixture, repository: changesRepo)
        let restoredSnapshot=await restored.snapshot()
        precondition(restoredSnapshot.status == .changesRequested && restoredSnapshot.threads.first?.state == .open && restoredSnapshot.requestChangesSummary == summary)
        let changeEvents=try await changesRepo.events(after: 0, reviewID: fixture.revision.reviewID)
        precondition(changeEvents.map(\.kind) == [.threadCreated, .changesRequested], "request changes is one atomic event")

        let closeRepo=MemoryReviewEventRepository(), closeHandler=try await open(fixture, repository: closeRepo)
        _=try await closeHandler.closeReview()
        let closed=try await open(fixture, repository: closeRepo)
        let closedSnapshot=await closed.snapshot()
        precondition(closedSnapshot.status == .closed)
    }

    private static func anchorAndPreflightGuards(_ fixture: Fixture) async throws {
        let invalidSource=try await ReviewCommandHandler.open(manifest: fixture.manifest, repository: MemoryReviewEventRepository(), anchors: TestSource(valid: false), mutationPreflight: FixedReviewMutationPreflight(headSHA: fixture.revision.headSHA))
        let id=try await invalidSource.createDraft(anchor: fixture.anchor, body: fixture.body)
        do { _=try await invalidSource.sendReview(threadIDs: [id]); preconditionFailure("stale anchor sent") } catch { precondition(error as? RTCDomainError == .staleAnchor) }
        let invalidSnapshot=await invalidSource.snapshot()
        precondition(invalidSnapshot.threads.first?.state == .draft)

        let unavailable=try await ReviewCommandHandler.open(manifest: fixture.manifest, repository: MemoryReviewEventRepository(), anchors: TestSource(valid: true), mutationPreflight: UnavailablePreflight())
        do { _=try await unavailable.createDraft(anchor: fixture.anchor, body: fixture.body); preconditionFailure("unverified mutation succeeded") } catch { precondition(error as? RTCDomainError == .readOnly) }
        let unavailableSnapshot=await unavailable.snapshot()
        precondition(!unavailableSnapshot.verificationAvailable)

        let stale=try await open(fixture, repository: MemoryReviewEventRepository())
        await stale.markHead(String(repeating: "c", count: 40)); await stale.markHead(fixture.revision.headSHA)
        do { _=try await stale.createDraft(anchor: fixture.anchor, body: fixture.body); preconditionFailure("sticky stale mutation succeeded") } catch { precondition(error as? RTCDomainError == .staleRevision) }

        let wrongHash=try ReviewAnchor(revision: fixture.revision, path: fixture.artifact.path, scope: .line, side: .new, startLine: 2, endLine: 2, startContextHash: SHA256Digest(data: Data("wrong".utf8)), endContextHash: fixture.hash)
        let guarded=try await open(fixture, repository: MemoryReviewEventRepository())
        do { _=try await guarded.createDraft(anchor: wrongHash, body: fixture.body); preconditionFailure("altered anchor persisted") } catch { }
        let guardedSnapshot=await guarded.snapshot()
        precondition(guardedSnapshot.cursor == 0)
    }

    private static func terminalMatrix(_ fixture: Fixture) async throws {
        for status in [ReviewStatus.approved, .changesRequested, .closed, .superseded] {
            let manifest=fixture.manifest(status: status)
            let repo=MemoryReviewEventRepository()
            let handler=try await ReviewCommandHandler.open(manifest: manifest, repository: repo, anchors: TestSource(valid: true), mutationPreflight: FixedReviewMutationPreflight(headSHA: fixture.revision.headSHA))
            do { _=try await handler.createDraft(anchor: fixture.anchor, body: fixture.body); preconditionFailure("terminal create succeeded") } catch { precondition(error as? RTCDomainError == .readOnly) }
            do { _=try await handler.reply(threadID: UUID(), body: fixture.body); preconditionFailure("terminal reply succeeded") } catch { precondition(error as? RTCDomainError == .readOnly) }
            do { _=try await handler.markViewed(path: fixture.artifact.path); preconditionFailure("terminal progress succeeded") } catch { precondition(error as? RTCDomainError == .readOnly) }
            do { _=try await handler.sendReview(threadIDs: [UUID()]); preconditionFailure("terminal send succeeded") } catch { precondition(error as? RTCDomainError == .readOnly) }
            do { _=try await handler.requestChanges(threadIDs: [], summary: fixture.body); preconditionFailure("terminal request succeeded") } catch { precondition(error as? RTCDomainError == .readOnly) }
            do { _=try await handler.resolve(threadID: UUID()); preconditionFailure("terminal resolve succeeded") } catch { precondition(error as? RTCDomainError == .readOnly) }
            do { _=try await handler.reopen(threadID: UUID()); preconditionFailure("terminal reopen succeeded") } catch { precondition(error as? RTCDomainError == .readOnly) }
            do { _=try await handler.approveExactRevision(); preconditionFailure("terminal approve succeeded") } catch { precondition(error as? RTCDomainError == .readOnly) }
            do { _=try await handler.closeReview(); preconditionFailure("terminal close succeeded") } catch { precondition(error as? RTCDomainError == .readOnly) }
            let events=try await repo.events(after: 0, reviewID: fixture.revision.reviewID)
            precondition(events.isEmpty)
        }
        let staleManifest=fixture.manifest(stale: true)
        let stale=try await ReviewCommandHandler.open(manifest: staleManifest, repository: MemoryReviewEventRepository(), anchors: TestSource(valid: true), mutationPreflight: FixedReviewMutationPreflight(headSHA: fixture.revision.headSHA))
        let staleSnapshot=await stale.snapshot()
        precondition(!staleSnapshot.isMutable)
    }

    private static func corruptReplay(_ fixture: Fixture) async throws {
        let malformed=ReviewEvent(id: UUID(), reviewID: fixture.revision.reviewID, revision: fixture.revision, sequence: 1, kind: .feedback, payload: ["version": "1", "data": "{}", "extra": "rejected"], createdAt: Date())
        do { _=try await ReviewCommandHandler.open(manifest: fixture.manifest, repository: StaticRepository([malformed]), anchors: TestSource(valid: true), mutationPreflight: FixedReviewMutationPreflight(headSHA: fixture.revision.headSHA)); preconditionFailure("malformed replay opened") } catch { }
        let gap=ReviewEvent(id: UUID(), reviewID: fixture.revision.reviewID, revision: fixture.revision, sequence: 2, kind: .close, payload: ["version": "1", "data": "{}"], createdAt: Date())
        do { _=try await ReviewCommandHandler.open(manifest: fixture.manifest, repository: StaticRepository([gap]), anchors: TestSource(valid: true), mutationPreflight: FixedReviewMutationPreflight(headSHA: fixture.revision.headSHA)); preconditionFailure("gapped replay opened") } catch { }
        let other=try RevisionIdentity(repositoryPath: fixture.revision.repositoryPath, baseSHA: fixture.revision.baseSHA, headSHA: String(repeating: "d", count: 40))
        let wrong=ReviewEvent(id: UUID(), reviewID: fixture.revision.reviewID, revision: other, sequence: 1, kind: .close, payload: ["version": "1", "data": "{}"], createdAt: Date())
        do { _=try await ReviewCommandHandler.open(manifest: fixture.manifest, repository: StaticRepository([wrong]), anchors: TestSource(valid: true), mutationPreflight: FixedReviewMutationPreflight(headSHA: fixture.revision.headSHA)); preconditionFailure("wrong revision replay opened") } catch { }
    }

    private static func open(_ fixture: Fixture, repository: any EventRepository) async throws -> ReviewCommandHandler {
        try await ReviewCommandHandler.open(manifest: fixture.manifest, repository: repository, anchors: TestSource(valid: true), mutationPreflight: FixedReviewMutationPreflight(headSHA: fixture.revision.headSHA))
    }
}

private struct Fixture {
    let revision: RevisionIdentity
    let hash: SHA256Digest
    let artifact: DiffArtifact
    let anchor: ReviewAnchor
    let body: RichText
    let manifest: ReviewManifest
    init() throws {
        revision=try RevisionIdentity(repositoryPath: "/tmp/rtc-reviewed-repository", baseSHA: String(repeating: "a", count: 40), headSHA: String(repeating: "b", count: 40))
        hash=SHA256Digest(data: Data("let value = 1".utf8))
        let line=DiffLine(kind: .addition, oldLine: nil, newLine: 2, text: "let value = 1", contextHash: hash)
        let hunk=DiffHunk(header: "@@ -0,0 +2 @@", oldStart: 0, oldLines: 0, newStart: 2, newLines: 1, lines: [line])
        artifact=DiffArtifact(path: "Sources/A.swift", status: .added, additions: 1, deletions: 0, binary: false, truncated: false, hunks: [hunk])
        anchor=try ReviewAnchor(revision: revision, path: artifact.path, scope: .line, side: .new, startLine: 2, endLine: 2, startContextHash: hash, endContextHash: hash)
        body=try RichText(runs: [RichTextRun(kind: .plain, text: "Please handle this case.")])
        manifest=ReviewManifest(id: revision.reviewID, revision: revision, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1), status: .ready, stale: false, summary: ReviewSummary(files: 1, additions: 1, deletions: 0), files: [artifact])
    }
    func manifest(status: ReviewStatus = .ready, stale: Bool = false) -> ReviewManifest { ReviewManifest(id: revision.reviewID, revision: revision, createdAt: manifest.createdAt, updatedAt: manifest.updatedAt, status: status, stale: stale, summary: manifest.summary, files: manifest.files) }
}
