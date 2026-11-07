import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @StateObject private var callMonitor = CallMonitor()
    @StateObject private var recorder = MeetingRecorder()
    @State private var showingImporter = false
    @State private var importedFileName: String?
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Состояние звонков", systemImage: "phone.badge.waveform")
                            .font(.headline)
                        Text(callMonitor.callStateDescription)
                            .font(.title3.weight(.semibold))
                        Text("CallKit может сообщать состояние некоторых вызовов, но не предоставляет стороннему приложению аудиопоток разговора.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

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
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(recorder.isRecording ? .red : .mint)
                        .foregroundStyle(recorder.isRecording ? .white : .black)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Ограничение iOS", systemImage: "info.circle")
                            .font(.headline)
                        Text("Это технический прототип. Он не записывает звук обычных сотовых звонков, WhatsApp, Telegram или FaceTime. Запись микрофона во время чужого звонка не является способом получить звук собеседника и может быть заблокирована системой.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Автоматический запуск скрытой записи не включён. Перед записью разговоров нужно обеспечить уведомление и согласие участников.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
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
