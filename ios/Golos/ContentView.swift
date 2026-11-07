import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @StateObject private var callMonitor = CallMonitor()
    @StateObject private var recorder = MeetingRecorder()
    @ObservedObject private var voice = VoiceCallManager.shared
    @ObservedObject private var configuration = VoiceServerConfiguration.shared
    @StateObject private var recordingsStore = VoiceRecordingsStore()

    @State private var showingImporter = false
    @State private var importedFileName: String?
    @State private var importError: String?
    @State private var serverURLDraft = VoiceServerConfiguration.shared.serverURL
    @State private var apiTokenDraft = ""
    @State private var phoneNumber = ""
    @State private var hasAcknowledgedRecordingNotice = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    voiceSettings
                    phoneDialer
                    recordingsLibrary
                    meetingRecorder
                    importCard
                    callMonitorCard
                    platformNote
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Голос")
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                importAudio(result)
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
            Button("Сохранить настройки") {
                configuration.save(serverURL: serverURLDraft, apiToken: apiTokenDraft)
                apiTokenDraft = ""
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
            Toggle("Я уведомлён о записи и проверил согласие собеседника", isOn: $hasAcknowledgedRecordingNotice)
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
                VoiceRecordingRow(recording: recording, store: recordingsStore)
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

    private var meetingRecorder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Запись встреч и заметок", systemImage: "waveform")
                .font(.headline)
            Text(recorder.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                recorder.isRecording ? recorder.stop() : recorder.start()
            } label: {
                Label(recorder.isRecording ? "Остановить запись" : "Начать запись",
                      systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .mint)
            .foregroundStyle(recorder.isRecording ? .white : .black)
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

    private func importAudio(_ result: Result<[URL], Error>) {
        do {
            guard let source = try result.get().first else { return }
            let didAccess = source.startAccessingSecurityScopedResource()
            defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                let renamed = directory.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: renamed)
                importedFileName = renamed.lastPathComponent
            } else {
                try FileManager.default.copyItem(at: source, to: destination)
                importedFileName = destination.lastPathComponent
            }
            importError = nil
        } catch {
            importError = "Не удалось импортировать файл: \(error.localizedDescription)"
        }
    }
}


private struct VoiceRecordingRow: View {
    let recording: VoiceRecording
    @ObservedObject var store: VoiceRecordingsStore
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
                            case .success(let url): downloadedURL = url
                            case .failure(let error): downloadError = error.localizedDescription
                            }
                        }
                    } label: {
                        if isDownloading {
                            ProgressView()
                        } else {
                            Label("Скачать", systemImage: "arrow.down.circle")
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
