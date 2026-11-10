import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class MeetingRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var status = "Готов к записи"
    @Published private(set) var latestFileURL: URL?

    private var recorder: AVAudioRecorder?

    func start() {
        guard !isRecording else { return }
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.status = "Нет разрешения на микрофон"
                    return
                }
                self.startWithPermission()
            }
        }
    }

    private func startWithPermission() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = directory.appendingPathComponent("Golos-\(Int(Date().timeIntervalSince1970)).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.delegate = self
            newRecorder.record()
            recorder = newRecorder
            latestFileURL = url
            isRecording = true
            status = "Идёт запись микрофона"
        } catch {
            status = "Не удалось начать запись: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRecording else { return }
        recorder?.stop()
        recorder = nil
        isRecording = false
        status = "Запись сохранена в библиотеке приложения"
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}


struct AIRecordingTask: Decodable, Identifiable {
    let task: String
    let owner: String?
    let dueDate: String?

    var id: String { task + (owner ?? "") + (dueDate ?? "") }

    enum CodingKeys: String, CodingKey {
        case task
        case owner
        case dueDate = "due_date"
    }
}

struct AIRecordingSummary: Decodable {
    let title: String
    let summary: String
    let keyPoints: [String]
    let decisions: [String]
    let tasks: [AIRecordingTask]
    let openQuestions: [String]

    enum CodingKeys: String, CodingKey {
        case title
        case summary
        case keyPoints = "key_points"
        case decisions
        case tasks
        case openQuestions = "open_questions"
    }
}

struct AIRecordingSegment: Decodable, Identifiable {
    let start: Double?
    let end: Double?
    let speaker: String?
    let text: String

    var id: String { "\(start ?? 0)-\(end ?? 0)-\(speaker ?? "")-\(text)" }
}

struct AIRecordingRecord: Decodable, Identifiable {
    let id: String
    let fileName: String
    let createdAt: String
    let fileSize: Int
    let transcript: String
    let segments: [AIRecordingSegment]
    let summary: AIRecordingSummary?
    let summaryWarning: String?
}

private struct AIRecordingEnvelope: Decodable {
    let recording: AIRecordingRecord
}

private struct AIErrorEnvelope: Decodable {
    let error: String?
}

@MainActor
final class AIRecordingProcessor: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var status = "Записи можно расшифровывать и превращать в конспекты"
    @Published private(set) var latestRecord: AIRecordingRecord?
    @Published private(set) var recordings: [AIRecordingLibraryItem] = []
    @Published private(set) var latestAudioURL: URL?
    @Published private(set) var latestAudioRecordID: String?
    @Published private(set) var isDownloadingAudio = false
    @Published private(set) var errorMessage: String?

    func refreshLibrary(query: String = "") {
        let configuration = VoiceServerConfiguration.shared
        guard configuration.isConfigured, let baseURL = URL(string: configuration.serverURL) else { return }
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/ai/recordings"), resolvingAgainstBaseURL: false)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            components?.queryItems = [URLQueryItem(name: "q", value: trimmedQuery)]
        }
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                guard let http = response as? HTTPURLResponse, let data, (200..<300).contains(http.statusCode) else {
                    return
                }
                do {
                    self.recordings = try JSONDecoder().decode(AIRecordingLibraryEnvelope.self, from: data).recordings
                } catch {
                    self.errorMessage = "Не удалось прочитать библиотеку: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    func openRecording(id: String) {
        let configuration = VoiceServerConfiguration.shared
        guard configuration.isConfigured, let baseURL = URL(string: configuration.serverURL) else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/ai/recordings").appendingPathComponent(id))
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                guard let http = response as? HTTPURLResponse, let data, (200..<300).contains(http.statusCode) else {
                    self.errorMessage = "Не удалось открыть запись"
                    return
                }
                do {
                    self.latestRecord = try JSONDecoder().decode(AIRecordingEnvelope.self, from: data).recording
                    self.status = "Запись открыта из библиотеки"
                    self.errorMessage = nil
                } catch {
                    self.errorMessage = "Не удалось прочитать запись: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    func downloadRecordingAudio(id: String, fileName: String) {
        let configuration = VoiceServerConfiguration.shared
        guard configuration.isConfigured, let baseURL = URL(string: configuration.serverURL) else { return }
        guard !isDownloadingAudio else { return }

        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/ai/recordings").appendingPathComponent(id).appendingPathComponent("audio")
        )
        request.httpMethod = "GET"
        request.timeoutInterval = 600
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")
        isDownloadingAudio = true
        errorMessage = nil

        URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDownloadingAudio = false

                if let error {
                    self.errorMessage = "Не удалось скачать аудио: \(error.localizedDescription)"
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let temporaryURL else {
                    self.errorMessage = "Сервер не отдал оригинальный аудиофайл"
                    return
                }

                let fileExtension = URL(fileURLWithPath: fileName).pathExtension
                    .lowercased()
                    .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(id + (fileExtension.isEmpty ? ".audio" : "." + fileExtension))
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporaryURL, to: destination)
                    self.latestAudioURL = destination
                    self.latestAudioRecordID = id
                    self.status = "Оригинальное аудио скачано"
                } catch {
                    self.errorMessage = "Не удалось сохранить аудио: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    func deleteRecording(id: String) {
        let configuration = VoiceServerConfiguration.shared
        guard configuration.isConfigured, let baseURL = URL(string: configuration.serverURL) else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/ai/recordings").appendingPathComponent(id))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    self.errorMessage = "Не удалось удалить запись"
                    return
                }
                if self.latestRecord?.id == id { self.latestRecord = nil }
                if self.latestAudioRecordID == id {
                    self.latestAudioURL = nil
                    self.latestAudioRecordID = nil
                }
                self.recordings.removeAll { $0.id == id }
                self.status = "Запись удалена"
            }
        }.resume()
    }

    func process(fileURL: URL) {
        let configuration = VoiceServerConfiguration.shared
        guard configuration.isConfigured,
              let baseURL = URL(string: configuration.serverURL) else {
            status = "Сначала настройте HTTPS-сервер и ключ приложения"
            return
        }
        guard !isProcessing else {
            status = "Предыдущая запись ещё обрабатывается"
            return
        }

        let fileExtension = fileURL.pathExtension.lowercased()
        let mimeType: String
        switch fileExtension {
        case "m4a", "mp4": mimeType = "audio/mp4"
        case "mp3", "mpeg", "mpga": mimeType = "audio/mpeg"
        case "wav": mimeType = "audio/wav"
        case "webm": mimeType = "audio/webm"
        default:
            status = "Формат файла не поддерживается"
            return
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL)
        } catch {
            status = "Не удалось прочитать аудиофайл: \(error.localizedDescription)"
            return
        }
        guard !audioData.isEmpty else {
            status = "Аудиофайл пустой"
            return
        }
        guard audioData.count <= 23 * 1024 * 1024 else {
            status = "Файл больше 23 МБ. Сожмите запись или разделите её на части"
            return
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/ai/recordings"))
        request.httpMethod = "POST"
        request.httpBody = audioData
        request.timeoutInterval = 600
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        let encodedName = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? "recording.\(fileExtension)"
        request.setValue(encodedName, forHTTPHeaderField: "X-File-Name")

        isProcessing = true
        errorMessage = nil
        status = "Загружаю аудио и готовлю расшифровку…"

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessing = false

                if let error {
                    self.errorMessage = error.localizedDescription
                    self.status = "Не удалось обработать запись"
                    return
                }
                guard let http = response as? HTTPURLResponse, let data else {
                    self.status = "Сервер не вернул результат обработки"
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    let serverError = (try? JSONDecoder().decode(AIErrorEnvelope.self, from: data))?.error
                    self.errorMessage = serverError ?? "HTTP \(http.statusCode)"
                    self.status = "Ошибка AI-обработки"
                    return
                }
                do {
                    let envelope = try JSONDecoder().decode(AIRecordingEnvelope.self, from: data)
                    self.latestRecord = envelope.recording
                    self.refreshLibrary()
                    if let warning = envelope.recording.summaryWarning {
                        self.status = "Расшифровка готова; конспект требует повторной обработки"
                        self.errorMessage = warning
                    } else {
                        self.status = "Расшифровка и AI-конспект готовы"
                    }
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.status = "Не удалось прочитать ответ сервера"
                }
            }
        }.resume()
    }
}


struct AIRecordingLibraryItem: Decodable, Identifiable {
    let id: String
    let fileName: String
    let createdAt: String
    let fileSize: Int
    let summary: AIRecordingSummary?
    let summaryWarning: String?
    let transcriptPreview: String

    var displayTitle: String {
        let title = summary?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? fileName : title
    }

    var dateLabel: String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: createdAt) else { return createdAt }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct AIRecordingLibraryEnvelope: Decodable {
    let recordings: [AIRecordingLibraryItem]
}



/// Performs speech recognition strictly on the device. No audio is uploaded.
@MainActor
final class LocalSpeechTranscriber: ObservableObject {
    @Published private(set) var isTranscribing = false
    @Published private(set) var status = "Готов к локальной расшифровке"
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?

    private var recognitionTask: SFSpeechRecognitionTask?

    func transcribe(fileURL: URL) {
        guard !isTranscribing else {
            status = "Дождитесь завершения предыдущей расшифровки"
            return
        }
        transcript = ""
        errorMessage = nil
        status = "Запрашиваем разрешение на распознавание речи…"
        SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
            DispatchQueue.main.async {
                guard let self else { return }
                guard authorization == .authorized else {
                    self.status = "Нет разрешения на распознавание речи"
                    self.errorMessage = "Разрешите распознавание речи в настройках iPhone и повторите попытку."
                    return
                }
                self.startRecognition(fileURL: fileURL)
            }
        }
    }

    private func startRecognition(fileURL: URL) {
        let locale = Locale(identifier: "ru-RU")
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            status = "Русский язык недоступен"
            errorMessage = "Системный распознаватель речи не поддерживает русский язык на этом устройстве."
            return
        }
        guard recognizer.isAvailable else {
            status = "Распознавание сейчас недоступно"
            errorMessage = "Проверьте настройки речи и попробуйте ещё раз."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            status = "Локальная модель русского языка недоступна"
            errorMessage = "На этом iPhone системный движок не подтверждает офлайн-распознавание русского языка. Чтобы не отправлять аудио в интернет, обработка остановлена."
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        isTranscribing = true
        status = "Распознаём аудио на iPhone…"
        recognitionTask?.cancel()
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.isTranscribing = false
                        self.status = "Локальная расшифровка готова"
                        self.saveTranscript(for: fileURL)
                        self.recognitionTask = nil
                    }
                }
                if let error {
                    self.isTranscribing = false
                    self.status = "Не удалось завершить расшифровку"
                    self.errorMessage = error.localizedDescription
                    self.recognitionTask = nil
                }
            }
        }
    }

    private func saveTranscript(for audioURL: URL) {
        let textURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        do {
            try transcript.write(to: textURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Текст распознан, но не удалось сохранить файл: \(error.localizedDescription)"
        }
    }

    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        isTranscribing = false
        status = "Расшифровка остановлена"
    }
}
