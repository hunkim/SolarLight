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
                        Label("Update", systemImage: "arrow.down.circle")
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

            ScrollView {
                Text(outputText)
                    .font(.system(size: 15))
                    .foregroundStyle(viewModel.response.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(22)
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
        viewModel.response.isEmpty ? "Response will stream here." : viewModel.response
    }
}

private struct SettingsView: View {
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
                    TextField("https://api.upstage.ai/v1", text: $settings.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 360)
                }

                LabeledContent("Model") {
                    TextField("solar-pro3", text: $settings.model)
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
