import Foundation
import RTCContracts
import RTCDiagram
import RTCGit
import RTCSyntax
import RTCTour

public struct ManifestTourArtifactSource: ExactArtifactSource, AnchorArtifactSource, Sendable {
    public let manifest: ReviewManifest
    public init(manifest: ReviewManifest) { self.manifest = manifest }

    public func manifest(for revision: RevisionIdentity) async throws -> ReviewManifest {
        guard revision == manifest.revision, manifest.id == revision.reviewID else {
            throw TourIntegrationError.revisionMismatch
        }
        return manifest
    }

    public func validate(_ anchor: ReviewAnchor) async throws -> Bool {
        guard anchor.revision == manifest.revision,
            anchor.revision.reviewID == manifest.id,
            !anchor.path.hasPrefix("/"),
            !anchor.path.split(separator: "/").contains(".."),
            let file = manifest.files.first(where: { $0.path == anchor.path || $0.oldPath == anchor.path })
        else {
            return false
        }
        switch anchor.scope {
        case .general, .file:
            return anchor.startLine == nil && anchor.endLine == nil
        case .symbol:
            // The landed exact artifact contract has no committed symbol index yet.
            // Reject instead of guessing a symbol location from text.
            return false
        case .hunk:
            guard let index = anchor.hunkIndex, file.hunks.indices.contains(index) else { return false }
            guard let start = anchor.startLine, let end = anchor.endLine else { return true }
            return range(start, end, isWithin: file.hunks[index])
        case .line:
            guard let side = anchor.side, let start = anchor.startLine, let end = anchor.endLine else { return false }
            let candidates = file.hunks.flatMap(\.lines).filter { line in
                guard let number = side == .new ? line.newLine : line.oldLine else { return false }
                return (start...end).contains(number)
            }
            guard !candidates.isEmpty,
                candidates.contains(where: { (side == .new ? $0.newLine : $0.oldLine) == start }),
                candidates.contains(where: { (side == .new ? $0.newLine : $0.oldLine) == end })
            else {
                return false
            }
            if let expected = anchor.startContextHash,
                candidates.first(where: { (side == .new ? $0.newLine : $0.oldLine) == start })?.contextHash != expected
            {
                return false
            }
            if let expected = anchor.endContextHash,
                candidates.first(where: { (side == .new ? $0.newLine : $0.oldLine) == end })?.contextHash != expected
            {
                return false
            }
            return true
        }
    }

    private func range(_ start: Int, _ end: Int, isWithin hunk: DiffHunk) -> Bool {
        func contains(_ candidateStart: Int, _ count: Int) -> Bool {
            guard count > 0 else { return false }
            return start >= candidateStart && end <= candidateStart + count - 1
        }
        return contains(hunk.newStart, hunk.newLines) || contains(hunk.oldStart, hunk.oldLines)
    }
}

public struct ResolvedDiffSlice: Sendable, Hashable {
    public let reference: DiffSliceReference
    public let lines: [DiffLine]
    public let syntaxSpans: [SyntaxSpan]
    public init(reference: DiffSliceReference, lines: [DiffLine], syntaxSpans: [SyntaxSpan]) {
        self.reference = reference; self.lines = lines; self.syntaxSpans = syntaxSpans
    }
}

public protocol TourArtifactResolving: Sendable {
    func manifest(for revision: RevisionIdentity) async throws -> ReviewManifest
    func resolve(_ reference: DiffSliceReference, revision: RevisionIdentity) async throws -> ResolvedDiffSlice
    func layout(_ diagram: DiagramDocument) throws -> DiagramLayout
}

public struct ExactTourArtifactResolver: TourArtifactResolving, ExactArtifactSource, Sendable {
    private let git: any ExactGitService
    private let syntax: any SyntaxHighlighter

    public init(git: any ExactGitService, syntax: any SyntaxHighlighter = RTCSyntaxHighlighter()) {
        self.git = git; self.syntax = syntax
    }

    public func manifest(for revision: RevisionIdentity) async throws -> ReviewManifest {
        let manifest = try await git.materialize(revision)
        guard manifest.schemaVersion == RTCConstants.schemaVersion,
            manifest.revision == revision,
            manifest.id == revision.reviewID
        else {
            throw TourIntegrationError.revisionMismatch
        }
        return manifest
    }

    public func resolve(_ reference: DiffSliceReference, revision: RevisionIdentity) async throws -> ResolvedDiffSlice {
        let manifest = try await manifest(for: revision)
        let source = ManifestTourArtifactSource(manifest: manifest)
        let anchor = try ReviewAnchor(
            revision: revision, path: reference.path, scope: .hunk,
            startLine: reference.startLine, endLine: reference.endLine,
            hunkIndex: reference.hunkIndex)
        guard try await source.validate(anchor),
            let file = manifest.files.first(where: { $0.path == reference.path || $0.oldPath == reference.path }),
            file.hunks.indices.contains(reference.hunkIndex)
        else {
            throw TourIntegrationError.invalidPayload
        }
        let hunk = file.hunks[reference.hunkIndex]
        let lines = hunk.lines.filter { line in
            [line.newLine, line.oldLine].compactMap { $0 }.contains {
                (reference.startLine...reference.endLine).contains($0)
            }
        }
        guard !lines.isEmpty else { throw TourIntegrationError.invalidPayload }
        let sourceText = lines.map(\.text).joined(separator: "\n")
        let digest = SHA256Digest(data: Data(sourceText.utf8))
        let spans =
            (try? await syntax.highlight(
                path: file.path, fileDigest: digest, source: sourceText,
                language: nil, lines: nil)) ?? []
        return ResolvedDiffSlice(reference: reference, lines: lines, syntaxSpans: spans)
    }

    public func layout(_ diagram: DiagramDocument) throws -> DiagramLayout {
        try DiagramLayoutEngine.layout(DiagramValidator.validate(diagram))
    }
}
