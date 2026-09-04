import Foundation
import RTCContracts
import RTCGit

public struct SubmissionOperationHandler: IPCOperationHandler {
    private let coordinator: SubmissionCoordinator

    public init(coordinator: SubmissionCoordinator) { self.coordinator = coordinator }

    public func handle(_ request: IPCRequest) async -> IPCResponse {
        do {
            let payload: Data
            switch request.operation.value {
            case "submitReview":
                let submission = try decode(ReviewSubmission.self, request.payload)
                payload = try RTCCanonicalJSON.encode(try await coordinator.submit(submission))
            case "status":
                let lookup = try decode(ReviewLookup.self, request.payload)
                payload = try RTCCanonicalJSON.encode(try await coordinator.status(lookup.reviewID))
            case "pollReviewEvents":
                let lookup = try decode(ReviewLookup.self, request.payload)
                payload = try RTCCanonicalJSON.encode(try await coordinator.poll(lookup))
            case "closeReview":
                let lookup = try decode(ReviewLookup.self, request.payload)
                payload = try RTCCanonicalJSON.encode(try await coordinator.close(lookup.reviewID))
            case "retryReview":
                let lookup = try decode(ReviewLookup.self, request.payload)
                try await coordinator.retry(lookup.reviewID)
                payload = try RTCCanonicalJSON.encode(try await coordinator.status(lookup.reviewID))
            default:
                throw IngestError.invalidSubmission
            }
            return IPCResponse(
                schemaVersion: RTCConstants.schemaVersion,
                requestID: request.id,
                ok: true,
                error: nil,
                payload: payload
            )
        } catch {
            return failure(request.id, error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data?) throws -> T {
        guard let data, data.count <= RTCConstants.maxRequestBytes else { throw IngestError.invalidSubmission }
        return try JSONDecoder().decode(type, from: data)
    }

    private func failure(_ requestID: UUID, _ error: Error) -> IPCResponse {
        let value: RTCError
        switch error {
        case IngestError.notFound:
            value = RTCError(code: .invalidRevision, message: "Review was not found.", retryable: false)
        case IngestError.idempotencyConflict, IngestError.invalidSubmission, IngestError.invalidTransition:
            value = RTCError(code: .invalidRevision, message: "The submission is invalid.", retryable: false)
        case GitEngineError.invalidRef:
            value = RTCError(code: .invalidRef, message: "A submitted revision cannot be resolved.", retryable: false)
        case GitEngineError.invalidRepository:
            value = RTCError(code: .invalidRevision, message: "Repository is unavailable or invalid.", retryable: true)
        default:
            value = RTCError(code: .internalError, message: "The operation failed.", retryable: true)
        }
        return IPCResponse(
            schemaVersion: RTCConstants.schemaVersion,
            requestID: requestID,
            ok: false,
            error: value,
            payload: nil
        )
    }
}
