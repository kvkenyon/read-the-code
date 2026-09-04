import Darwin
import Foundation
import RTCContracts
import RTCDomain
import RTCReview
import RTCStore

private struct Source: AnchorArtifactSource { func validate(_ anchor: ReviewAnchor) async throws -> Bool { true } }

@main enum RTCReviewPersistenceTests {
    static func main() async throws {
        let fixture=try Fixture()
        try await restartAndPrivateState(fixture)
        try await idempotency(fixture)
        try await concurrentWriters(fixture)
        try await decisionRace(fixture)
        print("RTC review SQLite persistence checks passed")
    }

    private static func restartAndPrivateState(_ fixture: Fixture) async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("rtc-state-\(UUID().uuidString)")
        let reviewed=FileManager.default.temporaryDirectory.appendingPathComponent("rtc-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: reviewed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: reviewed) }
        let manifest=fixture.manifest(repositoryPath: reviewed.path)
        let store=try SQLiteStore(rootURL: root); let reviews=SQLiteReviewRepository(store: store); try await reviews.save(manifest)
        let events=SQLiteEventRepository(store: store)
        let handler=try await open(manifest, repository: events)
        let thread=try await handler.createDraft(anchor: try fixture.anchor(revision: manifest.revision), body: fixture.body)
        _=try await handler.markViewed(path: fixture.artifact.path, expectedVersion: 0)
        _=try await handler.markViewed(path: fixture.artifact.path, viewed: false, expectedVersion: 1)
        _=try await handler.sendReview(threadIDs: [thread])
        _=try await handler.reply(threadID: thread, body: fixture.body)
        _=try await handler.resolve(threadID: thread)
        let expected=await handler.snapshot()

        let reopenedStore=try SQLiteStore(rootURL: root)
        let reopened=try await open(manifest, repository: SQLiteEventRepository(store: reopenedStore))
        let reopenedSnapshot=await reopened.snapshot()
        precondition(reopenedSnapshot == expected, "SQLite replay must survive fresh store and handler instances")
        let rootMode=(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue
        let dbMode=(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("ReviewStore.sqlite").path)[.posixPermissions] as? NSNumber)?.intValue
        precondition(rootMode == 0o700 && dbMode == 0o600, "state permissions must remain private")
        let reviewedFiles=try FileManager.default.contentsOfDirectory(atPath: reviewed.path)
        precondition(reviewedFiles.isEmpty, "review state must stay outside the reviewed repository")
    }

    private static func idempotency(_ fixture: Fixture) async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("rtc-idempotency-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: root) }
        let manifest=fixture.manifest(); let store=try SQLiteStore(rootURL: root); try await SQLiteReviewRepository(store: store).save(manifest)
        let repository=SQLiteEventRepository(store: store)
        let id=UUID(), proposal=PendingReviewEvent(id: id, reviewID: manifest.id, revision: manifest.revision, kind: .feedback, payload: ["data": "opaque", "version": "1"], createdAt: Date(timeIntervalSince1970: 100))
        let first=try await repository.append(proposal, after: 0)
        let retry=try await repository.append(proposal, after: 99)
        precondition(first == retry && retry.sequence == 1, "response-loss retry must return the original event")
        try await SQLiteReviewRepository(store: store).save(ReviewManifest(id: manifest.id, revision: manifest.revision, createdAt: manifest.createdAt, updatedAt: Date(), status: .ready, stale: true, summary: manifest.summary, files: manifest.files))
        let staleRetry=try await repository.append(proposal, after: 99)
        precondition(staleRetry == first, "idempotent retry precedes stale guards")
        let blocked=PendingReviewEvent(reviewID: manifest.id, revision: manifest.revision, kind: .close, payload: ["data": "{}", "version": "1"], createdAt: Date(timeIntervalSince1970: 101))
        do { _=try await repository.append(blocked, after: 1); preconditionFailure("new stale mutation appended") } catch { precondition(error as? EventRepositoryError == .reviewUnavailable) }
        let conflict=PendingReviewEvent(id: id, reviewID: manifest.id, revision: manifest.revision, kind: .feedback, payload: ["data": "changed", "version": "1"], createdAt: Date(timeIntervalSince1970: 100))
        do { _=try await repository.append(conflict, after: 1); preconditionFailure("idempotency collision succeeded") } catch { precondition(error as? EventRepositoryError == .idempotencyConflict) }
        let replayed=try await repository.events(after: 0, reviewID: manifest.id)
        precondition(replayed.count == 1)
    }

    private static func concurrentWriters(_ fixture: Fixture) async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("rtc-concurrency-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: root) }
        let manifest=fixture.manifest(); let store=try SQLiteStore(rootURL: root); try await SQLiteReviewRepository(store: store).save(manifest)
        let repository=SQLiteEventRepository(store: store)
        let first=try await open(manifest, repository: repository), second=try await open(manifest, repository: repository)
        let anchor=try fixture.anchor(revision: manifest.revision)
        try await withThrowingTaskGroup(of: UUID.self) { group in
            for index in 0..<8 {
                let handler=index.isMultiple(of: 2) ? first : second
                group.addTask { try await handler.createDraft(anchor: anchor, body: fixture.body) }
            }
            var ids=Set<UUID>(); for try await id in group { ids.insert(id) }
            precondition(ids.count == 8)
        }
        let stored=try await repository.events(after: 0, reviewID: manifest.id)
        precondition(stored.map(\.sequence) == Array(1...8))

        let progressA=try await open(manifest, repository: repository), progressB=try await open(manifest, repository: repository)
        async let a: ReviewEvent = progressA.markViewed(path: fixture.artifact.path, expectedVersion: 0)
        async let b: ReviewEvent = progressB.markViewed(path: fixture.artifact.path, expectedVersion: 0)
        var successes=0, failures=0
        do { _=try await a; successes += 1 } catch { failures += 1 }
        do { _=try await b; successes += 1 } catch { failures += 1 }
        precondition(successes == 1 && failures == 1, "optimistic file progress must have one winner")
    }

    private static func decisionRace(_ fixture: Fixture) async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("rtc-decision-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: root) }
        let manifest=fixture.manifest(); let store=try SQLiteStore(rootURL: root); try await SQLiteReviewRepository(store: store).save(manifest)
        let repository=SQLiteEventRepository(store: store)
        let approve=try await open(manifest, repository: repository), request=try await open(manifest, repository: repository)
        let summary=try RichText(runs: [RichTextRun(kind: .plain, text: "Needs changes")])
        async let a: ReviewEvent = approve.approveExactRevision()
        async let b: ReviewEvent = request.requestChanges(threadIDs: [], summary: summary)
        var successes=0, failures=0
        do { _=try await a; successes += 1 } catch { failures += 1 }
        do { _=try await b; successes += 1 } catch { failures += 1 }
        precondition(successes == 1 && failures == 1)
        let reopened=try await open(manifest, repository: repository)
        let snapshot=await reopened.snapshot()
        precondition([ReviewStatus.approved, .changesRequested].contains(snapshot.status))
    }

    private static func open(_ manifest: ReviewManifest, repository: any EventRepository) async throws -> ReviewCommandHandler {
        try await ReviewCommandHandler.open(manifest: manifest, repository: repository, anchors: Source(), mutationPreflight: FixedReviewMutationPreflight(headSHA: manifest.revision.headSHA))
    }
}

private struct Fixture {
    let hash=SHA256Digest(data: Data("let value = 1".utf8))
    let artifact: DiffArtifact
    let body: RichText
    init() throws {
        let line=DiffLine(kind: .addition, oldLine: nil, newLine: 1, text: "let value = 1", contextHash: hash)
        artifact=DiffArtifact(path: "Sources/App.swift", status: .added, additions: 1, deletions: 0, binary: false, truncated: false, hunks: [DiffHunk(header: "@@ -0,0 +1 @@", oldStart: 0, oldLines: 0, newStart: 1, newLines: 1, lines: [line])])
        body=try RichText(runs: [RichTextRun(kind: .plain, text: "Persistent feedback")])
    }
    func manifest(repositoryPath: String = "/tmp/rtc-persistence-reviewed") -> ReviewManifest {
        let revision=try! RevisionIdentity(repositoryPath: repositoryPath, baseSHA: String(repeating: "a", count: 40), headSHA: String(repeating: "b", count: 40))
        return ReviewManifest(id: revision.reviewID, revision: revision, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1), status: .ready, stale: false, summary: ReviewSummary(files: 1, additions: 1, deletions: 0), files: [artifact])
    }
    func anchor(revision: RevisionIdentity) throws -> ReviewAnchor { try ReviewAnchor(revision: revision, path: artifact.path, scope: .line, side: .new, startLine: 1, endLine: 1, startContextHash: hash, endContextHash: hash) }
}
