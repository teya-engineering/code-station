import SwiftUI

enum FileReferenceMetrics {
    static let menuWidth: CGFloat = 256
    static let dialogWidth: CGFloat = 1080
    static let dialogHeight: CGFloat = 800
    static let readingWidth: CGFloat = 760
    static let outlineWidth: CGFloat = 200
    static let outlineBreakpoint: CGFloat = 800
    static let compactBreakpoint: CGFloat = 540
    static let chipWidth: CGFloat = 240
}

struct FileReferenceMark: View {
    var body: some View {
        Image(systemName: "doc.text")
            .font(Typography.body)
            .foregroundStyle(Theme.accent)
            .frame(width: ControlHeight.lg, height: ControlHeight.lg)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Radius.control))
            .accessibilityHidden(true)
    }
}

struct FileReferenceSubject: View {
    let path: String
    var showsPath = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text((path as NSString).lastPathComponent)
                .font(showsPath ? Typography.title : Typography.label)
                .lineLimit(1)
                .truncationMode(.middle)
            if showsPath {
                Text(path)
                    .font(Typography.data)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appTooltip(path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((path as NSString).lastPathComponent)
        .accessibilityValue(path)
    }
}

struct DocumentLoading: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(spacing: Space.md) {
                LoopSpinner(size: ControlHeight.xs)
                Text("Loading file").font(Typography.detail).foregroundStyle(.secondary)
            }
            RoundedRectangle(cornerRadius: Radius.tag).fill(Theme.field)
                .frame(height: ControlHeight.lg)
                .padding(.trailing, FileReferenceMetrics.outlineWidth)
            ForEach(0..<6) { index in
                RoundedRectangle(cornerRadius: Radius.tag).fill(Theme.field)
                    .frame(height: Typography.Size.detail)
                    .padding(.trailing, index.isMultiple(of: 3) ? Space.xxxl : 0)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.xxxl)
        .frame(maxWidth: FileReferenceMetrics.readingWidth, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading file")
    }
}
