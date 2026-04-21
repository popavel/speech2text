import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var manager = TranscriptionManager()
    @State private var isDragTargeted = false
    @State private var showFileImporter = false

    var body: some View {
        VStack(spacing: 20) {
            dropZone

            if !manager.droppedFileURLs.isEmpty {
                fileList
            }

            controlsRow

            transcribeButton

            if !manager.statusMessage.isEmpty {
                statusRow
            }

            if case .transcribing(let progress) = manager.status, progress > 0 {
                ProgressView(value: progress)
            }

            if !manager.transcriptionResult.isEmpty {
                resultSection
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 500)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                manager.addFiles(urls)
            }
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDragTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isDragTargeted ? Color.accentColor.opacity(0.05) : Color.clear)
                )

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Drop audio or video files here")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("mp3, wav, m4a, flac, mp4, mov, mkv...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Browse Files") {
                    showFileImporter = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("o")
            }
        }
        .frame(height: 150)
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            loadDroppedFiles(from: providers)
            return true
        }
    }

    // MARK: - File List

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(manager.droppedFileURLs.count) file(s) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") {
                    manager.clearFiles()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(
                        Array(manager.droppedFileURLs.enumerated()),
                        id: \.offset
                    ) { index, url in
                        fileChip(url: url, index: index)
                    }
                }
            }
        }
    }

    private func fileChip(url: URL, index: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: iconName(for: url))
                .font(.caption)
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
            Button {
                manager.removeFile(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1), in: Capsule())
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Language")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $manager.selectedLanguage) {
                    ForEach(TranscriptionLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $manager.selectedModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }

            Spacer()
        }
    }

    // MARK: - Transcribe Button

    private var transcribeButton: some View {
        HStack {
            Button {
                Task { await manager.startTranscription() }
            } label: {
                HStack(spacing: 8) {
                    if manager.isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Label(
                        manager.isProcessing ? "Transcribing..." : "Transcribe",
                        systemImage: "waveform"
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!manager.canTranscribe)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(spacing: 6) {
            Group {
                switch manager.status {
                case .error:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .loadingModel, .transcribing:
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(.blue)
                default:
                    EmptyView()
                }
            }

            Text(manager.statusMessage)
                .font(.callout)
                .foregroundStyle(statusColor)

            Spacer()
        }
    }

    // MARK: - Results

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcription")
                    .font(.headline)
                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        manager.transcriptionResult,
                        forType: .string
                    )
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    exportText()
                } label: {
                    Label("Export .txt", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            TextEditor(text: $manager.transcriptionResult)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )
                .frame(minHeight: 150, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch manager.status {
        case .error: return .red
        case .completed: return .green
        default: return .secondary
        }
    }

    private func iconName(for url: URL) -> String {
        let videoExts: Set<String> = ["mp4", "mov", "avi", "mkv", "webm", "m4v"]
        return videoExts.contains(url.pathExtension.lowercased()) ? "film" : "music.note"
    }

    private func loadDroppedFiles(from providers: [NSItemProvider]) {
        for provider in providers {
            Task {
                if let url = await fileURL(from: provider) {
                    manager.addFiles([url])
                }
            }
        }
    }

    private func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier
            ) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                continuation.resume(returning: url)
            }
        }
    }

    private func exportText() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcription.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? manager.transcriptionResult.write(
                to: url, atomically: true, encoding: .utf8
            )
        }
    }
}

#Preview {
    ContentView()
}
