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
            if docker.hasLoadedContainers, docker.containerFailure == nil {
                Text("\(docker.containers.count) running")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await docker.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
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
                    ("Containers  \(docker.containers.count)", .containers),
                    ("Images  \(docker.images.count)", .images),
                    ("Networks  \(docker.networks.count)", .networks),
                    ("Volumes  \(docker.volumes.count)", .volumes)
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
            containerList
        case .images:
            imageList
        case .networks:
            networkList
        case .volumes:
            volumeList
        }
    }

    @ViewBuilder private var containerList: some View {
        if let failure = docker.containerFailure {
            message(icon: "exclamationmark.triangle", title: "Could not load containers", detail: failure)
        } else if docker.containers.isEmpty {
            message(icon: "shippingbox", title: docker.hasLoadedContainers ? "No containers are running" : "Looking for containers",
                    detail: docker.hasLoadedContainers ? "Running containers will appear here." : "")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(containerGroups) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            containerGroupHeader(group)
                            ForEach(group.containers) { container in
                                ContainerRow(container: container,
                                             stopping: docker.stopping.contains(container.id)) {
                                    Task {
                                        if let failure = await docker.stop([container]) {
                                            showFailure(title: "Could not stop \"\(container.name)\"",
                                                        message: failure)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder private var imageList: some View {
        if let failure = docker.imageFailure {
            message(icon: "exclamationmark.triangle", title: "Could not load images", detail: failure)
        } else if docker.images.isEmpty {
            message(icon: "shippingbox", title: docker.hasLoadedImages ? "No images found" : "Looking for images",
                    detail: docker.hasLoadedImages ? "Pulled and built images will appear here." : "")
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(docker.images) { image in
                        ImageRow(image: image,
                                 deleting: docker.deletingImages.contains(image.id)) {
                            confirmDelete(image)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder private var networkList: some View {
        if let failure = docker.networkFailure {
            message(icon: "exclamationmark.triangle", title: "Could not load networks", detail: failure)
        } else if docker.networks.isEmpty {
            message(icon: "network", title: docker.hasLoadedNetworks ? "No networks found" : "Looking for networks",
                    detail: docker.hasLoadedNetworks ? "Docker networks will appear here." : "")
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(docker.networks) { network in
                        NetworkRow(network: network,
                                   deleting: docker.deletingNetworks.contains(network.id)) {
                            confirmDelete(network)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder private var volumeList: some View {
        if let failure = docker.volumeFailure {
            message(icon: "exclamationmark.triangle", title: "Could not load volumes", detail: failure)
        } else if docker.volumes.isEmpty {
            message(icon: "externaldrive", title: docker.hasLoadedVolumes ? "No volumes found" : "Looking for volumes",
                    detail: docker.hasLoadedVolumes ? "Docker volumes will appear here." : "")
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(docker.volumes) { volume in
                        VolumeRow(volume: volume,
                                  deleting: docker.deletingVolumes.contains(volume.id)) {
                            confirmDelete(volume)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private var containerGroups: [ContainerGroup] {
        Dictionary(grouping: docker.containers, by: \.composeProject)
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
        let stopping = group.containers.contains { docker.stopping.contains($0.id) }
        return HStack(spacing: 8) {
            SectionDot(size: 5)
            Text(group.composeProject ?? "Standalone containers")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(group.containers.count) running")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            if let project = group.composeProject {
                DockerBadge(text: "COMPOSE")
                Button {
                    Task {
                        if let failure = await docker.stop(group.containers) {
                            showFailure(title: "Could not stop \"\(project)\"",
                                        message: failure)
                        }
                    }
                } label: {
                    Text(stopping ? "Stopping…" : "Stop compose")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(stopping ? Color.secondary : Theme.deletion)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(stopping)
                .appTooltip("Stop every running container in this compose project")
            }
        }
        .padding(.horizontal, 2)
    }

    private func confirmDelete(_ image: DockerImage) {
        dialogs.show(Dialog(
            title: "Delete \"\(image.reference)\"?",
            message: "Docker will remove this image. An image used by a container cannot be deleted.",
            actions: [
                .init(label: "Delete image", kind: .destructive) {
                    Task {
                        if let failure = await docker.delete(image) {
                            showFailure(title: "Could not delete image", message: failure)
                        }
                    }
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    private func confirmDelete(_ network: DockerNetwork) {
        dialogs.show(Dialog(
            title: "Delete \"\(network.name)\"?",
            message: "Docker will remove this network. A network connected to a container cannot be deleted.",
            actions: [
                .init(label: "Delete network", kind: .destructive) {
                    Task {
                        if let failure = await docker.delete(network) {
                            showFailure(title: "Could not delete network", message: failure)
                        }
                    }
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    private func confirmDelete(_ volume: DockerVolume) {
        dialogs.show(Dialog(
            title: "Delete \"\(volume.id)\"?",
            message: "All data in this volume will be lost. A volume used by a container cannot be deleted.",
            actions: [
                .init(label: "Delete volume", kind: .destructive) {
                    Task {
                        if let failure = await docker.delete(volume) {
                            showFailure(title: "Could not delete volume", message: failure)
                        }
                    }
                },
                .init(label: "Cancel", kind: .cancel)
            ]))
    }

    private func showFailure(title: String, message: String) {
        dialogs.show(Dialog(
            title: title,
            message: message,
            actions: [.init(label: "OK", kind: .cancel)]))
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        PaneMessage(icon: icon, title: title, detail: detail, mono: title.hasPrefix("Could not"))
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

                Button(action: onStop) {
                    Text(stopping ? "Stopping…" : "Stop")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(stopping ? Color.secondary : Theme.deletion)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(stopping)
            }
        }
    }
}

private struct ImageRow: View {
    let image: DockerImage
    let deleting: Bool
    let onDelete: () -> Void

    private var usage: String? {
        guard !image.containers.isEmpty, image.containers != "N/A" else { return nil }
        return image.containers == "1" ? "1 container" : "\(image.containers) containers"
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

                DockerDeleteButton(deleting: deleting, resource: "image", action: onDelete)
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

                DockerDeleteButton(deleting: deleting, resource: "network", action: onDelete)
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

                DockerDeleteButton(deleting: deleting, resource: "volume", action: onDelete)
            }
        }
    }
}

private struct DockerDeleteButton: View {
    let deleting: Bool
    let resource: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(deleting ? "Deleting…" : "Delete")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(deleting ? Color.secondary : Theme.deletion)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(deleting)
        .appTooltip("Delete this Docker \(resource)")
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
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Theme.field : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
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
