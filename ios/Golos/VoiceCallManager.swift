import AVFoundation
import CallKit
import Combine
import Foundation
import PushKit
import TwilioVoice

/// Manages calls that are explicitly placed through the Golos VoIP service.
/// It does not access audio from the iPhone's cellular Phone app or other messengers.
final class VoiceCallManager: NSObject, ObservableObject {
    static let shared = VoiceCallManager()

    @Published private(set) var status = "Телефония не подключена"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isCallActive = false
    @Published private(set) var isMuted = false
    @Published private(set) var isIncomingCall = false

    var connectionStatus: String {
        VoiceServerConfiguration.shared.isConfigured ? "Сервис подключён" : "Сервис не настроен"
    }

    var callStatus: String { status }

    func configure(serverURL: String, bootstrapToken: String) {
        VoiceServerConfiguration.shared.save(
            serverURL: serverURL,
            apiToken: bootstrapToken
        )
        errorMessage = nil
        status = VoiceServerConfiguration.shared.isConfigured
            ? "Настройки телефонного сервера сохранены"
            : "Телефонный сервер не настроен"
    }

    func placeCall(to number: String) {
        startCall(to: number)
    }

    func hangUp() {
        endCall()
    }

    func startPushRegistration() {
        VoicePushManager.shared.start()
    }

    private let callController = CXCallController()
    private let audioDevice = DefaultAudioDevice()
    private let provider: CXProvider
    private var pendingDestination: String?
    private var activeCall: Call?
    private var activeCallUUID: UUID?
    private var activeCallInvites: [UUID: CallInvite] = [:]
    private var userInitiatedDisconnect = false
    private var activeCallWasIncoming = false
    private var pendingPushDeviceToken: Data?

    private override init() {
        let configuration = CXProviderConfiguration(localizedName: "Голос")
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportsVideo = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: .main)
        TwilioVoiceSDK.audioDevice = audioDevice
    }

    func startCall(to rawNumber: String) {
        let number = rawNumber.filter { $0.isNumber || $0 == "+" }
        guard number.range(of: #"^\+[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil else {
            errorMessage = "Введите номер в международном формате, например +31612345678."
            return
        }
        guard VoiceServerConfiguration.shared.isConfigured else {
            errorMessage = "Настройте HTTPS-адрес backend и ключ доступа ниже."
            return
        }

        pendingDestination = number
        errorMessage = nil
        let uuid = UUID()
        let handle = CXHandle(type: .phoneNumber, value: number)
        let action = CXStartCallAction(call: uuid, handle: handle)
        callController.request(CXTransaction(action: action)) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    self?.errorMessage = "Не удалось начать вызов: \(error.localizedDescription)"
                }
            }
        }
    }

    func endCall() {
        guard let uuid = activeCallUUID else { return }
        let action = CXEndCallAction(call: uuid)
        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error {
                DispatchQueue.main.async {
                    self?.errorMessage = "Не удалось завершить вызов: \(error.localizedDescription)"
                }
            }
        }
    }

    func toggleMute() {
        guard let call = activeCall else { return }
        let nextValue = !call.isMuted
        call.isMuted = nextValue
        isMuted = nextValue
    }

    // MARK: VoIP push registration

    func credentialsUpdated(_ credentials: PKPushCredentials) {
        pendingPushDeviceToken = credentials.token
        registerPushDeviceTokenIfPossible()
    }

    func configurationDidChange() {
        registerPushDeviceTokenIfPossible()
    }

    /// Tests the authenticated backend token endpoint without initiating a call.
    func validateConfiguration() {
        guard VoiceServerConfiguration.shared.isConfigured else {
            status = "Укажите HTTPS-адрес сервера и персональный ключ доступа"
            errorMessage = "Настройки неполные."
            return
        }
        status = "Проверяем подключение к телефонному серверу…"
        errorMessage = nil
        VoiceTokenService.shared.fetchAccessToken { [weak self] result in
            switch result {
            case .success:
                self?.status = "Сервер подключён. Можно совершать звонки."
                self?.errorMessage = nil
            case .failure(let error):
                self?.status = "Не удалось подключиться к серверу"
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func registerPushDeviceTokenIfPossible() {
        guard let deviceToken = pendingPushDeviceToken,
              VoiceServerConfiguration.shared.isConfigured else {
            status = "Настройте телефонный сервер для включения входящих звонков"
            return
        }

        VoiceTokenService.shared.fetchAccessToken { [weak self] result in
            switch result {
            case .success(let token):
                TwilioVoiceSDK.register(accessToken: token, deviceToken: deviceToken) { error in
                    DispatchQueue.main.async {
                        if let error {
                            self?.errorMessage = "Не удалось зарегистрировать PushKit: \(error.localizedDescription)"
                            self?.status = "Входящие звонки не настроены"
                        } else {
                            self?.status = "Телефония готова к входящим и исходящим звонкам"
                            self?.errorMessage = nil
                        }
                    }
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    self?.status = "Ожидает настройки телефонного сервера"
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func incomingPushReceived(_ payload: PKPushPayload) {
        TwilioVoiceSDK.handleNotification(payload.dictionaryPayload, delegate: self, delegateQueue: .main)
    }

    // MARK: CallKit actions

    private func connectOutgoingCall(action: CXStartCallAction, destination: String) {
        VoiceTokenService.shared.fetchAccessToken { [weak self] result in
            guard let self else { action.fail(); return }
            switch result {
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.status = "Не удалось подключиться"
                action.fail()
            case .success(let token):
                let options = ConnectOptions(accessToken: token) { builder in
                    builder.params = ["to": destination]
                    builder.uuid = action.callUUID
                }
                let call = TwilioVoiceSDK.connect(options: options, delegate: self)
                self.activeCall = call
                self.activeCallUUID = action.callUUID
                self.isCallActive = true
                self.isIncomingCall = false
                self.activeCallWasIncoming = false
                self.status = "Вызов номера \(destination)…"
                action.fulfill()
            }
        }
    }

    private func acceptIncomingCall(action: CXAnswerCallAction) {
        guard let invite = activeCallInvites[action.callUUID] else {
            action.fail()
            return
        }
        let options = AcceptOptions(callInvite: invite) { builder in
            builder.uuid = invite.uuid
        }
        activeCall = invite.accept(options: options, delegate: self)
        activeCallUUID = action.callUUID
        activeCallInvites.removeValue(forKey: action.callUUID)
        isCallActive = true
        isIncomingCall = false
        activeCallWasIncoming = true
        status = "Подключение входящего звонка…"
        action.fulfill()
    }

    private func resetCallState() {
        activeCall = nil
        activeCallUUID = nil
        isCallActive = false
        isIncomingCall = false
        isMuted = false
        userInitiatedDisconnect = false
        activeCallWasIncoming = false
        status = "Телефония готова"
    }
}

extension VoiceCallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        audioDevice.isEnabled = false
        resetCallState()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioDevice.isEnabled = true
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        audioDevice.isEnabled = false
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        guard let destination = pendingDestination else {
            errorMessage = "Не задан номер для вызова."
            action.fail()
            return
        }
        connectOutgoingCall(action: action, destination: destination)
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        acceptIncomingCall(action: action)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let invite = activeCallInvites.removeValue(forKey: action.callUUID) {
            invite.reject()
            resetCallState()
        } else if let call = activeCall {
            userInitiatedDisconnect = true
            call.disconnect()
        } else {
            resetCallState()
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        activeCall?.isMuted = action.isMuted
        isMuted = action.isMuted
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        guard let call = activeCall else { action.fail(); return }
        call.isOnHold = action.isOnHold
        action.fulfill()
    }
}

extension VoiceCallManager: NotificationDelegate {
    func callInviteReceived(callInvite: CallInvite) {
        activeCallInvites[callInvite.uuid] = callInvite
        isIncomingCall = true
        let caller = (callInvite.from ?? "Входящий звонок").replacingOccurrences(of: "client:", with: "")
        status = "Входящий вызов: \(caller)"

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: caller)
        update.supportsDTMF = true
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.hasVideo = false
        provider.reportNewIncomingCall(with: callInvite.uuid, update: update) { [weak self] error in
            if let error {
                self?.errorMessage = "Не удалось показать входящий звонок: \(error.localizedDescription)"
                self?.activeCallInvites.removeValue(forKey: callInvite.uuid)
                self?.isIncomingCall = false
            }
        }
    }

    func cancelledCallInviteReceived(cancelledCallInvite: CancelledCallInvite, error: Error) {
        guard let invite = activeCallInvites.values.first(where: { $0.callSid == cancelledCallInvite.callSid }) else { return }
        activeCallInvites.removeValue(forKey: invite.uuid)
        provider.reportCall(with: invite.uuid, endedAt: Date(), reason: .remoteEnded)
        if invite.uuid == activeCallUUID { resetCallState() }
    }
}

extension VoiceCallManager: CallDelegate {
    func callDidStartRinging(call: Call) {
        status = "Идёт вызов…"
    }

    func callDidConnect(call: Call) {
        status = "Разговор начался — запись выполняется на сервере"
        isCallActive = true
        if !activeCallWasIncoming, let uuid = call.uuid {
            provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        }
    }

    func callIsReconnecting(call: Call, error: Error) {
        status = "Восстановление соединения…"
    }

    func callDidReconnect(call: Call) {
        status = "Соединение восстановлено"
    }

    func callDidFailToConnect(call: Call, error: Error) {
        errorMessage = "Звонок не состоялся: \(error.localizedDescription)"
        status = "Ошибка звонка"
        if let uuid = call.uuid {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .failed)
        }
        resetCallState()
    }

    func callDidDisconnect(call: Call, error: Error?) {
        if !userInitiatedDisconnect, let uuid = call.uuid {
            provider.reportCall(with: uuid, endedAt: Date(), reason: error == nil ? .remoteEnded : .failed)
        }
        if let error {
            errorMessage = "Звонок завершён с ошибкой: \(error.localizedDescription)"
        }
        resetCallState()
    }
}