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
            !anchor.path.split(separator: "/").contains("..")
        else {
            return false
        }
        let file: DiffArtifact?
        switch anchor.side {
        case .new: file = manifest.files.first { $0.path == anchor.path }
        case .old: file = manifest.files.first { $0.oldPath == anchor.path || $0.path == anchor.path }
        case nil: file = manifest.files.first { $0.path == anchor.path || $0.oldPath == anchor.path }
        }
        guard let file else { return false }
        switch anchor.scope {
        case .general, .file:
            return anchor.startLine == nil && anchor.endLine == nil
        case .symbol:
            // The landed exact artifact contract has no committed symbol index yet.
            // Reject instead of guessing a symbol location from text.
            return false
        case .hunk:
            guard let index = anchor.hunkIndex, file.hunks.indices.contains(index) else { return false }
            guard let start = anchor.startLine, let end = anchor.endLine else { return anchor.side == nil }
            guard let side = anchor.side else { return false }
            return exactLines(
                in: file.hunks[index], side: side, start: start, end: end,
                startHash: anchor.startContextHash, endHash: anchor.endContextHash) != nil
        case .line:
            guard let side = anchor.side, let start = anchor.startLine, let end = anchor.endLine else { return false }
            let available = file.hunks.flatMap(\.lines)
            return exactLines(
                in: available, side: side, start: start, end: end,
                startHash: anchor.startContextHash, endHash: anchor.endContextHash) != nil
        }
    }

    public func exactLines(for reference: DiffSliceReference) -> [DiffLine]? {
        let file: DiffArtifact?
        if reference.side == .new {
            file = manifest.files.first { $0.path == reference.path }
        } else {
            file = manifest.files.first { $0.oldPath == reference.path || $0.path == reference.path }
        }
        guard let file, file.hunks.indices.contains(reference.hunkIndex) else { return nil }
        return exactLines(
            in: file.hunks[reference.hunkIndex], side: reference.side,
            start: reference.startLine, end: reference.endLine,
            startHash: reference.startContextHash, endHash: reference.endContextHash)
    }

    private func exactLines(
        in hunk: DiffHunk, side: AnchorSide, start: Int, end: Int,
        startHash: SHA256Digest?, endHash: SHA256Digest?
    ) -> [DiffLine]? {
        exactLines(
            in: hunk.lines, side: side, start: start, end: end,
            startHash: startHash, endHash: endHash)
    }

    private func exactLines(
        in available: [DiffLine], side: AnchorSide, start: Int, end: Int,
        startHash: SHA256Digest?, endHash: SHA256Digest?
    ) -> [DiffLine]? {
        guard start > 0, end >= start, end - start <= RTCConstants.maxPatchBytesPerFile else { return nil }
        let candidates = available.filter { line in
            guard let number = side == .new ? line.newLine : line.oldLine else { return false }
            return number >= start && number <= end
        }
        let numbers = candidates.compactMap { side == .new ? $0.newLine : $0.oldLine }
        guard numbers == Array(start...end), let first = candidates.first, let last = candidates.last else {
            return nil
        }
        if let startHash, first.contextHash != startHash { return nil }
        if let endHash, last.contextHash != endHash { return nil }
        return candidates
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
    func resolve(_ references: [DiffSliceReference], revision: RevisionIdentity) async throws -> [ResolvedDiffSlice]
    func layout(_ diagram: DiagramDocument) throws -> DiagramLayout
}

extension TourArtifactResolving {
    public func resolve(_ references: [DiffSliceReference], revision: RevisionIdentity) async throws
        -> [ResolvedDiffSlice]
    {
        var result: [ResolvedDiffSlice] = []
        for reference in references { result.append(try await resolve(reference, revision: revision)) }
        return result
    }
}

/// Resolves tour blocks exclusively from the immutable manifest already stored
/// for a review. Rendering therefore remains available when the repository is
/// missing or its symbolic refs have moved, and never consults the working tree.
public struct ManifestTourArtifactResolver: TourArtifactResolving, Sendable {
    public let manifest: ReviewManifest
    private let syntax: any SyntaxHighlighter

    public init(manifest: ReviewManifest, syntax: any SyntaxHighlighter = RTCSyntaxHighlighter()) {
        self.manifest = manifest
        self.syntax = syntax
    }

    public func manifest(for revision: RevisionIdentity) async throws -> ReviewManifest {
        guard manifest.revision == revision, manifest.id == revision.reviewID else {
            throw TourIntegrationError.revisionMismatch
        }
        return manifest
    }

    public func resolve(
        _ reference: DiffSliceReference, revision: RevisionIdentity
    ) async throws -> ResolvedDiffSlice {
        _ = try await manifest(for: revision)
        let source = ManifestTourArtifactSource(manifest: manifest)
        let anchor = try ReviewAnchor(
            revision: revision, path: reference.path, scope: .hunk,
            side: reference.side, startLine: reference.startLine, endLine: reference.endLine,
            startContextHash: reference.startContextHash,
            endContextHash: reference.endContextHash, hunkIndex: reference.hunkIndex)
        guard try await source.validate(anchor), let lines = source.exactLines(for: reference) else {
            throw TourIntegrationError.invalidPayload
        }
        let sourceText = lines.map(\.text).joined(separator: "\n")
        let digest = SHA256Digest(data: Data(sourceText.utf8))
        let spans = (try? await syntax.highlight(
            path: reference.path, fileDigest: digest, source: sourceText,
            language: nil, lines: nil)) ?? []
        return ResolvedDiffSlice(reference: reference, lines: lines, syntaxSpans: spans)
    }

    public func layout(_ diagram: DiagramDocument) throws -> DiagramLayout {
        try DiagramLayoutEngine.layout(DiagramValidator.validate(diagram))
    }
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
        return try await resolve(reference, manifest: manifest)
    }

    public func resolve(_ references: [DiffSliceReference], revision: RevisionIdentity) async throws
        -> [ResolvedDiffSlice]
    {
        let manifest = try await manifest(for: revision)
        var result: [ResolvedDiffSlice] = []
        for reference in references { result.append(try await resolve(reference, manifest: manifest)) }
        return result
    }

    private func resolve(_ reference: DiffSliceReference, manifest: ReviewManifest) async throws -> ResolvedDiffSlice {
        let revision = manifest.revision
        let source = ManifestTourArtifactSource(manifest: manifest)
        let anchor = try ReviewAnchor(
            revision: revision, path: reference.path, scope: .hunk,
            side: reference.side,
            startLine: reference.startLine, endLine: reference.endLine,
            startContextHash: reference.startContextHash,
            endContextHash: reference.endContextHash,
            hunkIndex: reference.hunkIndex)
        guard try await source.validate(anchor),
            let file = manifest.files.first(where: {
                reference.side == .new
                    ? $0.path == reference.path : ($0.oldPath == reference.path || $0.path == reference.path)
            }), let lines = source.exactLines(for: reference)
        else {
            throw TourIntegrationError.invalidPayload
        }
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
