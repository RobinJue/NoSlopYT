import SwiftUI

/// The app's mark at any size: a red gradient rounded square with a white play triangle and a small sparkle, the
/// same picture as the app icon (`scripts/make-icon.swift`). Decorative: VoiceOver skips it.
struct BrandMarkView: View {
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 1.0, green: 0.306, blue: 0.271), Color(red: 0.702, green: 0.071, blue: 0.102)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
                    // A triangle looks centred when its centre of mass, not its bounding box, is.
                    .offset(x: size * 0.025)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(size * 0.1)
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 16) {
        BrandMarkView(size: 24)
        BrandMarkView(size: 48)
        BrandMarkView(size: 96)
    }
    .padding()
}
