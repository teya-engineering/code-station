import SwiftUI

struct DockerView: View {
    @Environment(DockerService.self) private var docker
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.dismiss) private var dismiss

    private enum Tab: Hashable {
        case containers
        case images
        case networks
        case volumes
    }

    @State private var tab = Tab.containers

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            content
            SheetFooter { dismiss() }
        }
        .frame(width: 700, height: 620)
        .background(Theme.background)
        .task {
            await docker.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await docker.refreshContainers()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Docker").font(.serif(18))
            if docker.containers.hasLoaded, docker.containers.failure == nil {
                Text("\(docker.containers.items.count) running")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            GlyphButton(icon: "arrow.clockwise", tint: Theme.accent) {
                Task { await docker.refresh() }
            }
            .appTooltip("Refresh all Docker resources")
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    private var tabs: some View {
        HStack {
            HeaderTabToggle(
                selection: $tab,
                options: [
                    ("Containers  \(docker.containers.items.count)", .containers),
                    ("Images  \(docker.images.items.count)", .images),
                    ("Networks  \(docker.networks.items.count)", .networks),
                    ("Volumes  \(docker.volumes.items.count)", .volumes)
                ]
            )
            Spacer()
        }
        .padding(.horizontal, 20)
        .headerBand(Theme.card, height: Theme.subHeaderHeight)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .containers:
            resourceList(docker.containers, noun: "containers", icon: "shippingbox",
                         empty: "No containers are running",
                         hint: "Running containers will appear here.") {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(containerGroups) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            containerGroupHeader(group)
                            ForEach(group.containers) { container in
                                ContainerRow(container: container,
                                             stopping: docker.containers.busy.contains(container.id)) {
                                    stop([container], named: container.name)
                                }
                            }
                        }
                    }
                }
            }
        case .images:
            resourceList(docker.images, noun: "images", icon: "shippingbox",
                         empty: "No images found",
                         hint: "Pulled and built images will appear here.") {
                LazyVStack(spacing: 6) {
                    ForEach(docker.images.items) { image in
                        ImageRow(image: image, deleting: docker.images.busy.contains(image.id)) {
                            confirmDelete(kind: "image", name: image.reference,
                                          message: "Docker will remove this image. An image used by a container cannot be deleted.") {
                                await docker.delete(image)
                            }
                        }
                    }
                }
            }
        case .networks:
            resourceList(docker.networks, noun: "networks", icon: "network",
                         empty: "No networks found",
                         hint: "Docker networks will appear here.") {
                LazyVStack(spacing: 6) {
                    ForEach(docker.networks.items) { network in
                        NetworkRow(network: network, deleting: docker.networks.busy.contains(network.id)) {
                            confirmDelete(kind: "network", name: network.name,
                                          message: "Docker will remove this network. A network connected to a container cannot be deleted.") {
                                await docker.delete(network)
                            }
                        }
                    }
                }
            }
        case .volumes:
            resourceList(docker.volumes, noun: "volumes", icon: "externaldrive",
                         empty: "No volumes found",
                         hint: "Docker volumes will appear here.") {
                LazyVStack(spacing: 6) {
                    ForEach(docker.volumes.items) { volume in
                        VolumeRow(volume: volume, deleting: docker.volumes.busy.contains(volume.id)) {
                            confirmDelete(kind: "volume", name: volume.id,
                                          message: "All data in this volume will be lost. A volume used by a container cannot be deleted.") {
                                await docker.delete(volume)
                            }
                        }
                    }
                }
            }
        }
    }

    // What every tab shows around its rows: docker's complaint, the empty state, the
    // wait for the first answer, and only then the list.
    @ViewBuilder private func resourceList<Item, Rows: View>(
        _ resource: DockerService.Resource<Item>, noun: String, icon: String,
        empty: String, hint: String, @ViewBuilder rows: () -> Rows) -> some View {
        if let failure = resource.failure {
            PaneMessage(icon: "exclamationmark.triangle", title: "Could not load \(noun)",
                        detail: failure, mono: true)
        } else if resource.items.isEmpty {
            PaneMessage(icon: icon, title: resource.hasLoaded ? empty : "Looking for \(noun)",
                        detail: resource.hasLoaded ? hint : "")
        } else {
            ScrollView {
                rows().padding(20)
            }
        }
    }

    private var containerGroups: [ContainerGroup] {
        Dictionary(grouping: docker.containers.items, by: \.composeProject)
            .map { ContainerGroup(composeProject: $0.key, containers: $0.value) }
            .sorted {
                switch ($0.composeProject, $1.composeProject) {
                case let (left?, right?):
                    left.localizedStandardCompare(right) == .orderedAscending
                case (.some, .none):
                    true
                case (.none, .some):
                    false
                case (.none, .none):
                    false
                }
            }
    }

    private func containerGroupHeader(_ group: ContainerGroup) -> some View {
        let stopping = group.containers.contains { docker.containers.busy.contains($0.id) }
        return HStack(spacing: 8) {
            RunningDot(size: 5)
            Text(group.composeProject ?? "Standalone containers")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(group.containers.count) running")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            if let project = group.composeProject {
                DockerBadge(text: "COMPOSE")
                DockerRowButton(title: "Stop compose", busyTitle: "Stopping…", busy: stopping,
                                size: 9.5,
                                tooltip: "Stop every running container in this compose project") {
                    stop(group.containers, named: project)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private func stop(_ containers: [DockerContainer], named name: String) {
        Task {
            if let failure = await docker.stop(containers) {
                dialogs.show(.notice("Could not stop \"\(name)\"", message: failure))
            }
        }
    }

    // Docker's own complaint is shown once the question is answered, so a failed
    // removal says why rather than quietly leaving the row where it was.
    private func confirmDelete(kind: String, name: String, message: String,
                               action: @escaping () async -> String?) {
        dialogs.show(.confirm("Delete \"\(name)\"?", message: message, action: "Delete \(kind)") {
            Task {
                if let failure = await action() {
                    dialogs.show(.notice("Could not delete \(kind)", message: failure))
                }
            }
        })
    }
}

private struct ContainerGroup: Identifiable {
    let composeProject: String?
    let containers: [DockerContainer]

    var id: String { composeProject.map { "compose:\($0)" } ?? "standalone" }
}

private struct ContainerRow: View {
    let container: DockerContainer
    let stopping: Bool
    let onStop: () -> Void

    private var metadata: String {
        var details = ["ID \(container.shortID)"]
        if !container.publishedPorts.isEmpty { details.append("ports \(container.publishedPorts)") }
        if !container.networks.isEmpty { details.append("network \(container.networks)") }
        if !container.mounts.isEmpty { details.append("mounts \(container.mounts)") }
        if !container.size.isEmpty { details.append(container.size) }
        return details.joined(separator: "  ·  ")
    }

    var body: some View {
        DockerCard {
            HStack(spacing: 11) {
                Circle().fill(Theme.dotOn).frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(container.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let service = container.composeService {
                            DockerBadge(text: service)
                        }
                    }
                    Text(container.image)
                        .font(.mono(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(metadata)
                        .font(.mono(9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(container.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                DockerRowButton(title: "Stop", busyTitle: "Stopping…", busy: stopping,
                                tooltip: "Stop this container", action: onStop)
            }
        }
    }
}

private struct ImageRow: View {
    let image: DockerImage
    let deleting: Bool
    let onDelete: () -> Void

    // Docker says "N/A" when it has not counted, which is not worth a line.
    private var usage: String? {
        guard let count = Int(image.containers) else { return nil }
        return counted(count, "container")
    }

    var body: some View {
        DockerCard {
            HStack(spacing: 11) {
                resourceIcon("shippingbox.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text(image.reference)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("ID \(image.shortID)" + (image.createdSince.isEmpty ? "" : "  ·  created \(image.createdSince)"))
                        .font(.mono(9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    if !image.size.isEmpty {
                        Text(image.size).font(.system(size: 11, weight: .medium))
                    }
                    if let usage {
                        Text(usage)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                DockerRowButton(title: "Delete", busyTitle: "Deleting…", busy: deleting,
                                tooltip: "Delete this Docker image", action: onDelete)
            }
        }
    }
}

private struct NetworkRow: View {
    let network: DockerNetwork
    let deleting: Bool
    let onDelete: () -> Void

    private var metadata: String {
        [network.driver, network.scope, "ID \(network.shortID)"]
            .filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
    }

    var body: some View {
        DockerCard {
            HStack(spacing: 11) {
                resourceIcon("network")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(network.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let project = network.composeProject { DockerBadge(text: project) }
                        if network.isInternal { DockerBadge(text: "INTERNAL") }
                        if network.supportsIPv6 { DockerBadge(text: "IPV6") }
                    }
                    Text(metadata)
                        .font(.mono(9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if !network.created.isEmpty {
                        Text("Created \(network.created)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DockerRowButton(title: "Delete", busyTitle: "Deleting…", busy: deleting,
                                tooltip: "Delete this Docker network", action: onDelete)
            }
        }
    }
}

private struct VolumeRow: View {
    let volume: DockerVolume
    let deleting: Bool
    let onDelete: () -> Void

    private var metadata: String {
        var details = [volume.driver, volume.scope].filter { !$0.isEmpty }
        if !volume.size.isEmpty, volume.size != "N/A" { details.append(volume.size) }
        return details.joined(separator: "  ·  ")
    }

    var body: some View {
        DockerCard {
            HStack(spacing: 11) {
                resourceIcon("externaldrive.fill")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(volume.id)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let project = volume.composeProject { DockerBadge(text: project) }
                        if let name = volume.composeVolume { DockerBadge(text: name) }
                    }
                    if !volume.mountpoint.isEmpty {
                        Text(volume.mountpoint)
                            .font(.mono(9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !metadata.isEmpty {
                        Text(metadata)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DockerRowButton(title: "Delete", busyTitle: "Deleting…", busy: deleting,
                                tooltip: "Delete this Docker volume", action: onDelete)
            }
        }
    }
}

// The red action on a row: Stop for a container, Delete for anything else. While docker
// works on it the button goes quiet and says so. Its room scales with its type, so the
// smaller one in a group header keeps the same shape.
private struct DockerRowButton: View {
    let title: String
    let busyTitle: String
    let busy: Bool
    var size: CGFloat = 11
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(busy ? busyTitle : title)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(busy ? Color.secondary : Theme.deletion)
                .padding(.horizontal, size * 0.9)
                .padding(.vertical, size * 0.45)
                .surface(Theme.field, cornerRadius: size * 0.65)
                .contentShape(RoundedRectangle(cornerRadius: size * 0.65))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .appTooltip(tooltip)
    }
}

private struct DockerBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .kerning(0.3)
            .foregroundStyle(Theme.accent)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.accent.opacity(0.08)))
    }
}

private struct DockerCard<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .surface(hovering ? Theme.field : Theme.card, cornerRadius: 9)
            .onHover { hovering = $0 }
    }
}

private func resourceIcon(_ name: String) -> some View {
    Image(systemName: name)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.accent)
        .frame(width: 26, height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.08)))
}
