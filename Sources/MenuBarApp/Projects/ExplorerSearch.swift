import AppKit
import SwiftUI

enum FileNameSearch {
    static let resultLimit = 200

    static func matches(_ query: String, in files: [FileNode], beneath root: String) -> [FileNode] {
        let query = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return [] }

        return files.compactMap { node -> (node: FileNode, rank: Int, path: String)? in
            let path = node.path.pathRelative(to: root) ?? node.path
            let name = normalized(node.name)
            let normalizedPath = normalized(path)
            let rank: Int
            if name == query {
                rank = 0
            } else if name.hasPrefix(query) {
                rank = 1
            } else if name.contains(query) {
                rank = 2
            } else if normalizedPath.contains(query) {
                rank = 3
            } else {
                return nil
            }
            return (node, rank, path)
        }
        .sorted { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            return left.path.localizedStandardCompare(right.path) == .orderedAscending
        }
        .prefix(resultLimit)
        .map(\.node)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

@MainActor
@Observable
final class ExplorerSearchModel {
    let root: String
    let includeHidden: Bool

    var query = "" {
        didSet { refreshMatches() }
    }
    private(set) var matches: [FileNode] = []
    private(set) var selectedIndex: Int?
    private(set) var loading = true

    private var files: [FileNode] = []

    init(root: String, includeHidden: Bool) {
        self.root = root
        self.includeHidden = includeHidden
    }

    var selected: FileNode? {
        guard let selectedIndex, matches.indices.contains(selectedIndex) else { return nil }
        return matches[selectedIndex]
    }

    func load() async {
        let files = await FileTree.files(
            beneath: URL(fileURLWithPath: root), includeHidden: includeHidden)
        guard !Task.isCancelled else { return }
        self.files = files
        loading = false
        refreshMatches()
    }

    func select(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        selectedIndex = index
    }

    func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = min(max((selectedIndex ?? 0) + offset, 0), matches.count - 1)
    }

    private func refreshMatches() {
        matches = FileNameSearch.matches(query, in: files, beneath: root)
        selectedIndex = matches.isEmpty ? nil : 0
    }
}

struct ShiftDoubleTapDetector {
    static let maximumInterval: TimeInterval = 0.5

    private var previousTap: TimeInterval?

    mutating func registerTap(at timestamp: TimeInterval) -> Bool {
        if let previousTap, timestamp - previousTap <= Self.maximumInterval {
            self.previousTap = nil
            return true
        }
        previousTap = timestamp
        return false
    }

    mutating func reset() {
        previousTap = nil
    }
}

struct ExplorerSearchShortcut: NSViewRepresentable {
    let onOpen: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.anchor = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.anchor = view
        context.coordinator.onOpen = onOpen
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var anchor: NSView?
        var onOpen: () -> Void

        private var detector = ShiftDoubleTapDetector()
        private var token: Any?

        init(onOpen: @escaping () -> Void) {
            self.onOpen = onOpen
        }

        func start() {
            guard token == nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
                let shouldOpen = MainActor.assumeIsolated { self.handle(event) }
                if shouldOpen {
                    DispatchQueue.main.async { self.onOpen() }
                }
                return event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === anchor?.window else {
                detector.reset()
                return false
            }
            guard event.type == .flagsChanged,
                  event.keyCode == 56 || event.keyCode == 60 else {
                detector.reset()
                return false
            }
            guard event.modifierFlags.contains(.shift) else { return false }
            return detector.registerTap(at: event.timestamp)
        }

        func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
            detector.reset()
        }
    }
}

struct ExplorerSearchDialog: View {
    private enum ResultsState: Equatable {
        case prompt
        case loading
        case empty
        case matches
    }

    @Bindable var model: ExplorerSearchModel
    let onOpen: (FileNode) -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Search files", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onMoveCommand { direction in
                        switch direction {
                        case .up: model.moveSelection(by: -1)
                        case .down: model.moveSelection(by: 1)
                        default: break
                        }
                    }
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))

            results
        }
        .smoothlyResizes(when: resultsState)
        .task {
            searchFocused = true
            await model.load()
        }
    }

    @ViewBuilder private var results: some View {
        if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchMessage("Start typing to find a file")
                .transition(.fadeIn)
        } else if model.loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading files...")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 180)
            .transition(.fadeIn)
        } else if model.matches.isEmpty {
            searchMessage("No matching files")
                .transition(.fadeIn)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.matches.enumerated()), id: \.element.path) { index, node in
                            resultRow(node, index: index)
                                .id(node.path)
                        }
                    }
                    .padding(5)
                }
                .frame(height: 240)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                .onChange(of: model.selectedIndex) {
                    if let path = model.selected?.path {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(path, anchor: .center)
                        }
                    }
                }
            }
            .transition(.fadeIn)
        }
    }

    private var resultsState: ResultsState {
        if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .prompt }
        if model.loading { return .loading }
        return model.matches.isEmpty ? .empty : .matches
    }

    private func resultRow(_ node: FileNode, index: Int) -> some View {
        let selected = model.selectedIndex == index
        let path = node.path.pathRelative(to: model.root) ?? node.path
        let directory = (path as NSString).deletingLastPathComponent

        return Button {
            model.select(index)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(node.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if directory != "." {
                    Text(directory)
                        .font(.mono(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Theme.card : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Theme.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(node) })
    }

    private func searchMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 180)
    }
}
