import Combine
import Foundation
import Security

/// Stores the backend URL as a normal preference and the app API token in iOS Keychain.
final class VoiceServerConfiguration: ObservableObject {
    static let shared = VoiceServerConfiguration()

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.serverURLKey) }
    }

    @Published var apiToken: String {
        didSet { Keychain.save(apiToken, account: Self.apiTokenAccount) }
    }

    fileprivate static let service = "com.blackministers.golos"
    private static let serverURLKey = "golos.voice.serverURL"
    private static let apiTokenAccount = "voice-backend-api-token"

    private init() {
        serverURL = UserDefaults.standard.string(forKey: Self.serverURLKey) ?? ""
        apiToken = Keychain.read(account: Self.apiTokenAccount) ?? ""
    }

    var isConfigured: Bool {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host != nil else { return false }
        return !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum Keychain {
    static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: VoiceServerConfiguration.service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: VoiceServerConfiguration.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}