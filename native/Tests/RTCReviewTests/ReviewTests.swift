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
private enum SimulatedTransportError: Error, Equatable { case responseLost }
private actor CommitThenLoseRepository: EventRepository {
    private var stored: [ReviewEvent] = []
    private var lossKinds: [ReviewEventKind]
    private let delayedKinds: [ReviewEventKind]
    private var originals: [UUID: PendingReviewEvent] = [:]
    private(set) var exactRetryCount = 0

    init(lossKinds: [ReviewEventKind], delayedKinds: [ReviewEventKind] = []) {
        self.lossKinds = lossKinds
        self.delayedKinds = delayedKinds
    }

    func append(_ proposal: PendingReviewEvent, after expectedSequence: Int) async throws -> ReviewEvent {
        if let existing = stored.first(where: { $0.id == proposal.id }) {
            guard let original = originals[proposal.id], Self.identical(original, proposal) else { throw EventRepositoryError.idempotencyConflict }
            exactRetryCount += 1
            return existing
        }
        guard stored.count == expectedSequence else { throw EventRepositoryError.concurrentModification }
        originals[proposal.id] = proposal
        let event=ReviewEvent(id: proposal.id, reviewID: proposal.reviewID, revision: proposal.revision, sequence: stored.count + 1, kind: proposal.kind, payload: proposal.payload, createdAt: proposal.createdAt)
        stored.append(event)
        if let index = lossKinds.firstIndex(where: { $0 == proposal.kind }) {
            lossKinds.remove(at: index)
            if delayedKinds.contains(where: { $0 == proposal.kind }) {
                try? await Task.sleep(nanoseconds: 1_100_000_000)
            } else {
                await Task.yield()
            }
            throw SimulatedTransportError.responseLost
        }
        return event
    }

    func events(after sequence: Int, reviewID: ReviewID) async throws -> [ReviewEvent] {
        stored.filter { $0.reviewID == reviewID && $0.sequence > sequence }
    }

    private static func identical(_ lhs: PendingReviewEvent, _ rhs: PendingReviewEvent) -> Bool {
        lhs.id == rhs.id && lhs.reviewID == rhs.reviewID && lhs.revision == rhs.revision && lhs.kind == rhs.kind && lhs.payload == rhs.payload && lhs.createdAt == rhs.createdAt
    }
}
private actor TailConflictRepository: EventRepository {
    private let competingPayload: [String: String]
    private var stored: [ReviewEvent] = []
    private var injected = false

    init(competingPayload: [String: String]) { self.competingPayload = competingPayload }

    func append(_ proposal: PendingReviewEvent, after expectedSequence: Int) async throws -> ReviewEvent {
        if !injected {
            injected = true
            stored.append(ReviewEvent(id: UUID(), reviewID: proposal.reviewID, revision: proposal.revision, sequence: 1, kind: .fileProgressChanged, payload: competingPayload, createdAt: proposal.createdAt))
            throw EventRepositoryError.concurrentModification
        }
        guard stored.count == expectedSequence else { throw EventRepositoryError.concurrentModification }
        let event=ReviewEvent(id: proposal.id, reviewID: proposal.reviewID, revision: proposal.revision, sequence: stored.count + 1, kind: proposal.kind, payload: proposal.payload, createdAt: proposal.createdAt)
        stored.append(event)
        return event
    }

    func events(after sequence: Int, reviewID: ReviewID) async throws -> [ReviewEvent] {
        stored.filter { $0.reviewID == reviewID && $0.sequence > sequence }
    }
}

@main enum RTCReviewTests {
    static func main() async throws {
        let fixture=try Fixture()
        try await workflow(fixture)
        try await anchorAndPreflightGuards(fixture)
        try await terminalMatrix(fixture)
        try await corruptReplay(fixture)
        try await responseLossRetries(fixture)
        try await conflictRevalidatesCandidate(fixture)
        try await strictPayloadSchemas(fixture)
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

    private static func responseLossRetries(_ fixture: Fixture) async throws {
        let repository=CommitThenLoseRepository(
            lossKinds: [.threadCreated, .feedback, .threadMessageAdded, .fileProgressChanged, .approval],
            delayedKinds: [.threadCreated, .threadMessageAdded]
        )
        let handler=try await open(fixture, repository: repository)

        let draftOperation=UUID()
        do { _=try await handler.createDraft(anchor: fixture.anchor, body: fixture.body, operationID: draftOperation); preconditionFailure("draft response was not lost") }
        catch { precondition(error as? SimulatedTransportError == .responseLost) }
        let threadID=try await handler.createDraft(anchor: fixture.anchor, body: fixture.body, operationID: draftOperation)
        precondition(threadID == draftOperation)

        let feedbackOperation=UUID()
        do { _=try await handler.sendReview(threadIDs: [threadID], operationID: feedbackOperation); preconditionFailure("feedback response was not lost") }
        catch { precondition(error as? SimulatedTransportError == .responseLost) }
        _=try await handler.sendReview(threadIDs: [threadID], operationID: feedbackOperation)

        let replyOperation=UUID()
        do { _=try await handler.reply(threadID: threadID, body: fixture.body, operationID: replyOperation); preconditionFailure("reply response was not lost") }
        catch { precondition(error as? SimulatedTransportError == .responseLost) }
        _=try await handler.reply(threadID: threadID, body: fixture.body, operationID: replyOperation)

        let progressOperation=UUID()
        do { _=try await handler.markViewed(path: fixture.artifact.path, expectedVersion: 0, operationID: progressOperation); preconditionFailure("progress response was not lost") }
        catch { precondition(error as? SimulatedTransportError == .responseLost) }
        _=try await handler.markViewed(path: fixture.artifact.path, expectedVersion: 0, operationID: progressOperation)

        let approvalOperation=UUID()
        do { _=try await handler.approveExactRevision(operationID: approvalOperation); preconditionFailure("approval response was not lost") }
        catch { precondition(error as? SimulatedTransportError == .responseLost) }
        _=try await handler.approveExactRevision(operationID: approvalOperation)
        let retryCount=await repository.exactRetryCount
        precondition(retryCount == 5, "every ambiguous append must retry its byte-identical pending event")

        let changesRepository=CommitThenLoseRepository(lossKinds: [.changesRequested])
        let changes=try await open(fixture, repository: changesRepository)
        let summary=try RichText(runs: [RichTextRun(kind: .plain, text: "Retry the terminal decision")])
        let changesOperation=UUID()
        do { _=try await changes.requestChanges(threadIDs: [], summary: summary, operationID: changesOperation); preconditionFailure("request-changes response was not lost") }
        catch { precondition(error as? SimulatedTransportError == .responseLost) }
        _=try await changes.requestChanges(threadIDs: [], summary: summary, operationID: changesOperation)
        let changesRetryCount=await changesRepository.exactRetryCount
        precondition(changesRetryCount == 1)

        let closeRepository=CommitThenLoseRepository(lossKinds: [.close])
        let close=try await open(fixture, repository: closeRepository)
        let closeOperation=UUID()
        do { _=try await close.closeReview(operationID: closeOperation); preconditionFailure("close response was not lost") }
        catch { precondition(error as? SimulatedTransportError == .responseLost) }
        _=try await close.closeReview(operationID: closeOperation)
        let closeRetryCount=await closeRepository.exactRetryCount
        precondition(closeRetryCount == 1)
    }

    private static func strictPayloadSchemas(_ fixture: Fixture) async throws {
        let id=UUID().uuidString.lowercased()
        let eventID=UUID()
        let validMessage=ThreadMessage(id: eventID, sequence: 1, author: .captain, body: fixture.body, createdAt: Date(timeIntervalSince1970: 10))
        let validThread=ReviewThread(id: eventID, reviewID: fixture.revision.reviewID, revision: fixture.revision, anchor: fixture.anchor, messages: [validMessage])

        let encodedThread = try jsonObject(validThread)
        var canonicalReducer = try ReviewReducer(manifest: fixture.manifest)
        try canonicalReducer.apply(ReviewEvent(
            id: eventID,
            reviewID: fixture.revision.reviewID,
            revision: fixture.revision,
            sequence: 1,
            kind: .threadCreated,
            payload: try payload(["thread": encodedThread]),
            createdAt: Date(timeIntervalSince1970: 10)
        ))
        precondition(canonicalReducer.snapshot.threads.map(\.id) == [eventID], "encoder-produced scalar review ID survives strict replay")

        let legacyEventID = UUID()
        let legacyMessage = ThreadMessage(id: legacyEventID, sequence: 1, author: .captain, body: fixture.body, createdAt: Date(timeIntervalSince1970: 10))
        let legacyThread = ReviewThread(id: legacyEventID, reviewID: fixture.revision.reviewID, revision: fixture.revision, anchor: fixture.anchor, messages: [legacyMessage])
        var legacyThreadObject = try jsonObject(legacyThread) as! [String: Any]
        legacyThreadObject["reviewID"] = ["value": fixture.revision.reviewID.value]
        var legacyReducer = try ReviewReducer(manifest: fixture.manifest)
        try legacyReducer.apply(ReviewEvent(
            id: legacyEventID,
            reviewID: fixture.revision.reviewID,
            revision: fixture.revision,
            sequence: 1,
            kind: .threadCreated,
            payload: try payload(["thread": legacyThreadObject]),
            createdAt: Date(timeIntervalSince1970: 10)
        ))
        precondition(legacyReducer.snapshot.threads.map(\.id) == [legacyEventID], "legacy object review ID survives strict replay")

        for malformedReviewID: Any in [
            String(repeating: "a", count: 23),
            String(repeating: "g", count: 24),
            ["value": String(repeating: "a", count: 23)],
            ["value": fixture.revision.reviewID.value, "unexpected": true],
        ] {
            var malformedThread = try jsonObject(validThread) as! [String: Any]
            malformedThread["reviewID"] = malformedReviewID
            try expectPayloadCorrupt(
                kind: .threadCreated,
                payload: payload(["thread": malformedThread]),
                fixture: fixture,
                reason: "invalid payload schema"
            )
        }

        for kind in [ReviewEventKind.threadCreated, .threadMessageAdded, .fileProgressChanged, .feedback, .changesRequested, .approval, .threadResolved, .threadReopened] {
            try expectPayloadCorrupt(kind: kind, payload: payload([:]), fixture: fixture, reason: "invalid payload schema")
        }
        try expectPayloadCorrupt(kind: .close, payload: ["version": "1"], fixture: fixture, reason: "invalid payload envelope")

        let extraShapes: [(ReviewEventKind, [String: Any])] = [
            (.threadCreated, ["thread": NSNull(), "unexpected": true]),
            (.threadMessageAdded, ["message": NSNull(), "threadID": id, "unexpected": true]),
            (.fileProgressChanged, ["progress": NSNull(), "unexpected": true]),
            (.feedback, ["threadIDs": [], "unexpected": true]),
            (.changesRequested, ["threadIDs": [], "unexpected": true]),
            (.approval, ["unexpected": true, "warnings": []]),
            (.close, ["unexpected": true]),
            (.threadResolved, ["threadID": id, "unexpected": true]),
            (.threadReopened, ["threadID": id, "unexpected": true])
        ]
        for (kind, object) in extraShapes {
            try expectPayloadCorrupt(kind: kind, payload: payload(object), fixture: fixture, reason: "invalid payload schema")
        }

        let wrongTypes: [(ReviewEventKind, Any)] = [
            (.threadCreated, ["thread": "invalid"]),
            (.threadMessageAdded, ["message": "invalid", "threadID": id]),
            (.fileProgressChanged, ["progress": "invalid"]),
            (.feedback, ["threadIDs": "invalid"]),
            (.changesRequested, ["threadIDs": "invalid"]),
            (.approval, ["warnings": "invalid"]),
            (.close, []),
            (.threadResolved, ["threadID": 1]),
            (.threadReopened, ["threadID": 1])
        ]
        for (kind, object) in wrongTypes {
            try expectPayloadCorrupt(kind: kind, payload: payload(object), fixture: fixture, reason: "invalid payload schema")
        }

        try expectPayloadCorrupt(kind: .feedback, payload: payload(["threadIDs": [id, id]]), fixture: fixture, reason: "invalid payload schema")
        let lower="00000000-0000-4000-8000-000000000001", higher="ffffffff-ffff-4fff-8fff-ffffffffffff"
        try expectPayloadCorrupt(kind: .feedback, payload: payload(["threadIDs": [higher, lower]]), fixture: fixture, reason: "invalid payload schema")
        try expectPayloadCorrupt(kind: .changesRequested, payload: payload(["threadIDs": [id, id]]), fixture: fixture, reason: "invalid payload schema")
        try expectPayloadCorrupt(kind: .approval, payload: payload(["warnings": ["draft", "draft"]]), fixture: fixture, reason: "invalid payload schema")
        try expectPayloadCorrupt(kind: .fileProgressChanged, payload: payload(["progress": ["path": fixture.artifact.path, "version": 1, "viewed": "yes"]]), fixture: fixture, reason: "invalid payload schema")
        try expectPayloadCorrupt(kind: .fileProgressChanged, payload: payload(["progress": ["path": String(repeating: "a", count: RTCConstants.maxPathBytes + 1), "version": 1, "viewed": true]]), fixture: fixture, reason: "invalid payload schema")
        try expectPayloadCorrupt(kind: .approval, payload: payload(["warnings": ["unsupported"]]), fixture: fixture, reason: "invalid payload schema")
        let excessiveIDs=(0...RTCConstants.maxAnchors).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        try expectPayloadCorrupt(kind: .feedback, payload: payload(["threadIDs": excessiveIDs]), fixture: fixture, reason: "invalid payload schema")
        try expectPayloadCorrupt(kind: .changesRequested, payload: payload(["threadIDs": excessiveIDs]), fixture: fixture, reason: "invalid payload schema")
        try expectPayloadCorrupt(kind: .approval, payload: payload(["warnings": Array(repeating: "draft", count: RTCConstants.maxFiles + 1)]), fixture: fixture, reason: "invalid payload schema")
        try expectPayloadCorrupt(kind: .threadMessageAdded, payload: payload([
            "threadID": id,
            "message": [
                "author": "captain",
                "body": ["runs": [["kind": "plain", "text": String(repeating: "a", count: RTCConstants.maxCommentBytes + 1)]]],
                "createdAt": "1970-01-01T00:00:10Z",
                "id": id,
                "sequence": 1
            ]
        ]), fixture: fixture, reason: "invalid payload schema")
        var excessiveThread=try jsonObject(validThread) as! [String: Any]
        let messageObject=try jsonObject(validMessage)
        excessiveThread["messages"]=Array(repeating: messageObject, count: 257)
        try expectPayloadCorrupt(kind: .threadCreated, payload: payload(["thread": excessiveThread]), fixture: fixture, reason: "invalid payload schema")
        try expectPayloadCorrupt(kind: .feedback, payload: ["version": "1", "data": "{\"threadIDs\":[],\"threadIDs\":[]}"], fixture: fixture, reason: "invalid payload schema")
        try expectPayloadCorrupt(kind: .feedback, payload: ["version": "1", "data": "{ \"threadIDs\": [] }"], fixture: fixture, reason: "invalid payload schema")

        let workerMessage=ThreadMessage(id: eventID, sequence: 1, author: .worker, body: fixture.body, createdAt: Date(timeIntervalSince1970: 10))
        let workerThread=ReviewThread(id: eventID, reviewID: fixture.revision.reviewID, revision: fixture.revision, anchor: fixture.anchor, messages: [workerMessage])
        try expectEventRejected(kind: .threadCreated, id: eventID, payload: payload(["thread": try jsonObject(workerThread)]), fixture: fixture)
        let orphanMessage=ThreadMessage(id: eventID, sequence: 1, author: .captain, body: fixture.body, createdAt: Date(timeIntervalSince1970: 10))
        try expectEventRejected(kind: .threadMessageAdded, id: eventID, payload: payload(["message": try jsonObject(orphanMessage), "threadID": UUID().uuidString]), fixture: fixture)
        try expectEventRejected(kind: .fileProgressChanged, id: eventID, payload: payload(["progress": ["path": "unknown.swift", "version": 1, "viewed": true]]), fixture: fixture)
        try expectEventRejected(kind: .feedback, id: eventID, payload: payload(["threadIDs": []]), fixture: fixture)
        try expectEventRejected(kind: .changesRequested, id: eventID, payload: payload(["threadIDs": []]), fixture: fixture)
        try expectEventRejected(kind: .approval, id: eventID, payload: payload(["warnings": []]), fixture: fixture)
        try expectEventRejected(kind: .threadResolved, id: eventID, payload: payload(["threadID": UUID().uuidString]), fixture: fixture)
        try expectEventRejected(kind: .threadReopened, id: eventID, payload: payload(["threadID": UUID().uuidString]), fixture: fixture)

        var reducer=try ReviewReducer(manifest: fixture.manifest)
        let close=ReviewEvent(id: UUID(), reviewID: fixture.revision.reviewID, revision: fixture.revision, sequence: 1, kind: .close, payload: try payload([:]), createdAt: Date())
        try reducer.apply(close)
        precondition(reducer.snapshot.status == .closed, "close accepts exact canonical empty object only")
        let repeatedClose=ReviewEvent(id: UUID(), reviewID: fixture.revision.reviewID, revision: fixture.revision, sequence: 2, kind: .close, payload: try payload([:]), createdAt: Date())
        do { try reducer.apply(repeatedClose); preconditionFailure("semantically invalid repeated close applied") } catch { }

        let malformed=ReviewEvent(id: UUID(), reviewID: fixture.revision.reviewID, revision: fixture.revision, sequence: 1, kind: .close, payload: ["version": "1", "data": "{\"unexpected\":true}"], createdAt: Date())
        do { _=try await ReviewCommandHandler.open(manifest: fixture.manifest, repository: StaticRepository([malformed]), anchors: TestSource(valid: true), mutationPreflight: FixedReviewMutationPreflight(headSHA: fixture.revision.headSHA)); preconditionFailure("strict corruption hydrated") } catch { }
    }

    private static func conflictRevalidatesCandidate(_ fixture: Fixture) async throws {
        let competing=try payload(["progress": ["path": fixture.artifact.path, "version": 1, "viewed": true]])
        let repository=TailConflictRepository(competingPayload: competing)
        let handler=try await open(fixture, repository: repository)
        do {
            _=try await handler.markViewed(path: fixture.artifact.path, viewed: false, expectedVersion: 0)
            preconditionFailure("candidate prepared against a stale tail was appended")
        } catch {
            precondition(error as? RTCDomainError == .invalidTransition)
        }
        let snapshot=await handler.snapshot()
        precondition(snapshot.cursor == 1 && snapshot.progress.first?.viewed == true && snapshot.progress.first?.version == 1, "tail conflict must replay the winner before candidate revalidation")
    }

    private static func expectPayloadCorrupt(kind: ReviewEventKind, payload: [String: String], fixture: Fixture, reason: String) throws {
        var reducer=try ReviewReducer(manifest: fixture.manifest)
        let event=ReviewEvent(id: UUID(), reviewID: fixture.revision.reviewID, revision: fixture.revision, sequence: 1, kind: kind, payload: payload, createdAt: Date())
        do { try reducer.apply(event); preconditionFailure("\(kind.rawValue) malformed payload applied") }
        catch { precondition(error as? ReviewStateError == .corrupt(reason), "unexpected corruption result for \(kind.rawValue): \(error)") }
    }

    private static func expectEventRejected(kind: ReviewEventKind, id: UUID, payload: [String: String], fixture: Fixture) throws {
        var reducer=try ReviewReducer(manifest: fixture.manifest)
        let event=ReviewEvent(id: id, reviewID: fixture.revision.reviewID, revision: fixture.revision, sequence: 1, kind: kind, payload: payload, createdAt: Date())
        do { try reducer.apply(event); preconditionFailure("\(kind.rawValue) semantic corruption applied") } catch { }
    }

    private static func payload(_ object: Any) throws -> [String: String] {
        let data=try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return ["version": "1", "data": String(decoding: data, as: UTF8.self)]
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: RTCCanonicalJSON.encode(value))
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
