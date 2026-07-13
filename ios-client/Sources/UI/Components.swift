import SwiftUI

struct K7Background: View {
    var body: some View {
        LinearGradient(
            colors: [Color(uiColor: .systemGroupedBackground), Color.indigo.opacity(0.06)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

struct K7Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

struct ConnectionHero: View {
    let phase: ConnectionPhase
    let detail: String?
    let retry: () -> Void

    private var color: Color {
        switch phase {
        case .online: return .green
        case .connecting, .authenticating, .reconnecting: return .orange
        case .failed: return .red
        case .unpaired: return .secondary
        }
    }

    private var symbol: String {
        switch phase {
        case .online: return "checkmark.circle.fill"
        case .connecting, .authenticating, .reconnecting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .unpaired: return "link.badge.plus"
        }
    }

    var body: some View {
        K7Card {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 56, height: 56)
                    .background(color.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text(phase.title).font(.title3.bold())
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                    } else {
                        Text(phase.isOnline ? "Kontrol kanalı kullanıma hazır" : "Eski iPhone'un hotspot ağına bağlanın")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if !phase.isOnline, phase != .unpaired {
                    Button(action: retry) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Yeniden bağlan")
                }
            }
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .indigo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct K7SectionTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title2.bold())
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Optional where Wrapped == Bool {
    var turkishStatus: String {
        switch self {
        case .some(true): return "Açık"
        case .some(false): return "Kapalı"
        case .none: return "Bilinmiyor"
        }
    }
}
