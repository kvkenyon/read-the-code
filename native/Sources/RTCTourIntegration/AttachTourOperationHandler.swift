import Foundation
import RTCContracts

public struct AttachTourOperationHandler: IPCOperationHandler {
    private let jobs: TourGenerationJobHandler
    public init(jobs: TourGenerationJobHandler) { self.jobs = jobs }

    public func handle(_ request: IPCRequest) async -> IPCResponse {
        guard request.schemaVersion == RTCConstants.schemaVersion else {
            return failure(request, code: .unknownMajor, message: "Unsupported schema major.")
        }
        guard request.operation.value == "attachTour",
            let reviewID = request.reviewID,
            let payload = request.payload,
            payload.count <= RTCConstants.maxDocumentBytes
        else {
            return failure(request, code: .invalidJSON, message: "Invalid attachTour payload.")
        }
        do {
            let envelope = try StrictTourDecoder.decodeWorkerEnvelope(payload)
            guard envelope.document.revision.reviewID == reviewID else {
                return failure(request, code: .invalidRevision, message: "Tour revision does not match the review.")
            }
            let run = try await jobs.attachPayload(
                envelope.rawDocumentPayload, reviewID: reviewID,
                attribution: envelope.attribution)
            guard run.state == .succeeded else {
                return failure(
                    request, code: run.failureCode ?? .tourRejected,
                    message: "Tour rejected by structured-content validation.")
            }
            let response = try JSONEncoder().encode(run)
            return IPCResponse(
                schemaVersion: RTCConstants.schemaVersion, requestID: request.id,
                ok: true, error: nil, payload: response)
        } catch TourIntegrationError.readOnlyReview {
            return failure(request, code: .staleRevision, message: "This exact review revision is read-only.")
        } catch TourIntegrationError.tourIDConflict {
            return failure(request, code: .tourIDConflict, message: "Tour ID conflicts with existing provenance.")
        } catch {
            return failure(request, code: .tourRejected, message: "Tour rejected by strict decoding.")
        }
    }

    private func failure(_ request: IPCRequest, code: RTCErrorCode, message: BoundedString) -> IPCResponse {
        IPCResponse(
            schemaVersion: RTCConstants.schemaVersion, requestID: request.id, ok: false,
            error: RTCError(code: code, message: message, retryable: false), payload: nil)
    }
}
