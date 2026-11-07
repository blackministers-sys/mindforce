import Foundation

private struct VoiceTokenResponse: Decodable {
    let accessToken: String
    let identity: String
    let expiresIn: Int
}

final class VoiceTokenService {
    static let shared = VoiceTokenService()
    private init() {}

    enum ServiceError: LocalizedError {
        case configurationMissing
        case invalidResponse
        case serverMessage(String)

        var errorDescription: String? {
            switch self {
            case .configurationMissing:
                return "Сначала укажите HTTPS-адрес телефонного сервера и ключ доступа в настройках."
            case .invalidResponse:
                return "Сервер вернул непонятный ответ. Проверьте адрес и настройки backend."
            case .serverMessage(let message):
                return message
            }
        }
    }

    func fetchAccessToken(completion: @escaping (Result<String, Error>) -> Void) {
        let configuration = VoiceServerConfiguration.shared
        guard configuration.isConfigured,
              let baseURL = URL(string: configuration.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            DispatchQueue.main.async { completion(.failure(ServiceError.configurationMissing)) }
            return
        }

        let endpoint = baseURL.appendingPathComponent("v1/voice/token")
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["identity": "golos-user"])

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                DispatchQueue.main.async { completion(.failure(ServiceError.invalidResponse)) }
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let detail = message?["error"] as? String ?? "HTTP \(http.statusCode)"
                DispatchQueue.main.async { completion(.failure(ServiceError.serverMessage(detail))) }
                return
            }
            do {
                let token = try JSONDecoder().decode(VoiceTokenResponse.self, from: data)
                DispatchQueue.main.async { completion(.success(token.accessToken)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(ServiceError.invalidResponse)) }
            }
        }.resume()
    }
}