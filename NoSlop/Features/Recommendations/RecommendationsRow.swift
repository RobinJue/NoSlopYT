import NoSlopKit
import SwiftUI

/// The Library entry for YouTube recommendations: a Connect button while not connected, "Connected" and the account
/// name when connected. Meant to sit in a `List` section.
struct RecommendationsRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var flow = RecommendationsConnectFlow()

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))

        layout {
            let inner = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(spacing: 12))
            inner {
                Image(systemName: env.recommendationsAccount == nil ? "sparkles.tv" : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(env.recommendationsAccount == nil ? Theme.accent : Color.green)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("YouTube recommendations")
                        .font(.body)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if env.recommendationsAccount == nil {
                if !stacked { Spacer(minLength: 8) }
                Button {
                    Task { await flow.connect(using: env) }
                } label: {
                    if flow.isWorking {
                        ProgressView()
                    } else {
                        Text("Connect")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(flow.isWorking)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.vertical, 4)
        .recommendationsConnectPresentation(flow)
    }

    private var detail: String {
        guard let account = env.recommendationsAccount else { return "Connect to see your own YouTube Home here" }
        if let name = account.name, !name.isEmpty { return "Connected · \(name)" }
        return "Connected"
    }
}
