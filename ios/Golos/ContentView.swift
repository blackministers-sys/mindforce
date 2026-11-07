import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @StateObject private var callMonitor = CallMonitor()
    @StateObject private var recorder = MeetingRecorder()
    @ObservedObject private var voice = VoiceCallManager.shared

    @State private var showingImporter = false
    @State private var importedFileName: String?
    @State private var importError: String?
    @State private var serverURL = UserDefaults.standard.string(forKey: "golos.voice.serverURL") ?? ""
    @State private var bootstrapKey = ""
    @State private var phoneNumber = ""
    @State private var hasAcknowledgedConsent = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    voiceSettings
                    phoneDialer
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
            Text(voice.connectionStatus)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(voice.connectionStatus.contains("подключён") ? .green : .secondary)
            TextField("HTTPS-адрес сервера", text: $serverURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            SecureField("Ключ доступа к «Голосу»", text: $bootstrapKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Button("Сохранить и подключить") {
                voice.configure(serverURL: serverURL, bootstrapToken: bootstrapKey)
                bootstrapKey = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(serverURL.isEmpty || bootstrapKey.isEmpty)
            Text("Секрет Twilio хранится только на сервере. Здесь нужен отдельный ключ доступа приложения.")
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
            Toggle("Я уведомлён о записи и согласии собеседника", isOn: $hasAcknowledgedConsent)
                .font(.footnote)
            Button {
                voice.placeCall(to: phoneNumber)
            } label: {
                Label("Позвонить и записать", systemImage: "phone.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasAcknowledgedConsent || phoneNumber.isEmpty || voice.connectionStatus == "Сервис не настроен")
            if voice.isCallActive {
                Button(role: .destructive) {
                    voice.hangUp()
                } label: {
                    Label("Завершить звонок", systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Text(voice.callStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Для входящих звонков на подключённый Twilio-номер приложение сможет принимать системный вызов через CallKit.")
                .font(.caption)
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
            Text("Обычные номера доступны через собственный телефонный шлюз. WhatsApp, Telegram и FaceTime не перехватываются. Перед записью необходимо уведомить участников и соблюдать местные требования к согласию.")
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

private extension View {
    func cardStyle() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
