import Foundation
import RTCContracts
import RTCInboxFeature
import RTCIngest

@main
struct InboxFeatureTests {
    static func main() throws {
        let base = String(repeating: "a", count: 40)
        let head = String(repeating: "b", count: 40)
        let revision = try RevisionIdentity(repositoryPath: "/tmp/repository", baseSHA: base, headSHA: head)
        let now = Date()
        let records = [
            record(revision, status: .failed, stale: false, updatedAt: now.addingTimeInterval(-2)),
            record(revision, status: .ready, stale: false, updatedAt: now),
            record(revision, status: .materializing, stale: false, updatedAt: now.addingTimeInterval(-1)),
            record(revision, status: .ready, stale: true, updatedAt: now.addingTimeInterval(-3)),
        ]
        let snapshot = InboxSnapshot(records: records)
        precondition(snapshot.items(in: .ready).count == 1, "ready section")
        precondition(snapshot.items(in: .pending).count == 1, "pending section")
        precondition(snapshot.items(in: .failed).count == 1, "failed section")
        precondition(snapshot.items(in: .stale).count == 1, "stale section")
        precondition(snapshot.items.first?.updatedAt == now, "newest first")
        print("RTC Inbox feature checks passed")
    }

    private static func record(
        _ revision: RevisionIdentity,
        status: ReviewStatus,
        stale: Bool,
        updatedAt: Date
    ) -> IngestReviewRecord {
        IngestReviewRecord(
            reviewID: revision.reviewID,
            revision: revision,
            baseRef: revision.baseSHA,
            headRef: revision.headSHA,
            title: status.rawValue,
            notify: true,
            unread: true,
            stale: stale,
            status: status,
            errorCode: status == .failed ? "INTERNAL_ERROR" : nil,
            errorMessage: status == .failed ? "Materialization failed." : nil,
            supersedes: nil,
            supersededBy: nil,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }
}
