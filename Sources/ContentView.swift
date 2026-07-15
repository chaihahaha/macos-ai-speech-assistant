import SwiftUI
import Foundation

struct ContentView: View {
    @StateObject private var viewModel = ViewModel()
    @State private var sessIDInput: String = ""
    @State private var showSettings: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle()
                    .fill(stateIndicatorColor)
                    .frame(width: 12, height: 12)

                Text(statusText)
                    .font(.headline)
                    .foregroundColor(statusColor)

                Spacer()

                if viewModel.isLoading {
                    ProgressView()
                }

                Button(action: { showSettings.toggle() }) {
                    Image(systemName: showSettings ? "gearshape.fill" : "gearshape")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.2))

            if showSettings {
                settingsPanel
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(Color.gray.opacity(0.05))
            }

            if viewModel.conversationState == ViewModel.ConversationState.waitingSilence {
                HStack {
                    Text("Waiting for silence...")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text("\(Int(viewModel.silenceTimerValue))s")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1))
            }

            HStack {
                Text("ASR: Qwen3-ASR-0.6B-MLX-4bit (local)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("TTS: macOS System TTS")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(viewModel.backendDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 4)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages, id: \.id) { msg in
                            MessageView(message: msg)
                                .id(msg.id)
                        }

                        if viewModel.isTyping || viewModel.conversationState == ViewModel.ConversationState.generating {
                            HStack {
                                Spacer()
                                HStack(spacing: 4) {
                                    Text("\u{25CF}")
                                    Text("\u{25CF}")
                                    Text("\u{25CF}")
                                }
                                .font(.body)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.orange.opacity(0.2))
                                .cornerRadius(8)
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .onChange(of: viewModel.messages.count) {
                    if let lastMessage = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text(stateStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 70, alignment: .leading)

                Spacer()

                if viewModel.conversationState == .inactive {
                    Button(action: { viewModel.startListening() }) {
                        Image(systemName: "mic.circle.fill")
                            .font(.title)
                            .foregroundColor(.blue)
                    }
                    .frame(width: 60, height: 60)
                    .disabled(viewModel.isLoading)
                } else {
                    Button(action: { viewModel.stopConversation() }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title)
                            .foregroundColor(.red)
                    }
                    .frame(width: 60, height: 60)
                    .disabled(viewModel.isLoading)
                }

                Spacer()

                Button(action: { viewModel.testTTS() }) {
                    Image(systemName: "speaker.circle.fill")
                        .font(.title3)
                }
                .frame(width: 50, height: 50)
                .disabled(viewModel.isLoading)

                Button(action: { viewModel.clearConversation() }) {
                    Image(systemName: "trash.circle")
                        .font(.title3)
                }
                .frame(width: 50, height: 50)
                .disabled(viewModel.isLoading)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .padding(.horizontal)
        .onAppear {
            Task { await viewModel.loadModels() }
        }
    }

    var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Backend:").font(.caption).foregroundColor(.secondary)
                Picker("", selection: $viewModel.selectedBackend) {
                    Text("llama.cpp").tag("llamacpp")
                    Text("opencode").tag("opencode")
                }
                .pickerStyle(.segmented)
                .onChange(of: viewModel.selectedBackend) { _, _ in viewModel.applyBackendSettings() }
            }

            if viewModel.selectedBackend == "llamacpp" {
                llamaSettings
            } else {
                opencodeSettings
            }

            HStack {
                Spacer()
                Button("Apply") { viewModel.applyBackendSettings() }
                    .font(.caption)
                    .controlSize(.small)
            }
        }
    }

    var llamaSettings: some View {
        HStack(spacing: 6) {
            Text("Server:").font(.caption).foregroundColor(.secondary)
            TextField("http://127.0.0.1:8080", text: $viewModel.llamacppURL)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
        }
    }

    var opencodeSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Server:").font(.caption).foregroundColor(.secondary)
                TextField("http://127.0.0.1:9999", text: $viewModel.opencodeURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            HStack(spacing: 6) {
                Text("Provider:").font(.caption).foregroundColor(.secondary)
                TextField("llama.cpp", text: $viewModel.opencodeProviderID)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 120)
                Text("Model:").font(.caption).foregroundColor(.secondary)
                TextField("qwen3.6", text: $viewModel.opencodeModelID)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 120)
                Text("Agent:").font(.caption).foregroundColor(.secondary)
                TextField("build", text: $viewModel.opencodeAgent)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(maxWidth: 100)
            }
            HStack(spacing: 6) {
                Text("Dir:").font(.caption).foregroundColor(.secondary)
                TextField("~/source", text: $viewModel.opencodeDirectory)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            HStack(spacing: 6) {
                Text("Session:").font(.caption).foregroundColor(.secondary)
                if let sid = viewModel.currentSessID {
                    HStack(spacing: 4) {
                        Text(sid.prefix(16) + "...")
                            .font(.caption)
                            .foregroundColor(.green)
                            .lineLimit(1)
                        Button(action: { viewModel.currentSessID = nil }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    TextField("sess_id (optional)", text: $sessIDInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(maxWidth: 200)
                    Button("Set") { viewModel.setSessID(sessIDInput) }
                        .font(.caption)
                        .controlSize(.small)
                }
            }
        }
    }

    var stateStatusText: String {
        switch viewModel.conversationState {
        case .inactive:        return "Idle"
        case .listening:       return "Recording..."
        case .waitingSilence:  return "Waiting..."
        case .transcribing:    return "Recognizing..."
        case .generating:      return "Thinking..."
        case .speaking:        return "Speaking..."
        }
    }

    var stateIndicatorColor: Color {
        switch viewModel.conversationState {
        case .inactive:        return .gray
        case .listening:       return .red
        case .waitingSilence:  return .blue
        case .transcribing:    return .orange
        case .generating:      return .orange
        case .speaking:        return .green
        }
    }

    var statusText: String {
        switch viewModel.conversationState {
        case .inactive:        return "Idle"
        case .listening:       return "Listening..."
        case .waitingSilence:  return "Processing..."
        case .transcribing:    return "Transcribing..."
        case .generating:      return "Generating..."
        case .speaking:        return "Speaking..."
        }
    }

    var statusColor: Color {
        switch viewModel.conversationState {
        case .inactive:        return .gray
        case .listening:       return .red
        case .waitingSilence:  return .blue
        case .transcribing:    return .orange
        case .generating:      return .orange
        case .speaking:        return .green
        }
    }
}

struct MessageView: View {
    let message: Message

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.role == .user ? Color.red.opacity(0.2) : Color.green.opacity(0.2))
                    .cornerRadius(8)

                Text(formatTimestamp(message.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if message.role == .assistant {
                Spacer()
            }
        }
    }

    private func formatTimestamp(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

struct Message: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date = Date()

    enum Role {
        case user
        case assistant
    }
}
