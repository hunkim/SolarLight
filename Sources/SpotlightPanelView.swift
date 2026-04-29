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
                let showRail = geometry.size.width >= 820 && !viewModel.citations.isEmpty
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        AnswerView(
                            text: viewModel.response,
                            isPlaceholder: viewModel.response.isEmpty,
                            citations: viewModel.citations
                        )
                        if !showRail, !viewModel.citations.isEmpty {
                            ReferencesStrip(citations: viewModel.citations)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if showRail {
                        Divider()
                        ReferencesRail(citations: viewModel.citations)
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
                    Text(InlineMarkdown.attributed(text, citations: citations))
                        .font(.system(size: level == 1 ? 22 : 19, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, level == 1 ? 4 : 8)

                case .paragraph(let text):
                    Text(InlineMarkdown.attributed(text, citations: citations))
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

                        Text(InlineMarkdown.attributed(text, citations: citations))
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

private enum InlineMarkdown {
    static func attributed(_ text: String, citations: [ChatCitation]) -> AttributedString {
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

                if let number = Int(value), number > 0 {
                    flushBuffer()
                    result.append(citationBadge(number: number, citations: citations))
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

    private static func citationBadge(number: Int, citations: [ChatCitation]) -> AttributedString {
        var badge = AttributedString("\u{2009}[\(number)]")
        badge.foregroundColor = .blue
        badge.font = .system(size: 12, weight: .semibold)

        if citations.indices.contains(number - 1) {
            badge.link = citations[number - 1].url
        }

        return badge
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
