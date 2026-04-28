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
                if geometry.size.width >= 820, !viewModel.citations.isEmpty {
                    HStack(alignment: .top, spacing: 0) {
                        AnswerView(
                            text: outputText,
                            isPlaceholder: viewModel.response.isEmpty,
                            citations: viewModel.citations
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Divider()

                        ReferencesRail(citations: viewModel.citations)
                            .frame(width: min(340, geometry.size.width * 0.34))
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    AnswerView(
                        text: outputText,
                        isPlaceholder: viewModel.response.isEmpty,
                        citations: viewModel.citations
                    )
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
        .onChange(of: viewModel.focusToken) { _ in
            DispatchQueue.main.async {
                isInputFocused = true
            }
        }
        .onExitCommand {
            close()
        }
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsView(settings: viewModel.settings)
                .onDisappear {
                    viewModel.settings.save()
                    viewModel.settingsDidClose()
                }
        }
    }

    private var outputText: String {
        viewModel.response
    }
}

private struct AnswerView: View {
    let text: String
    let isPlaceholder: Bool
    let citations: [ChatCitation]

    var body: some View {
        ScrollView {
            if isPlaceholder {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarkdownAnswer(text: text, citations: citations)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MarkdownAnswer: View {
    let text: String
    let citations: [ChatCitation]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    InlineMarkdownText(text: text, citations: citations)
                        .font(.system(size: level == 1 ? 22 : 19, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, level == 1 ? 4 : 8)

                case .paragraph(let text):
                    InlineMarkdownText(text: text, citations: citations)
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

                        InlineMarkdownText(text: text, citations: citations)
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
}

private struct InlineMarkdownText: View {
    let text: String
    let citations: [ChatCitation]

    var body: some View {
        WrappingHStack(horizontalSpacing: 4, verticalSpacing: 6) {
            ForEach(Array(InlineToken.parse(text).enumerated()), id: \.offset) { _, token in
                switch token {
                case .text(let markdown):
                    inlineText(markdown)

                case .citation(let number):
                    CitationBadge(number: number, citation: citation(for: number))
                }
            }
        }
    }

    private func citation(for number: Int) -> ChatCitation? {
        let index = number - 1
        guard citations.indices.contains(index) else {
            return nil
        }

        return citations[index]
    }

    private func inlineText(_ markdown: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }

        return Text(markdown)
    }
}

private enum InlineToken {
    case text(String)
    case citation(Int)

    static func parse(_ markdown: String) -> [InlineToken] {
        var tokens: [InlineToken] = []
        var buffer = ""
        var index = markdown.startIndex

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            tokens.append(contentsOf: textTokens(from: buffer))
            buffer.removeAll()
        }

        while index < markdown.endIndex {
            let character = markdown[index]

            if character == "[" {
                let closingIndex = markdown[index...].firstIndex(of: "]")
                if let closingIndex {
                    let valueStart = markdown.index(after: index)
                    let value = String(markdown[valueStart..<closingIndex])

                    if let number = Int(value), number > 0 {
                        flushBuffer()
                        tokens.append(.citation(number))
                        index = markdown.index(after: closingIndex)
                        continue
                    }
                }
            }

            buffer.append(character)
            index = markdown.index(after: index)
        }

        flushBuffer()
        return tokens
    }

    private static func textTokens(from text: String) -> [InlineToken] {
        var tokens: [InlineToken] = []
        var current = ""

        for character in text {
            current.append(character)

            if character.isWhitespace {
                tokens.append(.text(current))
                current.removeAll()
            }
        }

        if !current.isEmpty {
            tokens.append(.text(current))
        }

        return tokens
    }
}

private struct CitationBadge: View {
    let number: Int
    let citation: ChatCitation?

    var body: some View {
        if let citation {
            Link(destination: citation.url) {
                badge
            }
            .buttonStyle(.plain)
            .help(citation.title)
        } else {
            badge
        }
    }

    private var badge: some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(.blue)
            .clipShape(Circle())
            .accessibilityLabel("Reference \(number)")
    }
}

private struct WrappingHStack: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        return layout(in: maxWidth, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = layout(in: bounds.width, subviews: subviews)

        for item in layout.items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                proposal: ProposedViewSize(item.size)
            )
        }
    }

    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> (items: [Item], size: CGSize) {
        var items: [Item] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)

            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            items.append(Item(index: index, origin: CGPoint(x: x, y: y), size: size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, x - horizontalSpacing)
        }

        return (items, CGSize(width: usedWidth, height: y + rowHeight))
    }

    private struct Item {
        let index: Int
        let origin: CGPoint
        let size: CGSize
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

struct SettingsView: View {
    @ObservedObject var settings: ChatSettings
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isAPIKeyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("API Key") {
                    SecureField("up_...", text: $settings.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 360)
                        .focused($isAPIKeyFocused)
                }

                LabeledContent("Base URL") {
                    TextField(SolarDefaults.baseURL, text: $settings.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 360)
                }

                LabeledContent("Model") {
                    TextField(SolarDefaults.model, text: $settings.model)
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

            HStack {
                Button("Solar Defaults") {
                    settings.resetToSolarDefaults()
                }

                Spacer()

                Button("Save") {
                    settings.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            settings.refreshStartupState()
            DispatchQueue.main.async {
                isAPIKeyFocused = true
            }
        }
    }
}
