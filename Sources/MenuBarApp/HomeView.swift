import SwiftUI

// The product home gives the logo a stable destination and explains why the surrounding
// tools belong together.
struct HomeView: View {
    private let highlights = [
        HomeHighlight(
            icon: "arrow.triangle.branch",
            title: "Work in parallel",
            detail: "Give each session an isolated Git worktree, or let it work directly in the project folder."),
        HomeHighlight(
            icon: "doc.text.magnifyingglass",
            title: "See everything that changed",
            detail: "Follow the conversation, tool activity, files, diffs, token use and terminal without losing context."),
        HomeHighlight(
            icon: "person.2.fill",
            title: "Use the right agent",
            detail: "Start each session with Codex or Claude Code and choose its model, reasoning and access settings."),
        HomeHighlight(
            icon: "wrench.and.screwdriver.fill",
            title: "Stay in flow",
            detail: "Answer permissions, manage Git, inspect Docker, send API requests and use MCP tools inside Conductor.")
    ]

    private let columns = [
        GridItem(.flexible(minimum: 250), spacing: 14),
        GridItem(.flexible(minimum: 250), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero

                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "WHY CONDUCTOR")
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(highlights) { highlight in
                                highlightCard(highlight)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "ALSO BUILT IN")
                        builtInTools
                    }
                }
                .padding(28)
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .background(Theme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Home")
                .font(.serif(22))
            Text("What Teya Conductor brings together")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 22) {
            AppMark()
                .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 12) {
                Text("Run the work. See the whole change.")
                    .font(.serif(30))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Use Codex and Claude Code across local projects while keeping conversations, files, Git and terminals together.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 650, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func highlightCard(_ highlight: HomeHighlight) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: highlight.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.accent.opacity(0.09)))

            VStack(alignment: .leading, spacing: 5) {
                Text(highlight.title)
                    .font(.serif(17))
                Text(highlight.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    private var builtInTools: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { toolChips }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    toolChip("Multi-project workspaces")
                    toolChip("MCP servers")
                    toolChip("Skills")
                }
                HStack(spacing: 8) {
                    toolChip("Docker")
                    toolChip("API requests")
                    toolChip("Shortcuts")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    @ViewBuilder private var toolChips: some View {
        toolChip("Multi-project workspaces")
        toolChip("MCP servers")
        toolChip("Skills")
        toolChip("Docker")
        toolChip("API requests")
        toolChip("Shortcuts")
    }

    private func toolChip(_ title: String) -> some View {
        HStack(spacing: 6) {
            SectionDot(size: 5)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
    }

}

private struct HomeHighlight: Identifiable {
    let icon: String
    let title: String
    let detail: String

    var id: String { title }
}
