import AppKit
import SwiftUI

struct SpotlightPanelView: View {
    @ObservedObject var viewModel: ChatViewModel
    let close: () -> Void

    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("Ask anything...", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .regular))
                    .focused($isInputFocused)
                    .onSubmit {
                        viewModel.submit()
                    }
                    .onChange(of: viewModel.query) { _ in
                        viewModel.queryChanged()
                    }

                if viewModel.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                }

                if let availableUpdate = viewModel.availableUpdate {
                    Button {
                        viewModel.installUpdate()
                    } label: {
                        Label("Update \(availableUpdate.version)", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.isUpdating)
                    .help("Install SolarLight \(availableUpdate.version)")
                }

                Button {
                    viewModel.isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .help("Configure API")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider()

            GeometryReader { geometry in
                let showRail = geometry.size.width >= 820 && !viewModel.webCitations.isEmpty
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        AnswerView(
                            text: viewModel.response,
                            isPlaceholder: viewModel.response.isEmpty,
                            webCitations: viewModel.webCitations,
                            fileCitations: viewModel.fileCitations,
                            ragAnswer: viewModel.ragAnswer,
                            ragCitations: viewModel.ragCitations,
                            ragState: viewModel.ragState,
                            isSharing: viewModel.isSharing,
                            copy: { viewModel.copyResponse() },
                            share: { viewModel.shareResponse() }
                        )
                        if !showRail, !viewModel.webCitations.isEmpty {
                            ReferencesStrip(citations: viewModel.webCitations)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showRail {
                        Divider()
                        ReferencesRail(citations: viewModel.webCitations)
                            .frame(width: min(340, geometry.size.width * 0.34))
                            .frame(maxHeight: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Text(viewModel.status)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") {
                    close()
                }
                .keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        // Route file:// links through NSWorkspace explicitly. SwiftUI's default
        // OpenURLAction inside an AttributedString-backed Text doesn't reliably
        // open file URLs on macOS, so we intercept and dispatch ourselves.
        .environment(\.openURL, OpenURLAction { url in
            if url.isFileURL {
                NSWorkspace.shared.open(url)
                return .handled
            }
            return .systemAction
        })
        .onChange(of: viewModel.focusToken) { _ in
            DispatchQueue.main.async {
                isInputFocused = true
            }
        }
        .onExitCommand {
            close()
        }
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsView(
                settings: viewModel.settings,
                fileIndex: viewModel.fileIndex,
                indexNow: { viewModel.indexNow() },
                applyFileSearchSettings: {
                    Task { await viewModel.applyFileSearchSettings() }
                }
            )
            .onDisappear {
                viewModel.settings.save()
                viewModel.settingsDidClose()
            }
        }
    }
}

private struct AnswerView: View {
    let text: String
    let isPlaceholder: Bool
    let webCitations: [ChatCitation]
    let fileCitations: [ChatCitation]
    let ragAnswer: String
    let ragCitations: [ChatCitation]
    let ragState: ChatViewModel.RAGState
    let isSharing: Bool
    let copy: () -> Void
    let share: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                if isPlaceholder {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        MarkdownAnswer(
                            text: text,
                            mode: .web(web: webCitations, file: fileCitations)
                        )

                        if ragState != .idle {
                            RAGAnswerSection(
                                state: ragState,
                                text: ragAnswer,
                                // Same array drives both inline `[N]` → filename
                                // resolution and the "Based on" chip row, so
                                // numbers and chips always agree. Prefer API
                                // annotations; fall back to file-search matches
                                // when the model didn't emit annotations.
                                citations: ragCitations.isEmpty ? fileCitations : ragCitations
                            )
                            .padding(.top, 28)
                        }

                        if !fileCitations.isEmpty {
                            LocalFilesSection(citations: fileCitations)
                                .padding(.top, 24)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 56)
                    .padding(.bottom, 24)
                }
            }

            if !isPlaceholder {
                AnswerActionBar(
                    isSharing: isSharing,
                    copy: copy,
                    share: share
                )
                .padding(.trailing, 24)
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AnswerActionBar: View {
    let isSharing: Bool
    let copy: () -> Void
    let share: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                copy()
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help("Copy answer")

            Button {
                share()
            } label: {
                Group {
                    if isSharing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .help("Share temporary page")
            .disabled(isSharing)
        }
        .buttonStyle(.plain)
        .font(.system(size: 17, weight: .regular))
        .foregroundStyle(.secondary)
        .padding(4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MarkdownAnswer: View {
    enum Mode {
        /// Web answer: `[N]` resolves to numeric blue badges into `web`,
        /// `[LN]` resolves into `file` (kept for the legacy merge path).
        case web(web: [ChatCitation], file: [ChatCitation])
        /// RAG answer: `[N]` resolves to a clickable filename badge.
        case filenameInline(citations: [ChatCitation])
    }

    let text: String
    let mode: Mode

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(attributed(text))
                        .font(.system(size: level == 1 ? 22 : 19, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, level == 1 ? 4 : 8)

                case .paragraph(let text):
                    Text(attributed(text))
                        .font(.system(size: 16))
                        .lineSpacing(5)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .center)

                        Text(attributed(text))
                            .font(.system(size: 16))
                            .lineSpacing(5)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attributed(_ text: String) -> AttributedString {
        switch mode {
        case .web(let webCitations, let fileCitations):
            return InlineMarkdown.attributed(
                text,
                webCitations: webCitations,
                fileCitations: fileCitations
            )
        case .filenameInline(let citations):
            return InlineMarkdown.attributedFilenames(text, citations: citations)
        }
    }
}

private enum InlineMarkdown {
    static func attributed(
        _ text: String,
        webCitations: [ChatCitation],
        fileCitations: [ChatCitation]
    ) -> AttributedString {
        var result = AttributedString("")
        var buffer = ""
        var index = text.startIndex

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            let parsed = (try? AttributedString(
                markdown: buffer,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(buffer)
            result.append(parsed)
            buffer.removeAll()
        }

        while index < text.endIndex {
            let character = text[index]

            if character == "[",
               let closingIndex = text[index...].firstIndex(of: "]") {
                let valueStart = text.index(after: index)
                let value = String(text[valueStart..<closingIndex])

                if let parsed = parseMarker(value) {
                    flushBuffer()
                    switch parsed {
                    case .web(let n):
                        result.append(badge(label: "[\(n)]", color: .blue, target: webCitations, index: n))
                    case .file(let n):
                        result.append(badge(label: "[L\(n)]", color: .orange, target: fileCitations, index: n))
                    }
                    index = text.index(after: closingIndex)
                    continue
                }
            }

            buffer.append(character)
            index = text.index(after: index)
        }

        flushBuffer()
        return result
    }

    private enum Marker {
        case web(Int)
        case file(Int)
    }

    private static func parseMarker(_ value: String) -> Marker? {
        if let n = Int(value), n > 0 {
            return .web(n)
        }
        if value.first == "L" || value.first == "l",
           let n = Int(value.dropFirst()), n > 0 {
            return .file(n)
        }
        return nil
    }

    private static func badge(
        label: String,
        color: Color,
        target: [ChatCitation],
        index: Int
    ) -> AttributedString {
        var badge = AttributedString("\u{2009}\(label)")
        badge.foregroundColor = color
        badge.font = .system(size: 12, weight: .semibold)

        if target.indices.contains(index - 1) {
            badge.link = target[index - 1].url
        }

        return badge
    }

    /// RAG variant: `[N]` markers are replaced with clickable filename labels
    /// that open the matching local file. Numeric markers that fall outside
    /// the citation range are silently dropped (rather than leaving raw `[5]`
    /// text in the answer). Non-numeric brackets pass through untouched.
    static func attributedFilenames(_ text: String, citations: [ChatCitation]) -> AttributedString {
        var result = AttributedString("")
        var buffer = ""
        var index = text.startIndex

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            let parsed = (try? AttributedString(
                markdown: buffer,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(buffer)
            result.append(parsed)
            buffer.removeAll()
        }

        while index < text.endIndex {
            let character = text[index]

            if character == "[",
               let closingIndex = text[index...].firstIndex(of: "]") {
                let valueStart = text.index(after: index)
                let value = String(text[valueStart..<closingIndex])
                if let n = Int(value), n > 0 {
                    flushBuffer()
                    if citations.indices.contains(n - 1) {
                        result.append(filenameBadge(citation: citations[n - 1]))
                    }
                    // Else: model referenced a non-existent citation index —
                    // strip the marker silently to avoid bare `[4]` artifacts.
                    index = text.index(after: closingIndex)
                    continue
                }
            }

            buffer.append(character)
            index = text.index(after: index)
        }

        flushBuffer()
        return result
    }

    private static func filenameBadge(citation: ChatCitation) -> AttributedString {
        let display = displayFilename(citation.title)
        // U+2009 thin spaces nudge the badge away from surrounding text.
        var badge = AttributedString("\u{2009}\(display)\u{2009}")
        badge.foregroundColor = .orange
        badge.font = .system(size: 13, weight: .semibold)
        badge.underlineStyle = .single
        badge.link = citation.url
        return badge
    }

    private static func displayFilename(_ filename: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        if stem.count > 28 {
            return String(stem.prefix(26)) + "…"
        }
        return stem.isEmpty ? filename : stem
    }
}

private enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            guard !line.isEmpty else {
                flushParagraph()
                continue
            }

            if let heading = parseHeading(line) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if let bullet = parseBullet(line) {
                flushParagraph()
                blocks.append(.bullet(bullet))
                continue
            }

            paragraphLines.append(line)
        }

        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let prefix = line.prefix { $0 == "#" }
        guard !prefix.isEmpty, prefix.count <= 3 else {
            return nil
        }

        let rest = line.dropFirst(prefix.count)
        guard rest.first == " " else {
            return nil
        }

        return (prefix.count, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func parseBullet(_ line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else {
            return nil
        }

        return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
}

private struct ReferencesStrip: View {
    let citations: [ChatCitation]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                    Link(destination: citation.url) {
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(.blue)
                                .clipShape(Circle())

                            Text(citation.url.host() ?? citation.title)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(citation.title)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }
}

private struct ReferencesRail: View {
    let citations: [ChatCitation]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("References")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(citations.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }

                ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                    CitationCard(index: index + 1, citation: citation)
                }
            }
            .padding(18)
        }
        .background(.ultraThinMaterial)
    }
}

private struct CitationCard: View {
    let index: Int
    let citation: ChatCitation

    var body: some View {
        Link(destination: citation.url) {
            VStack(alignment: .leading, spacing: 8) {
                Text(citation.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text("\(index)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(.blue)
                        .clipShape(Circle())

                    Text(citation.url.host() ?? citation.url.absoluteString)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RAGAnswerSection: View {
    let state: ChatViewModel.RAGState
    let text: String
    /// Drives both inline `[N]` → filename resolution and the "Based on"
    /// footer chips. Caller decides whether these come from API annotations
    /// or from the file-search match list.
    let citations: [ChatCitation]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [.orange, .pink.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)

                Text("From your files")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if state == .synthesizing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                }

                Spacer()
            }

            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(LinearGradient(
                        colors: [.orange.opacity(0.6), .pink.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 10) {
                    bodyView
                        .padding(.horizontal, 14)
                        .padding(.top, 12)

                    if state == .ready, !citations.isEmpty {
                        BasedOnRow(citations: citations)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                    } else {
                        Spacer().frame(height: 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [.orange.opacity(0.08), .pink.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        switch state {
        case .idle:
            EmptyView()
        case .synthesizing:
            HStack(spacing: 8) {
                Text("Synthesizing from your files…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .ready:
            if text.isEmpty {
                Text("No clear synthesis from your files.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                MarkdownAnswer(
                    text: text,
                    mode: .filenameInline(citations: citations)
                )
                .textSelection(.enabled)
            }
        case .failed:
            Text("Could not synthesize from your files.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

private struct BasedOnRow: View {
    let citations: [ChatCitation]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Based on")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 5)

            FlowLayout(spacing: 6) {
                ForEach(Array(citations.enumerated()), id: \.element.id) { _, citation in
                    SourceChip(citation: citation)
                }
            }
        }
    }
}

private struct SourceChip: View {
    let citation: ChatCitation

    var body: some View {
        Link(destination: citation.url) {
            HStack(spacing: 5) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(citation.url.path)
    }

    private var displayName: String {
        let stem = (citation.title as NSString).deletingPathExtension
        if stem.count > 24 {
            return String(stem.prefix(22)) + "…"
        }
        return stem.isEmpty ? citation.title : stem
    }
}

/// Simple flow layout that wraps children onto multiple lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct LocalFilesSection: View {
    let citations: [ChatCitation]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Local files")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text("\(citations.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            ForEach(Array(citations.enumerated()), id: \.element.id) { _, citation in
                LocalFileCard(citation: citation)
            }
        }
    }
}

private struct LocalFileCard: View {
    let citation: ChatCitation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Link(destination: citation.url) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: iconName)
                        .font(.system(size: 16))
                        .foregroundStyle(.orange)
                        .frame(width: 26, height: 26)
                        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(citation.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(folderHint)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            if let snippet = citation.snippet, !snippet.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Rectangle()
                        .fill(.orange.opacity(0.5))
                        .frame(width: 2)

                    Text(snippet)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.leading, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var iconName: String {
        switch (citation.url.pathExtension.lowercased()) {
        case "pdf": return "doc.richtext"
        case "docx", "doc": return "doc.text"
        case "pptx", "ppt": return "rectangle.stack"
        case "xlsx", "xls": return "tablecells"
        case "md", "txt": return "text.alignleft"
        case "jpg", "jpeg", "png", "bmp", "tiff", "tif", "heic": return "photo"
        default: return "doc"
        }
    }

    private var folderHint: String {
        let folder = citation.url.deletingLastPathComponent().lastPathComponent
        return folder.isEmpty ? citation.url.path : "in \(folder)"
    }
}

struct SettingsView: View {
    @ObservedObject var settings: ChatSettings
    @ObservedObject var fileIndex: FileIndexManager
    let indexNow: () -> Void
    let applyFileSearchSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isAPIKeyFocused: Bool

    init(
        settings: ChatSettings,
        fileIndex: FileIndexManager? = nil,
        indexNow: @escaping () -> Void = {},
        applyFileSearchSettings: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.fileIndex = fileIndex ?? FileIndexManager()
        self.indexNow = indexNow
        self.applyFileSearchSettings = applyFileSearchSettings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Configuration")
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button {
                        settings.save()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
                }

                chatSection

                Divider()

                fileSearchSection

                HStack {
                    Spacer()

                    Button("Save") {
                        settings.save()
                        applyFileSearchSettings()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
        }
        .frame(width: 560)
        .frame(maxHeight: 640)
        .onAppear {
            settings.refreshStartupState()
            DispatchQueue.main.async {
                isAPIKeyFocused = true
            }
        }
    }

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenAI-compatible API (optional)")
                    .font(.system(size: 13, weight: .semibold))
                Text("Leave blank to use the built-in default.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            LabeledContent("API Key") {
                SecureField("sk-...", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
                    .focused($isAPIKeyFocused)
            }

            LabeledContent("Base URL") {
                TextField("https://api.example.com/v1", text: $settings.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
            }

            LabeledContent("Model") {
                TextField("model-name", text: $settings.model)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
            }

            Toggle("Run at startup", isOn: Binding(
                get: { settings.runAtStartup },
                set: { settings.setRunAtStartup($0) }
            ))
            .padding(.top, 4)

            if let startupError = settings.startupError {
                Text(startupError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var fileSearchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("File Search")
                        .font(.system(size: 13, weight: .semibold))
                    Text("BETA")
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Text("Index a local folder with Upstage so answers can cite your own files.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Upstage API Key") {
                SecureField("up_...", text: $settings.upstageAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
            }

            LabeledContent("Folder") {
                HStack(spacing: 8) {
                    TextField("~/Downloads", text: $settings.fileSearchFolderPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                    Button("Choose…") { chooseFolder() }
                }
            }

            HStack(spacing: 10) {
                Button {
                    settings.save()
                    applyFileSearchSettings()
                    indexNow()
                } label: {
                    if fileIndex.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Index Now")
                    }
                }
                .disabled(!settings.hasFileSearchKey || fileIndex.isSyncing)

                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Supported: PDF, DOCX, PPTX, XLSX, HWP/HWPX, MD, TXT, JPG, PNG, BMP, TIFF, HEIC. Up to 480 files from the folder's top level.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var statusText: String {
        switch fileIndex.status.phase {
        case .idle:
            if fileIndex.status.totalFiles == 0 {
                return settings.hasFileSearchKey ? "No files indexed yet." : "Add a key to enable file search."
            }
            let lastSync = fileIndex.status.lastSyncAt.map { Self.relativeDateFormatter.localizedString(for: $0, relativeTo: Date()) } ?? "—"
            return "\(fileIndex.status.indexedFiles) of \(fileIndex.status.totalFiles) indexed · synced \(lastSync)"
        case .scanning:
            return "Scanning folder…"
        case .uploading(let current, let total):
            return "Uploading \(current)/\(total)…"
        case .waitingForIndexing(let current, let total):
            return "Waiting for indexing \(current)/\(total)…"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (settings.fileSearchFolderPath as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            settings.fileSearchFolderPath = url.path
        }
    }
}
