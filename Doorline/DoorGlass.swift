import SwiftUI

/// System Liquid Glass where the SDK declares it. Xcode 16.4 has no glass symbols, so that branch is not compiled there.
extension View {
    @ViewBuilder
    func doorGlass<S: Shape>(in shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }
}

struct DoorGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 16) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

struct DoorCommandButton: View {
    var title: String
    var systemImage: String
    var prominent = false
    var action: () -> Void

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, macOS 26.0, *) {
            if prominent {
                styled.buttonStyle(.glassProminent)
            } else {
                styled.buttonStyle(.glass)
            }
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    @ViewBuilder
    private var fallback: some View {
        if prominent {
            styled.buttonStyle(.borderedProminent)
        } else {
            styled.buttonStyle(.bordered)
        }
    }

    private var styled: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .controlSize(.large)
    }
}
