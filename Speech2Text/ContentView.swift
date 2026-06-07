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

            if !manager.skippedFileNames.isEmpty {
                warningRow(skippedFilesMessage(manager.skippedFileNames))
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
            guard !manager.isProcessing else { return }
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
                Text(Self.supportedFormatsCaption)
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
            guard !manager.isProcessing else { return false }
            loadDroppedFiles(from: providers)
            return true
        }
        .disabled(manager.isProcessing)
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
        // Don't let "Clear All" / per-file removal mutate the queue while a run
        // is iterating it — that would leave an inconsistent completed state.
        .disabled(manager.isProcessing)
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

    private func warningRow(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.orange)
            Spacer()
        }
    }

    private func skippedFilesMessage(_ names: [String]) -> String {
        let label = names.count == 1 ? "file" : "files"
        return "Unsupported \(label) skipped: \(names.joined(separator: ", "))"
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

    // Derived from the manager's canonical sets so the UI never advertises or
    // icons a format the app doesn't actually accept. Static so the union/sort
    // runs once rather than on every render.
    private static let supportedFormatsCaption: String =
        TranscriptionManager.supportedAudioExtensions
            .union(TranscriptionManager.supportedVideoExtensions)
            .sorted()
            .joined(separator: ", ")

    private func iconName(for url: URL) -> String {
        TranscriptionManager.mediaKind(for: url) == .video ? "film" : "music.note"
    }

    private func loadDroppedFiles(from providers: [NSItemProvider]) {
        // Resolve every provider, then hand the whole drop to addFiles in a
        // single call. Adding one file at a time would let each call's
        // skipped-files bookkeeping overwrite the previous one's.
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await fileURL(from: provider) {
                    urls.append(url)
                }
            }
            // Resolving providers is async, so a transcription may have started
            // since the drop was accepted — re-check before mutating the queue.
            guard !manager.isProcessing else { return }
            if !urls.isEmpty {
                manager.addFiles(urls)
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
