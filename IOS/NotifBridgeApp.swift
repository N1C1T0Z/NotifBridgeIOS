// NotifBridge - iOS App
// Requires: iOS 16+, Swift 5.9+
// Permissions needed in Info.plist:
//   NSMicrophoneUsageDescription
//   UNUserNotificationCenter authorization
// Target: NotifBridgeApp

import SwiftUI
import UserNotifications
import AVFoundation
import Combine

// MARK: - Entry Point

@main
struct NotifBridgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(NotifBridgeManager.shared)
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotifBridgeManager.shared.requestNotificationPermission()
        return true
    }

    // Intercept notifications when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let notif = BridgedNotification(from: notification)
        NotifBridgeManager.shared.addNotification(notif)
        NotifBridgeManager.shared.sendToWindows(notif)
        completionHandler([.banner, .sound, .badge])
    }

    // Handle notification response (user tapped or replied)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        if let textResponse = response as? UNTextInputNotificationResponse {
            NotifBridgeManager.shared.handleReply(
                to: response.notification.request.identifier,
                text: textResponse.userText
            )
        }
        completionHandler()
    }
}

// MARK: - Model

struct BridgedNotification: Identifiable, Codable {
    var id: String
    var appName: String
    var title: String
    var body: String
    var timestamp: Date
    var hasAudio: Bool
    var audioBase64: String?
    var replied: Bool = false
    var replyText: String?

    init(from notification: UNNotification) {
        self.id = notification.request.identifier
        self.appName = notification.request.content.userInfo["appName"] as? String ?? "App"
        self.title = notification.request.content.title
        self.body = notification.request.content.body
        self.timestamp = notification.date
        self.hasAudio = false
    }

    init(id: String = UUID().uuidString, appName: String, title: String, body: String,
         hasAudio: Bool = false, audioBase64: String? = nil) {
        self.id = id
        self.appName = appName
        self.title = title
        self.body = body
        self.timestamp = Date()
        self.hasAudio = hasAudio
        self.audioBase64 = audioBase64
    }
}

// MARK: - Manager

class NotifBridgeManager: NSObject, ObservableObject {
    static let shared = NotifBridgeManager()

    @Published var notifications: [BridgedNotification] = []
    @Published var isConnected = false
    @Published var serverIP: String = "192.168.1.100"
    @Published var serverPort: String = "8765"
    @Published var isRecording = false
    @Published var recordingForID: String? = nil

    private var webSocketTask: URLSessionWebSocketTask?
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingURL: URL?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Permissions

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            print("Notification permission: \(granted)")
        }
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    // MARK: - Notification Management

    func addNotification(_ notif: BridgedNotification) {
        DispatchQueue.main.async {
            self.notifications.insert(notif, at: 0)
        }
    }

    func sendReply(to notifID: String, text: String) {
        guard var notif = notifications.first(where: { $0.id == notifID }) else { return }
        notif.replied = true
        notif.replyText = text

        if let idx = notifications.firstIndex(where: { $0.id == notifID }) {
            notifications[idx] = notif
        }

        let packet: [String: Any] = [
            "type": "reply",
            "notifID": notifID,
            "text": text
        ]
        sendPacket(packet)
    }

    func handleReply(to notifID: String, text: String) {
        DispatchQueue.main.async {
            self.sendReply(to: notifID, text: text)
        }
    }

    // MARK: - Audio Recording

    func startRecording(for notifID: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .default)
        try? session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice_\(notifID).m4a")
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 12000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        audioRecorder = try? AVAudioRecorder(url: url, settings: settings)
        audioRecorder?.record()

        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingForID = notifID
        }
    }

    func stopRecordingAndSend() {
        audioRecorder?.stop()
        try? AVAudioSession.sharedInstance().setActive(false)

        DispatchQueue.main.async {
            self.isRecording = false
        }

        guard let url = recordingURL, let notifID = recordingForID else { return }
        recordingForID = nil

        if let audioData = try? Data(contentsOf: url) {
            let base64 = audioData.base64EncodedString()
            let packet: [String: Any] = [
                "type": "voice_reply",
                "notifID": notifID,
                "audioBase64": base64,
                "format": "m4a"
            ]
            sendPacket(packet)

            if let idx = notifications.firstIndex(where: { $0.id == notifID }) {
                notifications[idx].replied = true
                notifications[idx].replyText = "🎤 Message vocal envoyé"
            }
        }
    }

    func playAudio(base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("playback.m4a")
        try? data.write(to: url)

        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.play()
    }

    // MARK: - WebSocket

    func connect() {
        let urlString = "ws://\(serverIP):\(serverPort)"
        guard let url = URL(string: urlString) else { return }

        webSocketTask = URLSession.shared.webSocketTask(with: url)
        webSocketTask?.resume()

        DispatchQueue.main.async { self.isConnected = true }
        receiveLoop()

        // Identify as iOS client
        sendPacket(["type": "hello", "client": "ios"])
    }

    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        DispatchQueue.main.async { self.isConnected = false }
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self?.handleIncoming(text)
                }
                self?.receiveLoop()
            case .failure:
                DispatchQueue.main.async { self?.isConnected = false }
            }
        }
    }

    private func handleIncoming(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = json["type"] as? String ?? ""

        switch type {
        case "reply_from_windows":
            if let notifID = json["notifID"] as? String,
               let replyText = json["text"] as? String {
                DispatchQueue.main.async {
                    if let idx = self.notifications.firstIndex(where: { $0.id == notifID }) {
                        self.notifications[idx].replied = true
                        self.notifications[idx].replyText = "💻 \(replyText)"
                    }
                    self.postLocalNotification(title: "Répondu depuis Windows", body: replyText)
                }
            }
        case "voice_from_windows":
            if let audioBase64 = json["audioBase64"] as? String {
                DispatchQueue.main.async {
                    self.playAudio(base64: audioBase64)
                }
            }
        default:
            break
        }
    }

    func sendToWindows(_ notif: BridgedNotification) {
        guard isConnected else { return }
        if let data = try? JSONEncoder().encode(notif),
           let json = String(data: data, encoding: .utf8) {
            let packet: [String: Any] = ["type": "notification", "payload": json]
            sendPacket(packet)
        }
    }

    private func sendPacket(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { _ in }
    }

    private func postLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Demo

    func addDemoNotification() {
        let demos = [
            BridgedNotification(appName: "Messages", title: "Thomas", body: "T'es dispo ce soir ?"),
            BridgedNotification(appName: "WhatsApp", title: "Emilio", body: "Le serveur est up 🔥"),
            BridgedNotification(appName: "Instagram", title: "Nouvelle activité", body: "@n1c1t0z a reçu 47 likes"),
            BridgedNotification(appName: "Téléphone", title: "Appel manqué", body: "+33 6 12 34 56 78", hasAudio: true)
        ]
        addNotification(demos.randomElement()!)
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var manager: NotifBridgeManager

    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "0A0A0F").ignoresSafeArea()

                VStack(spacing: 0) {
                    HeaderView()
                    ConnectionBannerView()
                    NotificationListView()
                }
            }
            .navigationBarHidden(true)
        }
        .preferredColorScheme(.dark)
    }
}

struct HeaderView: View {
    @EnvironmentObject var manager: NotifBridgeManager

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("NOTIF")
                    .font(.system(size: 24, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                + Text("BRIDGE")
                    .font(.system(size: 24, weight: .black, design: .monospaced))
                    .foregroundColor(Color(hex: "00F0FF"))

                Text("iOS → Windows")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "666680"))
            }

            Spacer()

            HStack(spacing: 12) {
                Button(action: { manager.addDemoNotification() }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(Color(hex: "00F0FF"))
                }

                NavigationLink(destination: SettingsView()) {
                    Image(systemName: "gearshape.fill")
                        .font(.title2)
                        .foregroundColor(Color(hex: "8888AA"))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

struct ConnectionBannerView: View {
    @EnvironmentObject var manager: NotifBridgeManager

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(manager.isConnected ? Color(hex: "00FF88") : Color(hex: "FF3366"))
                .frame(width: 8, height: 8)
                .shadow(color: manager.isConnected ? Color(hex: "00FF88") : Color(hex: "FF3366"),
                        radius: manager.isConnected ? 4 : 2)

            Text(manager.isConnected
                 ? "Connecté à \(manager.serverIP):\(manager.serverPort)"
                 : "Déconnecté — Appuyez pour configurer")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(manager.isConnected ? Color(hex: "00FF88") : Color(hex: "FF3366"))

            Spacer()

            if manager.isConnected {
                Button("Déco") { manager.disconnect() }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "FF3366"))
            } else {
                Button("Connecter") { manager.connect() }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "00F0FF"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hex: "12121A"))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(hex: "1E1E2E")),
            alignment: .bottom
        )
    }
}

struct NotificationListView: View {
    @EnvironmentObject var manager: NotifBridgeManager

    var body: some View {
        if manager.notifications.isEmpty {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "bell.slash")
                    .font(.system(size: 40))
                    .foregroundColor(Color(hex: "333350"))
                Text("Aucune notification")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "444460"))
                Text("Appuyez sur + pour un test")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: "2A2A40"))
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(manager.notifications) { notif in
                        NotificationCardView(notif: notif)
                    }
                }
                .padding(16)
            }
        }
    }
}

struct NotificationCardView: View {
    let notif: BridgedNotification
    @EnvironmentObject var manager: NotifBridgeManager
    @State private var replyText = ""
    @State private var showReply = false

    var appColor: Color {
        switch notif.appName {
        case "Messages": return Color(hex: "00FF88")
        case "WhatsApp": return Color(hex: "25D366")
        case "Instagram": return Color(hex: "E1306C")
        case "Téléphone": return Color(hex: "00F0FF")
        default: return Color(hex: "8888FF")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(appColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text(String(notif.appName.prefix(1)))
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundColor(appColor)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(notif.appName.uppercased())
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundColor(appColor)
                        Spacer()
                        Text(timeString(notif.timestamp))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(hex: "444460"))
                    }
                    Text(notif.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            // Body
            Text(notif.body)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "AAAACC"))
                .padding(.horizontal, 14)
                .padding(.top, 6)

            // Reply indicator
            if notif.replied, let reply = notif.replyText {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(appColor)
                        .frame(width: 2)
                    Text(reply)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(appColor)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }

            // Actions
            HStack(spacing: 8) {
                // Text reply
                Button(action: { withAnimation { showReply.toggle() } }) {
                    Label("Répondre", systemImage: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "00F0FF"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(hex: "00F0FF").opacity(0.1))
                        .cornerRadius(6)
                }

                // Voice
                if notif.hasAudio, let audio = notif.audioBase64 {
                    Button(action: { manager.playAudio(base64: audio) }) {
                        Label("Écouter", systemImage: "play.circle.fill")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(hex: "00FF88"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(hex: "00FF88").opacity(0.1))
                            .cornerRadius(6)
                    }
                }

                // Record vocal
                if manager.isRecording && manager.recordingForID == notif.id {
                    Button(action: { manager.stopRecordingAndSend() }) {
                        Label("Stop", systemImage: "stop.circle.fill")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(hex: "FF3366"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(hex: "FF3366").opacity(0.1))
                            .cornerRadius(6)
                    }
                } else {
                    Button(action: { manager.startRecording(for: notif.id) }) {
                        Label("Vocal", systemImage: "mic.fill")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(hex: "FF8800"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(hex: "FF8800").opacity(0.1))
                            .cornerRadius(6)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, showReply ? 0 : 12)

            // Inline reply field
            if showReply {
                HStack(spacing: 8) {
                    TextField("Votre réponse...", text: $replyText)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(hex: "1A1A28"))
                        .cornerRadius(8)

                    Button(action: {
                        if !replyText.isEmpty {
                            manager.sendReply(to: notif.id, text: replyText)
                            replyText = ""
                            showReply = false
                        }
                    }) {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(Color(hex: "00F0FF"))
                            .padding(8)
                            .background(Color(hex: "00F0FF").opacity(0.15))
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: "12121A"))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            notif.replied ? appColor.opacity(0.3) : Color(hex: "1E1E2E"),
                            lineWidth: 1
                        )
                )
        )
    }

    func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

struct SettingsView: View {
    @EnvironmentObject var manager: NotifBridgeManager

    var body: some View {
        ZStack {
            Color(hex: "0A0A0F").ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text("CONFIGURATION")
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 8) {
                    label("IP DU PC WINDOWS")
                    TextField("ex: 192.168.1.100", text: $manager.serverIP)
                        .fieldStyle()
                }

                VStack(alignment: .leading, spacing: 8) {
                    label("PORT WEBSOCKET")
                    TextField("ex: 8765", text: $manager.serverPort)
                        .fieldStyle()
                        .keyboardType(.numberPad)
                }

                Button(action: {
                    manager.disconnect()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        manager.connect()
                    }
                }) {
                    Text("CONNECTER")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(Color(hex: "0A0A0F"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(hex: "00F0FF"))
                        .cornerRadius(10)
                }

                Spacer()
            }
            .padding(24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .foregroundColor(Color(hex: "555570"))
    }
}

// MARK: - Extensions

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: (a, r, g, b) = (255, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255, opacity: Double(a)/255)
    }
}

extension View {
    func fieldStyle() -> some View {
        self
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(.white)
            .padding(12)
            .background(Color(hex: "12121A"))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "1E1E2E"), lineWidth: 1))
            .cornerRadius(8)
    }
}