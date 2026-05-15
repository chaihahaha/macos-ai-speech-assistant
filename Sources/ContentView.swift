import SwiftUI
import Foundation

struct ContentView: View {
    @StateObject private var viewModel = ViewModel()
    
    var body: some View {
        VStack {
            // Enhanced status header with state indicator
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
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.2))
            
            // Silence timer indicator
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
            
            // Model info
            HStack {
                Text("ASR: Qwen3-ASR-0.6B-MLX-4bit (local)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("TTS: macOS System TTS")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("LLM: llama.cpp @ 127.0.0.1:8080")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            
            Divider()
            
            // Conversation transcript
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
                                    Text("●")
                                    Text("●")
                                    Text("●")
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
            
            // Control buttons
            HStack {
                // Status indicator button (clickable only when inactive)
                Button(action: {
                    if viewModel.conversationState == .inactive {
                        viewModel.startListening()
                    }
                }) {
                    Image(systemName: stateIconName)
                        .font(stateIconFont)
                        .foregroundColor(stateIconColor)
                }
                .frame(width: 60, height: 60)
                .disabled(viewModel.isLoading || viewModel.conversationState != .inactive)
                
                Spacer()
                
                // Stop button (only visible when active)
                if viewModel.conversationState != ViewModel.ConversationState.inactive {
                    Button(action: {
                        viewModel.stopConversation()
                    }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                    }
                    .frame(width: 50, height: 50)
                    .disabled(viewModel.isLoading)
                    
                    Spacer()
                }
                
                Button(action: {
                    viewModel.testTTS()
                }) {
                    Image(systemName: "speaker.circle.fill")
                        .font(.title3)
                }
                .frame(width: 50, height: 50)
                .disabled(viewModel.isLoading)
                
                Button(action: {
                    viewModel.clearConversation()
                }) {
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
            Task {
                await viewModel.loadModels()
            }
        }
    }
    
    // MARK: - Status Icon
    
    var stateIconName: String {
        switch viewModel.conversationState {
        case .inactive:
            return "mic.circle.fill"
        case .listening:
            return "mic.circle.fill"
        case .waitingSilence:
            return "waveform.circle.fill"
        case .transcribing:
            return "text.bubble.fill"
        case .generating:
            return "brain.head.profile"
        case .speaking:
            return "speaker.wave.2.circle.fill"
        }
    }
    
    var stateIconFont: Font {
        viewModel.conversationState == .inactive ? .title : .title2
    }
    
    var stateIconColor: Color {
        switch viewModel.conversationState {
        case .inactive: return .blue
        case .listening: return .red
        case .waitingSilence: return .blue
        case .transcribing: return .orange
        case .generating: return .orange
        case .speaking: return .green
        }
    }
    
    var stateIndicatorColor: Color {
        switch viewModel.conversationState {
        case ViewModel.ConversationState.inactive:
            return .gray
        case ViewModel.ConversationState.listening:
            return .red
        case ViewModel.ConversationState.waitingSilence:
            return .blue
        case ViewModel.ConversationState.transcribing:
            return .orange
        case ViewModel.ConversationState.generating:
            return .orange
        case ViewModel.ConversationState.speaking:
            return .green
        }
    }
    
    var statusText: String {
        switch viewModel.conversationState {
        case ViewModel.ConversationState.inactive:
            return "Idle"
        case ViewModel.ConversationState.listening:
            return "Listening..."
        case ViewModel.ConversationState.waitingSilence:
            return "Processing..."
        case ViewModel.ConversationState.transcribing:
            return "Transcribing..."
        case ViewModel.ConversationState.generating:
            return "Generating..."
        case ViewModel.ConversationState.speaking:
            return "Speaking..."
        }
    }
    
    var statusColor: Color {
        switch viewModel.conversationState {
        case ViewModel.ConversationState.inactive:
            return .gray
        case ViewModel.ConversationState.listening:
            return .red
        case ViewModel.ConversationState.waitingSilence:
            return .blue
        case ViewModel.ConversationState.transcribing:
            return .orange
        case ViewModel.ConversationState.generating:
            return .orange
        case ViewModel.ConversationState.speaking:
            return .green
        }
    }
}

// MARK: - Message View Component

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

// MARK: - Message Type

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
