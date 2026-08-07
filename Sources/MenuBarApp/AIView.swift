import SwiftUI

// The local model server, with the one control that matters: start it or stop it.
// The output tail is here because a model that fails to load says why on stderr and
// nowhere else.
struct AIView: View {
    @Environment(AIService.self) private var ai
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            SheetFooter { dismiss() }
        }
        .frame(width: 560, height: 520)
        .background(Theme.background)
        // The server can start or die from a terminal too, so the sheet keeps probing
        // while it is open instead of trusting the last button press.
        .task {
            while !Task.isCancelled {
                await ai.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("AI").font(.serif(16))
            Text("Local model server")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            serverCard
            if case .failed(let message) = ai.state {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            output
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var serverCard: some View {
        HStack(spacing: 12) {
            Circle().fill(dotColour).frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(AIService.modelName)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    Text("llama-server · \(AIService.alias) · \(AIService.contextLength / 1024)k context")
                    if ai.state == .running || ai.state == .runningExternally {
                        Text("· \(AIService.endpoint)")
                    }
                }
                .font(.mono(10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .textSelection(.enabled)
                Text(statusLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            toggleButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }

    @ViewBuilder private var toggleButton: some View {
        if ai.state.isActive {
            Button {
                Task { await ai.stop() }
            } label: {
                Text("Stop")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.deletion)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        } else {
            Button {
                ai.start()
            } label: {
                Text("Start")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.88)))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OUTPUT")
                .font(.mono(10, .semibold))
                .kerning(0.5)
                .foregroundStyle(.tertiary)
            ScrollViewReader { scroller in
                ScrollView {
                    Text(ai.log.isEmpty ? "Nothing yet. Output appears once the server starts." : ai.log)
                        .font(.mono(10.5))
                        .foregroundStyle(ai.log.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .onChange(of: ai.log) { _, _ in
                    scroller.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        }
        .frame(maxHeight: .infinity)
    }

    private static let bottom = "bottom"

    private var dotColour: Color {
        switch ai.state {
        case .running, .runningExternally: Theme.dotOn
        case .starting: Theme.attention
        case .failed: Theme.deletion
        case .stopped: Theme.dotOff
        }
    }

    private var statusLabel: String {
        switch ai.state {
        case .stopped: "Not running"
        case .starting: "Loading model…"
        case .running: "Running on port \(AIService.port)"
        case .runningExternally: "Running on port \(AIService.port), started outside the app"
        case .failed: "Failed"
        }
    }
}
