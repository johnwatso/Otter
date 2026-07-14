import SwiftUI

extension View {
    func tahoePrimaryActionButton() -> some View {
        self
            .labelStyle(.titleAndIcon)
            .font(.callout.weight(.medium))
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
    }

    func tahoeSecondaryActionButton() -> some View {
        self
            .labelStyle(.titleAndIcon)
            .font(.callout.weight(.medium))
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
    }

    func tahoeCompactActionButton() -> some View {
        self
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
    }
}
