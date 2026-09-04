import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import RTCContracts

public struct DiagramAccessibilityItem: Hashable, Sendable {
    public let id: String
    public let label: String
    public let role: NodeRole
    public let order: Int
}

public enum DiagramAccessibility {
    public static func items(for diagram: ValidatedDiagram) -> [DiagramAccessibilityItem] {
        diagram.document.nodes.sorted { $0.id.value < $1.id.value }.enumerated().map {
            DiagramAccessibilityItem(
                id: $0.element.id.value, label: $0.element.label.value, role: $0.element.role, order: $0.offset)
        }
    }
}

public protocol DiagramAnchorNavigation: Sendable {
    func select(anchor: ReviewAnchor) async
}

public struct DiagramAnchorSelection {
    public let anchors: [ReviewAnchor]
    public init(anchors: [ReviewAnchor]) { self.anchors = anchors }
}

public enum DiagramAnchorNavigator {
    public static func anchors(for nodeID: String, in diagram: ValidatedDiagram) -> DiagramAnchorSelection {
        let node = diagram.document.nodes.first { $0.id.value == nodeID }
        return DiagramAnchorSelection(anchors: node?.anchors ?? [])
    }
}

public enum DiagramRenderStyle: Sendable {
    case light, dark, highContrast
    fileprivate var background: CGColor {
        switch self {
        case .light: return CGColor(gray: 1, alpha: 1);
        case .dark: return CGColor(gray: 0.08, alpha: 1);
        case .highContrast: return CGColor(gray: 1, alpha: 1)
        }
    }
    fileprivate var foreground: CGColor {
        switch self {
        case .light: return CGColor(gray: 0.12, alpha: 1);
        case .dark: return CGColor(gray: 0.94, alpha: 1);
        case .highContrast: return CGColor(gray: 0, alpha: 1)
        }
    }
}

public enum DiagramExportError: Error, Equatable, Sendable { case couldNotCreateImage; case couldNotCreatePDF }

public enum DiagramExportRenderer {
    public static func png(_ layout: DiagramLayout, scale: CGFloat = 1, style: DiagramRenderStyle = .light) throws
        -> Data
    {
        let width = max(1, Int(ceil(layout.size.width * scale))), height = max(1, Int(ceil(layout.size.height * scale)))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw DiagramExportError.couldNotCreateImage }
        context.scaleBy(x: scale, y: scale)
        draw(layout, in: context, style: style)
        guard let image = context.makeImage() else { throw DiagramExportError.couldNotCreateImage }
        let data = NSMutableData();
        guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw DiagramExportError.couldNotCreateImage
        }
        CGImageDestinationAddImage(output, image, nil);
        guard CGImageDestinationFinalize(output) else { throw DiagramExportError.couldNotCreateImage }
        return data as Data
    }

    public static func pdf(_ layout: DiagramLayout, style: DiagramRenderStyle = .light) throws -> Data {
        let data = NSMutableData();
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw DiagramExportError.couldNotCreatePDF }
        let box = CGRect(origin: .zero, size: layout.size);
        context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary);
        draw(layout, in: context, style: style); context.endPDFPage(); context.closePDF(); return data as Data
    }

    fileprivate static func draw(_ layout: DiagramLayout, in context: CGContext, style: DiagramRenderStyle) {
        context.setFillColor(style.background); context.fill(CGRect(origin: .zero, size: layout.size))
        context.setStrokeColor(style.foreground); context.setFillColor(style.foreground);
        context.setLineWidth(
            {
                if case .highContrast = style { return 3.0 }; return 1.5
            }())
        for edge in layout.edges {
            context.move(to: edge.points[0]); for point in edge.points.dropFirst() { context.addLine(to: point) };
            context.strokePath()
        }
        for node in layout.nodes {
            context.setFillColor(style.background); context.fill(node.frame); context.setStrokeColor(style.foreground);
            context.stroke(node.frame)
        }
    }
}

public struct DiagramView: View {
    public let layout: DiagramLayout
    public let style: DiagramRenderStyle
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    public init(layout: DiagramLayout, style: DiagramRenderStyle = .light) { self.layout = layout; self.style = style }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    zoom = max(0.25, zoom - 0.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: [.command]).accessibilityLabel("Zoom out diagram")
                Button {
                    zoom = min(4, zoom + 0.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .keyboardShortcut("+", modifiers: [.command]).accessibilityLabel("Zoom in diagram")
                Button {
                    resetView()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .keyboardShortcut("0", modifiers: [.command]).accessibilityLabel("Fit and reset diagram")
                Button {
                    offset.width -= 24
                } label: {
                    Image(systemName: "arrow.left")
                }.accessibilityLabel("Pan diagram left")
                Button {
                    offset.width += 24
                } label: {
                    Image(systemName: "arrow.right")
                }.accessibilityLabel("Pan diagram right")
                Button {
                    offset.height -= 24
                } label: {
                    Image(systemName: "arrow.up")
                }.accessibilityLabel("Pan diagram up")
                Button {
                    offset.height += 24
                } label: {
                    Image(systemName: "arrow.down")
                }.accessibilityLabel("Pan diagram down")
            }.buttonStyle(.borderless)
            Canvas { context, size in
                let scale = zoom
                context.translateBy(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -layout.size.width / 2, y: -layout.size.height / 2)
                for group in layout.groups {
                    context.stroke(
                        Path(roundedRect: group.frame, cornerRadius: 10), with: .foreground,
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    context.draw(
                        Text(group.label).font(.caption).bold(),
                        at: CGPoint(x: group.frame.minX + 6, y: group.frame.minY + 8), anchor: .leading)
                }
                for edge in layout.edges {
                    var path = Path(); path.move(to: edge.points[0])
                    for point in edge.points.dropFirst() { path.addLine(to: point) }
                    context.stroke(path, with: .foreground, lineWidth: 1.5)
                    if let end = edge.points.last, let previous = edge.points.dropLast().last {
                        var arrow = Path(); let angle = atan2(end.y - previous.y, end.x - previous.x)
                        arrow.move(to: end)
                        arrow.addLine(to: CGPoint(x: end.x - 10 * cos(angle - 0.45), y: end.y - 10 * sin(angle - 0.45)))
                        arrow.addLine(to: CGPoint(x: end.x - 10 * cos(angle + 0.45), y: end.y - 10 * sin(angle + 0.45)))
                        arrow.closeSubpath(); context.fill(arrow, with: .foreground)
                    }
                    if let first = edge.points.first, let last = edge.points.last {
                        context.draw(
                            Text(edge.label ?? edge.role.rawValue).font(.caption2),
                            at: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2 - 8))
                    }
                }
                for node in layout.nodes {
                    context.fill(Path(roundedRect: node.frame, cornerRadius: 8), with: .color(.white.opacity(0.92)))
                    context.stroke(Path(roundedRect: node.frame, cornerRadius: 8), with: .foreground, lineWidth: 1.5)
                    context.draw(
                        Text(node.label).font(.body).bold(), at: CGPoint(x: node.frame.midX, y: node.frame.midY - 7))
                    context.draw(
                        Text(node.role.rawValue).font(.caption2),
                        at: CGPoint(x: node.frame.midX, y: node.frame.midY + 11))
                }
            }
            .gesture(
                MagnifyGesture().onChanged { zoom = min(4, max(0.25, $0.magnification)) }.simultaneously(
                    with: DragGesture().onChanged { offset = $0.translation }))
            if let fallback = layout.textualFallback {
                Text(fallback).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .focusable()
        .accessibilityRepresentation {
            VStack(alignment: .leading) {
                Text(layout.textualFallback ?? "Diagram")
                ForEach(Array(layout.nodes.enumerated()), id: \.element.id) { index, node in
                    Text("Node \(index + 1): \(node.label), \(node.role.rawValue)")
                }
                ForEach(Array(layout.edges.enumerated()), id: \.offset) { index, edge in
                    Text("Relationship \(index + 1): \(edge.from) \(edge.label ?? edge.role.rawValue) \(edge.to)")
                }
            }
        }
    }

    private func resetView() { zoom = 1; offset = .zero }
}
