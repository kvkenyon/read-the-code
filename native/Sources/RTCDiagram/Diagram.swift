import Foundation
import CoreGraphics
import RTCContracts

public enum DiagramValidationError: Error, Equatable, Sendable {
    case emptyGraph
    case limitExceeded
    case duplicateID(String)
    case missingNode(String)
    case invalidGroup(String)
    case invalidEdge(String)
    case invalidLabel(String)
    case tooManyAnchors
}

public struct ValidatedDiagram: Hashable, Sendable {
    public let document: DiagramDocument
    public let nodeIDs: [String]
    public let edgeIDs: [String]

    public init(document: DiagramDocument) throws {
        guard !document.nodes.isEmpty else { throw DiagramValidationError.emptyGraph }
        guard document.nodes.count <= RTCConstants.maxNodes,
              document.edges.count <= RTCConstants.maxEdges,
              document.groups.count <= RTCConstants.maxNodes else { throw DiagramValidationError.limitExceeded }
        var nodeIDs = Set<String>()
        for node in document.nodes {
            let id = node.id.value
            guard nodeIDs.insert(id).inserted else { throw DiagramValidationError.duplicateID(id) }
            guard id.count <= RTCConstants.maxLabelCharacters, node.label.value.count <= RTCConstants.maxLabelCharacters else { throw DiagramValidationError.invalidLabel(id) }
        }
        var edgeIDs = Set<String>()
        var totalAnchors = document.anchors.count
        for node in document.nodes { totalAnchors += node.anchors.count }
        for edge in document.edges {
            let edgeID = "\(edge.from.value)->\(edge.to.value)#\(edge.role.rawValue)"
            guard edgeIDs.insert(edgeID).inserted else { throw DiagramValidationError.duplicateID(edgeID) }
            guard nodeIDs.contains(edge.from.value) else { throw DiagramValidationError.missingNode(edge.from.value) }
            guard nodeIDs.contains(edge.to.value) else { throw DiagramValidationError.missingNode(edge.to.value) }
            if let label = edge.label, label.value.count > RTCConstants.maxLabelCharacters { throw DiagramValidationError.invalidLabel(edgeID) }
            totalAnchors += edge.anchors.count
        }
        guard totalAnchors <= RTCConstants.maxAnchors else { throw DiagramValidationError.tooManyAnchors }
        var groups = Set<String>()
        let nodeSet = nodeIDs
        for group in document.groups {
            guard groups.insert(group.id.value).inserted else { throw DiagramValidationError.duplicateID(group.id.value) }
            guard group.id.value.count <= RTCConstants.maxLabelCharacters,
                  group.label.value.count <= RTCConstants.maxLabelCharacters,
                  group.nodeIDs.count <= RTCConstants.maxNodes else { throw DiagramValidationError.invalidLabel(group.id.value) }
            var members = Set<String>()
            for nodeID in group.nodeIDs {
                guard nodeSet.contains(nodeID.value), members.insert(nodeID.value).inserted else { throw DiagramValidationError.invalidGroup(group.id.value) }
            }
        }
        // Yes/no edges are meaningful only from a decision node and may not repeat.
        let roles = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id.value, $0.role) })
        var decisionLabels: [String: Set<EdgeRole>] = [:]
        for edge in document.edges where edge.role == .yes || edge.role == .no {
            guard roles[edge.from.value] == .decision else { throw DiagramValidationError.invalidEdge(edge.from.value) }
            guard decisionLabels[edge.from.value, default: []].insert(edge.role).inserted else { throw DiagramValidationError.invalidEdge(edge.from.value) }
        }
        self.document = document
        self.nodeIDs = document.nodes.map { $0.id.value }.sorted()
        self.edgeIDs = edgeIDs.sorted()
    }
}

public enum DiagramValidator {
    public static func validate(_ document: DiagramDocument) throws -> ValidatedDiagram { try ValidatedDiagram(document: document) }
}

public struct DiagramLayoutNode: Hashable, Sendable {
    public let id: String
    public let frame: CGRect
    public let rank: Int
}

public struct DiagramLayoutEdge: Hashable, Sendable {
    public let from: String
    public let to: String
    public let points: [CGPoint]
}

public struct DiagramLayoutGroup: Hashable, Sendable {
    public let id: String
    public let frame: CGRect
}

public struct DiagramLayout: Hashable, Sendable {
    public let nodes: [DiagramLayoutNode]
    public let edges: [DiagramLayoutEdge]
    public let groups: [DiagramLayoutGroup]
    public let size: CGSize
    public let digest: SHA256Digest
    public let textualFallback: String?

    public init(nodes: [DiagramLayoutNode], edges: [DiagramLayoutEdge], groups: [DiagramLayoutGroup], size: CGSize, textualFallback: String? = nil) throws {
        self.nodes = nodes; self.edges = edges; self.groups = groups; self.size = size; self.textualFallback = textualFallback
        let stable = nodes.map { "\($0.id):\($0.rank):\($0.frame.origin.x),\($0.frame.origin.y),\($0.frame.width),\($0.frame.height)" }.joined(separator: "|")
        self.digest = SHA256Digest(data: Data(stable.utf8))
    }
}

public enum DiagramLayoutEngine {
    public static func layout(_ diagram: ValidatedDiagram, maxMilliseconds: Int = 100) throws -> DiagramLayout {
        let start = DispatchTime.now().uptimeNanoseconds
        let doc = diagram.document
        let ids = doc.nodes.map { $0.id.value }.sorted()
        let outgoing = Dictionary(grouping: doc.edges, by: { $0.from.value })
        var ranks = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0) })
        // Bounded relaxation is deterministic and also terminates for cycles.
        for _ in 0..<ids.count {
            var changed = false
            for id in ids {
                for edge in (outgoing[id] ?? []).sorted(by: { ($0.to.value, $0.role.rawValue) < ($1.to.value, $1.role.rawValue) }) {
                    let next = min(ids.count - 1, (ranks[id] ?? 0) + 1)
                    if next > (ranks[edge.to.value] ?? 0) { ranks[edge.to.value] = next; changed = true }
                }
            }
            if !changed { break }
            if DispatchTime.now().uptimeNanoseconds - start > UInt64(maxMilliseconds) * 1_000_000 { throw DiagramValidationError.limitExceeded }
        }
        let width: CGFloat = 180, height: CGFloat = 64, xGap: CGFloat = 48, yGap: CGFloat = 36
        let grouped = Dictionary(grouping: ids, by: { ranks[$0] ?? 0 })
        let maxColumn = grouped.values.map(\.count).max() ?? 1
        var positions: [String: CGRect] = [:]
        for rank in grouped.keys.sorted() {
            for (column, id) in grouped[rank]!.sorted().enumerated() {
                positions[id] = CGRect(x: CGFloat(rank) * (width + xGap), y: CGFloat(column) * (height + yGap), width: width, height: height)
            }
        }
        let layoutNodes = ids.compactMap { id in positions[id].map { DiagramLayoutNode(id: id, frame: $0, rank: ranks[id] ?? 0) } }
        let layoutEdges = doc.edges.sorted { ($0.from.value, $0.to.value, $0.role.rawValue) < ($1.from.value, $1.to.value, $1.role.rawValue) }.compactMap { edge -> DiagramLayoutEdge? in
            guard let a = positions[edge.from.value], let b = positions[edge.to.value] else { return nil }
            return DiagramLayoutEdge(from: edge.from.value, to: edge.to.value, points: [CGPoint(x: a.midX, y: a.midY), CGPoint(x: b.midX, y: b.midY)])
        }
        let groups = doc.groups.sorted { $0.id.value < $1.id.value }.compactMap { group -> DiagramLayoutGroup? in
            let frames = group.nodeIDs.compactMap { positions[$0.value] }; guard let first = frames.first else { return nil }
            return DiagramLayoutGroup(id: group.id.value, frame: frames.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -20, dy: -24))
        }
        let size = CGSize(width: CGFloat(max(1, (ranks.values.max() ?? 0) + 1)) * (width + xGap) - xGap, height: CGFloat(maxColumn) * (height + yGap) - yGap)
        let fallback = "Diagram \(doc.title.value): \(ids.joined(separator: ", "))"
        return try DiagramLayout(nodes: layoutNodes, edges: layoutEdges, groups: groups, size: size, textualFallback: fallback)
    }
}
