import SwiftUI

// The desktop side of mobile access: the button that hands out a code, the badge that
// says how many are out, and the sheet that shows one.

// The QR button as a header wears it. The same control sits on a session, on a project and
// on Home; what changes is how far the code it makes can reach.
struct MobileAccessButton: View {
    let scope: MobileScope

    @Environment(MobileAccessController.self) private var mobileAccess
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(ProjectStore.self) private var store

    var body: some View {
        let share = mobileAccess.share(for: scope)
        let connected = mobileAccess.isLive(scope)
        let tint = if connected {
            Theme.addition
        } else if share != nil {
            Theme.accent
        } else {
            Color.secondary
        }
        return GlyphButton(icon: "qrcode", tint: tint, action: open)
            .appTooltip(tooltip(shared: share != nil, connected: connected))
            .accessibilityLabel(tooltip(shared: share != nil, connected: connected))
    }

    private func tooltip(shared: Bool, connected: Bool) -> String {
        if connected { return "Phone connected" }
        if shared { return "Shared with a phone" }
        return switch scope {
        case .session: "Open this session on a phone"
        case .project: "Open this project on a phone"
        case .everything: "Open Code Station on a phone"
        }
    }

    private func open() {
        dialogs.show(Dialog(
            title: title,
            message: """
            \(reach)

            No phone can connect until you start sharing below. Sharing continues after this dialog closes. Reopen it to cancel or stop sharing.
            """,
            content: AnyView(MobilePairingView(scope: scope)),
            actions: [.init(label: "Done", kind: .primary)],
            width: 390))
    }

    private var title: String {
        switch scope {
        case .session: "Open this session on your phone"
        case .project(let id): "Open \(store.project(id)?.name ?? "this project") on your phone"
        case .everything: "Open Code Station on your phone"
        }
    }

    // What the code lets the phone do, said plainly, because it is the whole difference
    // between the three codes.
    private var reach: String {
        switch scope {
        case .session:
            "A phone on the same trusted Wi-Fi can read this one session, send prompts, stop turns and answer requests. It can reach nothing else."
        case .project(let id):
            "A phone on the same trusted Wi-Fi can read any session in \(store.project(id)?.name ?? "this project"), start new ones there, send prompts, stop turns and answer requests."
        case .everything:
            "A phone on the same trusted Wi-Fi can read any session in any project, start new ones anywhere, send prompts, stop turns and answer requests."
        }
    }
}

// Every code that is out, wherever it was made. The three buttons that hand out access sit
// on the session, the project and Home, so without this there is no one place that says
// what a phone can reach or takes it back.
struct MobileAccessBadge: View {
    @Environment(MobileAccessController.self) private var mobileAccess

    var body: some View {
        let shares = mobileAccess.activeShares
        if !shares.isEmpty {
            let connected = shares.count(where: \.isConnected)
            let tint = connected > 0 ? Theme.addition : Theme.accent
            HStack(spacing: 5) {
                Image(systemName: connected > 0
                        ? "iphone.radiowaves.left.and.right" : "iphone")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(shares.count)")
                    .font(.mono(9.5, .semibold))
                    .kerning(0.7)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.1)))
            .appMenu { menu(shares) }
            .appTooltip(connected > 0
                        ? "\(connected) of \(shares.count) shared with a connected phone"
                        : "Shared with a phone")
            .accessibilityLabel("Mobile access")
        }
    }

    private func menu(_ shares: [MobileShareSummary]) -> [MenuEntry] {
        var entries: [MenuEntry] = shares.map { share in
            .item(share.name,
                  icon: share.isConnected
                      ? "iphone.radiowaves.left.and.right" : "iphone",
                  subtitle: "\(share.state) · \(share.reach)",
                  detail: "Revoke",
                  detailColour: Theme.deletion,
                  detailAction: {
                      mobileAccess.revoke(share.scope)
                  })
        }
        if shares.count > 1 {
            entries.append(.separator)
            entries.append(.item("Revoke all", kind: .destructive, icon: "xmark.circle") {
                mobileAccess.stop()
            })
        }
        return entries
    }
}

struct MobilePairingView: View {
    private enum ContentState: Equatable {
        case idle(hasFailure: Bool)
        case confirming
        case sharing
    }

    @Environment(MobileAccessController.self) private var mobileAccess
    let scope: MobileScope

    @State private var starting = false
    @State private var confirming = false
    @State private var failure: String?

    var body: some View {
        Group {
            if let share = mobileAccess.share(for: scope) {
                VStack(spacing: 14) {
                    if let image = MobilePairingQRCode.image(for: share.url) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 214, height: 214)
                            .padding(18)
                            .surface(.white, cornerRadius: 12)
                    }

                    HStack(spacing: 7) {
                        Circle()
                            .fill(mobileAccess.isLive(scope) ? Theme.addition : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(mobileAccess.isLive(scope)
                             ? "Phone connected" : "Waiting for the phone")
                            .font(.system(size: 12, weight: .semibold))
                    }

                    Text(share.url.absoluteString)
                        .font(.mono(9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)

                    ActionButton(title: share.isConnected ? "Stop sharing" : "Cancel sharing",
                                 tone: .danger, height: 38, size: 13, fills: true) {
                        mobileAccess.revoke(scope)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .transition(.fadeIn)
            } else if confirming {
                confirmation.transition(.fadeIn)
            } else {
                idle.transition(.fadeIn)
            }
        }
        .smoothlyResizes(when: contentState)
    }

    private var idle: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Sharing is off")
                    .font(.system(size: 13, weight: .semibold))
                Text("Start sharing to create a temporary QR code and allow one phone to connect.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.deletion)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.fadeIn)
            }

            ActionButton(title: starting ? "Starting…" : "Start sharing",
                         tone: .green, height: 38, size: 13, fills: true,
                         action: startSharing)
                .disabled(starting)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    // A code that can browse hands over more than the screen the button was pressed on, so
    // that reach is spelled out once more and has to be agreed to before the code exists.
    private var confirmation: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Theme.accent)

            VStack(spacing: 4) {
                Text("This code opens more than one session")
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(warning)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                ActionButton(title: "Back", tone: .outlined, height: 38, size: 13, fills: true) {
                    confirming = false
                }
                ActionButton(title: "Confirm", tone: .green, height: 38, size: 13, fills: true,
                             action: begin)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var warning: String {
        switch scope {
        case .project:
            "Whoever scans it can browse every session in this project, read what they say and start new ones that run on this Mac. Only scan it on a phone you trust."
        default:
            "Whoever scans it can browse every project, read any session and start new ones anywhere, all running on this Mac. Only scan it on a phone you trust."
        }
    }

    private var contentState: ContentState {
        if mobileAccess.share(for: scope) != nil { return .sharing }
        if confirming { return .confirming }
        return .idle(hasFailure: failure != nil)
    }

    private func startSharing() {
        guard !starting else { return }
        guard !scope.canBrowse else {
            failure = nil
            confirming = true
            return
        }
        begin()
    }

    private func begin() {
        guard !starting else { return }
        starting = true
        confirming = false
        failure = nil
        Task { @MainActor in
            defer { starting = false }
            do {
                _ = try await mobileAccess.startSharing(scope)
            } catch let error as LANServerFailure {
                failure = error.message
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
