import MeshtasticCore
import MeshtasticProtobufs
import SwiftUI

/// Four-bar signal indicator.
struct SignalBars: View {
    let quality: SignalQuality
    var compact = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= quality.bars ? quality.color : Color.secondary.opacity(0.25))
                    .frame(width: compact ? 2.5 : 3,
                           height: (compact ? 4 : 5) + CGFloat(bar) * (compact ? 2 : 2.5))
            }
        }
        .accessibilityLabel("Signal: \(quality.label)")
    }
}

/// The two-to-four character short name every Meshtastic node carries.
struct NodeAvatar: View {
    let node: MeshNode
    var size: CGFloat = 34

    private var background: Color {
        // Derive a stable hue from the node number so nodes stay recognizable.
        let hue = Double(node.num % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }

    var body: some View {
        ZStack {
            Circle().fill(background.gradient)
            Text(node.shortName.prefix(4))
                .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .padding(2)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if node.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: size * 0.28))
                    .foregroundStyle(.yellow)
                    .background(Circle().fill(.background).padding(-1))
                    .offset(x: 2, y: 2)
            }
        }
    }
}

/// Battery pill used in node rows and the status bar.
struct BatteryIndicator: View {
    let node: MeshNode
    var showLabel = true

    var body: some View {
        if node.isPluggedIn {
            Label("Powered", systemImage: "powerplug.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .help("Running on external power")
        } else if let level = node.batteryLevel {
            HStack(spacing: 3) {
                Image(systemName: symbol(for: level))
                    .foregroundStyle(color(for: level))
                if showLabel {
                    Text("\(level)%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .help("Battery \(level)%")
        }
    }

    private func symbol(for level: Int) -> String {
        switch level {
        case ..<10: "battery.0percent"
        case ..<35: "battery.25percent"
        case ..<60: "battery.50percent"
        case ..<85: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private func color(for level: Int) -> Color {
        switch level {
        case ..<15: .red
        case ..<35: .orange
        default: .green
        }
    }
}

/// A labelled key/value row used throughout the detail panes.
struct DetailRow: View {
    let label: String
    let value: String
    var symbol: String?
    var isMonospaced = false

    init(_ label: String, _ value: String, symbol: String? = nil, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.symbol = symbol
        self.isMonospaced = monospaced
    }

    var body: some View {
        LabeledContent {
            Text(value)
                .font(isMonospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        } label: {
            if let symbol {
                Label(label, systemImage: symbol)
            } else {
                Text(label)
            }
        }
    }
}

/// Empty-state placeholder with a consistent look.
struct EmptyStateView: View {
    let title: String
    let message: String
    let symbol: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Shows the session's transient notices as dismissible banners.
struct NoticeBanner: View {
    @Environment(MeshSession.self) private var session

    var body: some View {
        if let notice = session.notices.last {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(notice.isError ? .orange : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title).font(.callout.weight(.medium))
                    if !notice.detail.isEmpty {
                        Text(notice.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    session.dismissNotice(notice.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(notice.id)
        }
    }
}

/// A form section that only submits when the user presses Save, so a stray
/// keystroke does not reboot a radio.
struct SaveBar: View {
    let isDirty: Bool
    let isBusy: Bool
    let save: () -> Void
    let revert: () -> Void

    var body: some View {
        HStack {
            if isDirty {
                Label("Unsaved changes", systemImage: "pencil.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert", action: revert)
                .disabled(!isDirty || isBusy)
            Button("Save to Radio", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty || isBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
