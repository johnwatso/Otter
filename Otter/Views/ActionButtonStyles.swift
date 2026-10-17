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

    /// A standard bordered button for use inside a Form, where the system
    /// controls (not Liquid Glass) are what people expect.
    func settingsActionButton() -> some View {
        self
            .labelStyle(.titleAndIcon)
            .buttonStyle(.bordered)
    }
}

private struct TahoePrimaryActionButtonModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .labelStyle(.titleAndIcon)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        } else {
            content
                .labelStyle(.titleAndIcon)
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
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        } else {
            content
                .labelStyle(.titleAndIcon)
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
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        } else {
            content
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
    }
}
