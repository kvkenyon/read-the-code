import AppKit
import SwiftUI

/// Semantic colors for the review instrument. Values are intentionally named by
/// meaning so feature modules never couple themselves to a palette.
public enum RTCColorToken: String, CaseIterable, Sendable {
    case canvas, surface, separator, textPrimary, textSecondary, selection
    case addition, additionBackground, deletion, deletionBackground, storySpine
}

public enum RTCDesign {
    public static let cornerRadius: CGFloat = 7
    public static let controlHeight: CGFloat = 28
    public static let standardSpacing: CGFloat = 12
    public static let compactSpacing: CGFloat = 6

    public static func color(_ token: RTCColorToken) -> Color {
        switch token {
        case .canvas: Color(nsColor: .windowBackgroundColor)
        case .surface: Color(nsColor: .controlBackgroundColor)
        case .separator: Color(nsColor: .separatorColor)
        case .textPrimary: Color(nsColor: .labelColor)
        case .textSecondary: Color(nsColor: .secondaryLabelColor)
        case .selection: Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        case .addition: Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedRed: 0.40, green: 0.88, blue: 0.60, alpha: 1) : NSColor(calibratedRed: 0.075, green: 0.478, blue: 0.27, alpha: 1)
        })
        case .additionBackground: Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedRed: 0.08, green: 0.23, blue: 0.14, alpha: 1) : NSColor(calibratedRed: 0.882, green: 0.953, blue: 0.91, alpha: 1)
        })
        case .deletion: Color(nsColor: .systemRed)
        case .deletionBackground: Color(nsColor: .systemRed.withAlphaComponent(0.12))
        case .storySpine: Color(red: 0.184, green: 0.49, blue: 0.447)
        }
    }

    public static let interfaceFont = Font.system(.body, design: .default)
    public static let codeFont = Font.system(.body, design: .monospaced)
    public static let badgeFont = Font.system(.caption2, design: .rounded).weight(.semibold)
}

public struct RTCButtonStyle: ButtonStyle {
    public var prominent = false
    public init(prominent: Bool = false) { self.prominent = prominent }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .medium))
            .padding(.horizontal, 10).frame(minHeight: RTCDesign.controlHeight)
            .background(prominent ? RTCDesign.color(.storySpine) : RTCDesign.color(.surface))
            .foregroundStyle(prominent ? Color.white : RTCDesign.color(.textPrimary))
            .clipShape(RoundedRectangle(cornerRadius: RTCDesign.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: RTCDesign.cornerRadius).stroke(RTCDesign.color(.separator), lineWidth: prominent ? 0 : 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

public struct RTCBadge: View {
    public enum Tone { case neutral, success, warning, danger }
    private let text: String
    private let tone: Tone
    public init(_ text: String, tone: Tone = .neutral) { self.text = text; self.tone = tone }
    public var body: some View {
        Text(text.uppercased()).font(RTCDesign.badgeFont).tracking(0.4)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .foregroundStyle(foreground).background(background)
            .clipShape(Capsule())
    }
    private var foreground: Color { switch tone { case .neutral: RTCDesign.color(.textSecondary); case .success: RTCDesign.color(.addition); case .warning: .orange; case .danger: RTCDesign.color(.deletion) } }
    private var background: Color { switch tone { case .neutral: RTCDesign.color(.selection); case .success: RTCDesign.color(.additionBackground); case .warning: .orange.opacity(0.14); case .danger: RTCDesign.color(.deletionBackground) } }
}

public struct RTCCard<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { content.padding(14).background(RTCDesign.color(.surface)).clipShape(RoundedRectangle(cornerRadius: RTCDesign.cornerRadius)).overlay(RoundedRectangle(cornerRadius: RTCDesign.cornerRadius).stroke(RTCDesign.color(.separator), lineWidth: 1)) }
}

public struct RTCEmptyState: View {
    public let title: String
    public let message: String
    public init(title: String, message: String) { self.title = title; self.message = message }
    public var body: some View { VStack(spacing: 8) { Image(systemName: "tray").font(.system(size: 24, weight: .light)).foregroundStyle(RTCDesign.color(.textSecondary)); Text(title).font(.headline); Text(message).font(.subheadline).foregroundStyle(RTCDesign.color(.textSecondary)).multilineTextAlignment(.center) }.frame(maxWidth: 280).padding(24) }
}

public struct RTCErrorState: View {
    public let title: String
    public let message: String
    public let retry: (() -> Void)?
    public init(title: String, message: String, retry: (() -> Void)? = nil) { self.title = title; self.message = message; self.retry = retry }
    public var body: some View { VStack(spacing: 10) { Image(systemName: "exclamationmark.triangle").foregroundStyle(RTCDesign.color(.deletion)); Text(title).font(.headline); Text(message).font(.subheadline).foregroundStyle(RTCDesign.color(.textSecondary)).multilineTextAlignment(.center); if let retry { Button("Try Again", action: retry).buttonStyle(RTCButtonStyle(prominent: true)) } }.frame(maxWidth: 300).padding(24) }
}
