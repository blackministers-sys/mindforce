import Combine
import Foundation

struct VoiceRecording: Decodable, Identifiable {
    let recordingSid: String
    let callSid: String
    let status: String
    let duration: Int
    let channels: Int
    let createdAt: String
    let audioPath: String

    var id: String { recordingSid }

    var durationLabel: String {
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var dateLabel: String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: createdAt) else { return createdAt }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct VoiceRecordingsResponse: Decodable {
    let recordings: [VoiceRecording]
}

final class VoiceRecordingsStore: ObservableObject {
    @Published private(set) var recordings: [VoiceRecording] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message = "Записи пока не загружены"

    func refresh() {
        let configuration = VoiceServerConfiguration.shared
        guard configuration.isConfigured,
              let baseURL = URL(string: configuration.serverURL) else {
            message = "Сначала настройте телефонный сервер"
            return
        }

        isLoading = true
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/voice/recordings"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false

                if let error {
                    self.message = "Не удалось загрузить записи: \(error.localizedDescription)"
                    return
                }
                guard let http = response as? HTTPURLResponse, let data else {
                    self.message = "Сервер не вернул список записей"
                    return
                }
                guard (200..<300).contains(http.statusCode) else {
                    self.message = "Ошибка сервера: HTTP \(http.statusCode)"
                    return
                }
                do {
                    let decoded = try JSONDecoder().decode(VoiceRecordingsResponse.self, from: data)
                    self.recordings = decoded.recordings
                    self.message = decoded.recordings.isEmpty ? "Завершённых записей пока нет" : "Записей: \(decoded.recordings.count)"
                } catch {
                    self.message = "Не удалось разобрать список записей: \(error.localizedDescription)"
                }
            }
        }.resume()
    }

    func download(_ recording: VoiceRecording, completion: @escaping (Result<URL, Error>) -> Void) {
        let configuration = VoiceServerConfiguration.shared
        guard configuration.isConfigured,
              let baseURL = URL(string: configuration.serverURL) else {
            completion(.failure(VoiceRecordingsError.notConfigured))
            return
        }

        let url = baseURL
            .appendingPathComponent("v1/voice/recordings")
            .appendingPathComponent(recording.recordingSid)
            .appendingPathComponent("audio")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.downloadTask(with: request) { temporaryURL, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let temporaryURL else {
                DispatchQueue.main.async {
                    completion(.failure(VoiceRecordingsError.downloadFailed))
                }
                return
            }

            do {
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destination = directory.appendingPathComponent(recording.recordingSid + ".mp3")
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                DispatchQueue.main.async { completion(.success(destination)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }
}

private enum VoiceRecordingsError: LocalizedError {
    case notConfigured
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Сначала настройте телефонный сервер"
        case .downloadFailed: return "Не удалось скачать аудиозапись"
        }
    }
}
