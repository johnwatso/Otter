import SwiftUI

extension View {
    func tahoePrimaryActionButton() -> some View {
        modifier(TahoePrimaryActionButtonModifier())
    }

    func tahoeSecondaryActionButton() -> some View {
        modifier(TahoeSecondaryActionButtonModifier())
    }

    func tahoeCompactActionButton() -> some View {
        modifier(TahoeCompactActionButtonModifier())
    }
}

private struct TahoePrimaryActionButtonModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        } else {
            content
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        }
    }
}

private struct TahoeSecondaryActionButtonModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        } else {
            content
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        }
    }
}

private struct TahoeCompactActionButtonModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        } else {
            content
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
    }
}
