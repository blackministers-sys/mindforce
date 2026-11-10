import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @StateObject private var callMonitor = CallMonitor()
    @StateObject private var recorder = MeetingRecorder()
    @ObservedObject private var voice = VoiceCallManager.shared
    @ObservedObject private var configuration = VoiceServerConfiguration.shared
    @StateObject private var recordingsStore = VoiceRecordingsStore()
    @StateObject private var aiProcessor = AIRecordingProcessor()

    @State private var showingImporter = false
    @State private var importedFileName: String?
    @State private var importError: String?
    @State private var serverURLDraft = VoiceServerConfiguration.shared.serverURL
    @State private var apiTokenDraft = ""
    @State private var phoneNumber = ""
    @State private var pendingSystemCallNumber: String?
    @State private var showingSystemCallPrompt = false
    @State private var showingRecordingConsentRequired = false
    @State private var aiLibraryQuery = ""
    @State private var pendingAIRecordingDeletion: AIRecordingLibraryItem?
    @AppStorage("golos.recording.accepted") private var hasAcknowledgedRecordingNotice = false
    @AppStorage("golos.meeting.recording.acknowledged") private var hasAcknowledgedMeetingRecordingNotice = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    voiceSettings
                    phoneDialer
                    recordingsLibrary
                    aiResultCard
                    aiLibraryCard
                    meetingRecorder
                    importCard
                    callMonitorCard
                    platformNote
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Голос")
            .onAppear { aiProcessor.refreshLibrary(query: aiLibraryQuery) }
            .onOpenURL { url in
                handleSystemCallURL(url)
            }
            .confirmationDialog(
                "Начать звонок через «Голос»?",
                isPresented: $showingSystemCallPrompt,
                titleVisibility: .visible
            ) {
                Button("Позвонить с записью") {
                    guard hasAcknowledgedRecordingNotice else {
                        showingRecordingConsentRequired = true
                        return
                    }
                    if let number = pendingSystemCallNumber {
                        voice.startCall(to: number)
                    }
                    pendingSystemCallNumber = nil
                }
                Button("Отмена", role: .cancel) {
                    pendingSystemCallNumber = nil
                }
            } message: {
                Text("Вызов будет выполнен через телефонный сервис «Голос». Собеседнику будет предложено подтвердить запись перед соединением.")
            }
            .alert("Сначала разрешите запись", isPresented: $showingRecordingConsentRequired) {
                Button("Понятно", role: .cancel) { }
            } message: {
                Text("Включите переключатель «Разрешаю запись звонков через „Голос“» в приложении, затем повторите вызов.")
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                importAudio(result)
            }
            .onChange(of: voice.status) { newStatus in
                if newStatus == "Телефония готова" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        recordingsStore.refresh()
                    }
                }
            }
        }
        .tint(Color(red: 0.35, green: 0.82, blue: 0.68))
    }

    private var voiceSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Телефонный сервис", systemImage: "network")
                .font(.headline)
            HStack(spacing: 8) {
                Circle()
                    .fill(configuration.isConfigured ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(configuration.isConfigured ? "Настройки сохранены" : "Нужна настройка сервера")
                    .font(.subheadline.weight(.medium))
            }
            TextField("HTTPS-адрес сервера", text: $serverURLDraft)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            SecureField("Ключ доступа приложения", text: $apiTokenDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Button("Сохранить и проверить") {
                configuration.save(serverURL: serverURLDraft, apiToken: apiTokenDraft)
                apiTokenDraft = ""
                voice.validateConfiguration()
                recordingsStore.refresh()
            }
            .buttonStyle(.borderedProminent)
            .disabled(serverURLDraft.isEmpty || apiTokenDraft.isEmpty)
            Text(voice.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = voice.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Ключ хранится в Keychain iPhone. Секреты Twilio в приложении не используются.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var phoneDialer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Звонок через «Голос»", systemImage: "phone.arrow.up.right")
                .font(.headline)
            TextField("+31612345678", text: $phoneNumber)
                .keyboardType(.phonePad)
                .textFieldStyle(.roundedBorder)
            Toggle("Разрешаю запись звонков через «Голос»", isOn: $hasAcknowledgedRecordingNotice)
                .font(.footnote)
            Button {
                voice.startCall(to: phoneNumber)
            } label: {
                Label("Позвонить и записать", systemImage: "phone.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!configuration.isConfigured || !hasAcknowledgedRecordingNotice || phoneNumber.isEmpty || voice.isCallActive)
            if voice.isCallActive {
                HStack {
                    Button {
                        voice.toggleMute()
                    } label: {
                        Label(voice.isMuted ? "Включить микрофон" : "Выключить микрофон",
                              systemImage: voice.isMuted ? "mic.slash.fill" : "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        voice.endCall()
                    } label: {
                        Label("Завершить", systemImage: "phone.down.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text(voice.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Звонок проходит через телефонный шлюз «Голоса», а не через SIM-звонилку iPhone. Запись выполняется на стороне провайдера.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Если назначить «Голос» приложением для звонков по умолчанию в настройках iOS, вызовы по ссылкам tel: будут открывать предложение записать разговор. Входящие SIM-звонки при этом останутся в стандартном приложении «Телефон».")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }


    private var recordingsLibrary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Записи звонков", systemImage: "waveform.badge.mic")
                    .font(.headline)
                Spacer()
                Button {
                    recordingsStore.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Обновить список записей")
            }
            if recordingsStore.isLoading {
                ProgressView()
            }
            Text(recordingsStore.message)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(recordingsStore.recordings) { recording in
                VoiceRecordingRow(recording: recording, store: recordingsStore, aiProcessor: aiProcessor)
                if recording.id != recordingsStore.recordings.last?.id {
                    Divider()
                }
            }
            Text("Аудио загружается по защищённому соединению из телефонного backend.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var aiResultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Расшифровка и AI-конспект", systemImage: "text.quote")
                .font(.headline)
            HStack(spacing: 8) {
                if aiProcessor.isProcessing { ProgressView() }
                Text(aiProcessor.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = aiProcessor.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let record = aiProcessor.latestRecord {
                Divider()
                HStack(spacing: 12) {
                    Button {
                        aiProcessor.downloadRecordingAudio(id: record.id, fileName: record.fileName)
                    } label: {
                        if aiProcessor.isDownloadingAudio {
                            ProgressView()
                        } else {
                            Label("Скачать аудио", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(aiProcessor.isDownloadingAudio)
                    if aiProcessor.latestAudioRecordID == record.id, let audioURL = aiProcessor.latestAudioURL {
                        ShareLink(item: audioURL) {
                            Label("Поделиться аудио", systemImage: "square.and.arrow.up")
                        }
                    }
                    ShareLink(item: record.transcript) {
                        Label("Экспорт текста", systemImage: "doc.on.doc")
                    }
                }
                if let summary = record.summary {
                    ShareLink(item: summary.summary) {
                        Label("Поделиться конспектом", systemImage: "square.and.arrow.up")
                    }
                    .font(.caption)
                }
                if let summary = record.summary {
                    Text(summary.title)
                        .font(.subheadline.weight(.semibold))
                    Text(summary.summary)
                        .font(.subheadline)
                        .textSelection(.enabled)
                    if !summary.keyPoints.isEmpty {
                        Text("Ключевые тезисы").font(.subheadline.weight(.semibold))
                        ForEach(Array(summary.keyPoints.enumerated()), id: \.offset) { _, item in
                            Text("• " + item).font(.footnote)
                        }
                    }
                    if !summary.decisions.isEmpty {
                        Text("Решения").font(.subheadline.weight(.semibold))
                        ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, item in
                            Text("• " + item).font(.footnote)
                        }
                    }
                    if !summary.tasks.isEmpty {
                        Text("Задачи").font(.subheadline.weight(.semibold))
                        ForEach(summary.tasks) { item in
                            let details = [item.owner, item.dueDate].compactMap { $0 }.filter { !$0.isEmpty }
                            Text("• " + item.task + (details.isEmpty ? "" : " — " + details.joined(separator: ", ")))
                                .font(.footnote)
                        }
                    }
                    if !summary.openQuestions.isEmpty {
                        Text("Открытые вопросы").font(.subheadline.weight(.semibold))
                        ForEach(Array(summary.openQuestions.enumerated()), id: \.offset) { _, item in
                            Text("• " + item).font(.footnote)
                        }
                    }
                }
                DisclosureGroup("Сегменты и спикеры") {
                    ForEach(record.segments) { segment in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(segment.speaker ?? "Спикер")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                let seconds = max(0, Int(segment.start ?? 0))
                                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(segment.text)
                                .font(.footnote)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 4)
                    }
                }
                DisclosureGroup("Полная расшифровка") {
                    Text(record.transcript)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Аудио передаётся на сервер и в OpenAI для распознавания и конспекта. Ключ API хранится только на сервере.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var aiLibraryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Библиотека расшифровок", systemImage: "books.vertical")
                    .font(.headline)
                Spacer()
                Button {
                    aiProcessor.refreshLibrary()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Обновить библиотеку расшифровок")
            }
            TextField("Поиск по названию и тексту", text: $aiLibraryQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { aiProcessor.refreshLibrary(query: aiLibraryQuery) }
            if aiProcessor.recordings.isEmpty {
                Text(aiLibraryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "После обработки записей они появятся здесь."
                     : "По этому запросу ничего не найдено.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // The backend searches the full transcript, not only the short preview.
                let filtered = aiProcessor.recordings
                if filtered.isEmpty {
                    Text("Ничего не найдено")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                aiProcessor.openRecording(id: item.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayTitle)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(item.dateLabel + " · " + ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(item.transcriptPreview)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Button(role: .destructive) {
                                pendingAIRecordingDeletion = item
                            } label: {
                                Image(systemName: "trash")
                                    .font(.subheadline)
                            }
                            .accessibilityLabel("Удалить запись")
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
        }
        .cardStyle()
        .confirmationDialog(
            "Удалить запись «\(pendingAIRecordingDeletion?.displayTitle ?? "")»?",
            isPresented: Binding(
                get: { pendingAIRecordingDeletion != nil },
                set: { if !$0 { pendingAIRecordingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить запись и аудио", role: .destructive) {
                if let item = pendingAIRecordingDeletion {
                    aiProcessor.deleteRecording(id: item.id)
                }
                pendingAIRecordingDeletion = nil
            }
            Button("Отмена", role: .cancel) {
                pendingAIRecordingDeletion = nil
            }
        }
    }

    private var meetingRecorder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Запись встреч и заметок", systemImage: "waveform")
                .font(.headline)
            Toggle("Я уведомил участников и получил требуемое согласие на запись", isOn: $hasAcknowledgedMeetingRecordingNotice)
                .font(.footnote)
            Text(recorder.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                if recorder.isRecording {
                    recorder.stop()
                    if let url = recorder.latestFileURL { aiProcessor.process(fileURL: url) }
                } else if hasAcknowledgedMeetingRecordingNotice {
                    recorder.start()
                }
            } label: {
                Label(recorder.isRecording ? "Остановить запись" : "Начать запись",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .mint)
            .foregroundStyle(recorder.isRecording ? .white : .black)
            .disabled(!recorder.isRecording && !hasAcknowledgedMeetingRecordingNotice)
            Text("До начала записи получите согласие, требуемое законодательством для всех участников встречи.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Импорт готовой записи", systemImage: "square.and.arrow.down")
                .font(.headline)
            Button("Выбрать аудиофайл") {
                showingImporter = true
            }
            .buttonStyle(.bordered)
            if let importedFileName {
                Text("Добавлен файл: \(importedFileName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let importError {
                Text(importError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .cardStyle()
    }

    private var callMonitorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Состояние системных вызовов", systemImage: "phone.badge.waveform")
                .font(.headline)
            Text(callMonitor.callStateDescription)
                .font(.subheadline)
            Text("Наблюдение за системными вызовами не даёт доступа к их аудио. Запись доступна только для звонков, проведённых через сервис «Голос», либо для импортированных файлов.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var platformNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Важно о звонках", systemImage: "info.circle")
                .font(.headline)
            Text("Обычные номера доступны через собственный телефонный шлюз. WhatsApp, Telegram и FaceTime не перехватываются. Перед записью необходимо уведомить участников, получить требуемое согласие и соблюдать местные правила.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private func handleSystemCallURL(_ url: URL) {
        guard url.scheme?.lowercased() == "tel" else { return }

        let rawNumber = String(url.absoluteString.dropFirst(4))
            .removingPercentEncoding ?? String(url.absoluteString.dropFirst(4))
        let number = rawNumber.filter { $0.isNumber || $0 == "+" }

        guard !number.isEmpty else { return }
        phoneNumber = number
        pendingSystemCallNumber = number
        showingSystemCallPrompt = true
    }

    private func importAudio(_ result: Result<[URL], Error>) {
        do {
            guard let source = try result.get().first else { return }
            let didAccess = source.startAccessingSecurityScopedResource()
            defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            let importedURL: URL
            if FileManager.default.fileExists(atPath: destination.path) {
                let renamed = directory.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: renamed)
                importedURL = renamed
            } else {
                try FileManager.default.copyItem(at: source, to: destination)
                importedURL = destination
            }
            importedFileName = importedURL.lastPathComponent
            importError = nil
            aiProcessor.process(fileURL: importedURL)
        } catch {
            importError = "Не удалось импортировать файл: \(error.localizedDescription)"
        }
    }
}


private struct VoiceRecordingRow: View {
    let recording: VoiceRecording
    @ObservedObject var store: VoiceRecordingsStore
    @ObservedObject var aiProcessor: AIRecordingProcessor
    @State private var isDownloading = false
    @State private var downloadedURL: URL?
    @State private var downloadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(recording.dateLabel)
                        .font(.subheadline.weight(.medium))
                    Text("\(recording.durationLabel) · \(recording.channels) канал(а)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let downloadedURL {
                    ShareLink(item: downloadedURL) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Поделиться аудиозаписью")
                } else {
                    Button {
                        isDownloading = true
                        downloadError = nil
                        store.download(recording) { result in
                            isDownloading = false
                            switch result {
                            case .success(let url):
                                downloadedURL = url
                                aiProcessor.process(fileURL: url)
                            case .failure(let error): downloadError = error.localizedDescription
                            }
                        }
                    } label: {
                        if isDownloading {
                            ProgressView()
                        } else {
                            Label("Скачать и расшифровать", systemImage: "waveform")
                        }
                    }
                    .disabled(isDownloading)
                }
            }
            if let downloadError {
                Text(downloadError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 3)
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
