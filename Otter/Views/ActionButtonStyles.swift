import SwiftUI

extension View {
    func tahoePrimaryActionButton() -> some View {
        modifier(TahoePrimaryActionButtonModifier())
    }

    func tahoeSecondaryActionButton() -> some View {
        modifier(TahoeSecondaryActionButtonModifier())
    }

    /// Styles a `Menu` to sit beside `tahoeSecondaryActionButton` buttons. A
    /// menu ignores the glass button style, so on macOS 26 it draws its own
    /// glass capsule at the same height.
    func tahoeSecondaryMenu() -> some View {
        modifier(TahoeSecondaryMenuModifier())
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

private struct TahoeSecondaryMenuModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .menuStyle(.borderlessButton)
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        }
    }
}
