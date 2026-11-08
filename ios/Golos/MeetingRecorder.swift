import AVFoundation
import Combine
import Foundation

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
    @Published private(set) var errorMessage: String?

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
        guard audioData.count <= 24 * 1024 * 1024 else {
            status = "Файл больше 24 МБ. Сожмите запись или разделите её на части"
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
