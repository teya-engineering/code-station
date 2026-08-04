import SwiftUI

// The containers a session left behind are easy to forget about, so they get their own
// sheet with a way to stop them without leaving the app.
struct DockerView: View {
    @Environment(DockerService.self) private var docker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            list
        }
        .frame(width: 560, height: 520)
        .background(Theme.background)
        // A container can start or stop from anywhere, so the list keeps looking while
        // the sheet is open rather than going stale until the refresh button is hit.
        .task {
            while !Task.isCancelled {
                await docker.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Docker").font(.serif(16))
            if !docker.containers.isEmpty {
                Text("\(docker.containers.count) running")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await docker.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh")

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.88)))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var list: some View {
        if let failure = docker.failure {
            note(failure, colour: Theme.deletion)
        } else if docker.containers.isEmpty {
            note(docker.hasLoaded ? "No containers are running." : "Looking for containers…",
                 colour: .secondary)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(docker.containers) { container in
                        ContainerRow(container: container,
                                     stopping: docker.stopping.contains(container.id)) {
                            Task { await docker.stop(container) }
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private func note(_ text: String, colour: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(20)
    }
}

private struct ContainerRow: View {
    let container: DockerContainer
    let stopping: Bool
    let onStop: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.dotOn).frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(container.image)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !container.publishedPorts.isEmpty {
                        Text("· \(container.publishedPorts)")
                    }
                }
                .font(.mono(10))
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(container.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button(action: onStop) {
                Text(stopping ? "Stopping…" : "Stop")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(stopping ? Color.secondary : Theme.deletion)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            }
            .buttonStyle(.plain)
            .disabled(stopping)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Theme.field : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .onHover { hovering = $0 }
    }
}
