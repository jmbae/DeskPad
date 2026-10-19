import SwiftUI
import UIKit
import Observation

struct ContentView: View {
    @State private var store = ConnectionStore()
    @State private var editingConnection: SavedConnection?
    @State private var isAddingConnection = false
    @State private var connectingTo: SavedConnection?
    @State private var deletingConnection: SavedConnection?
    @State private var message: UserMessage?

    var body: some View {
        NavigationStack {
            Group {
                if store.connections.isEmpty {
                    ContentUnavailableView {
                        Label("연결이 없습니다", systemImage: "display")
                    } description: {
                        Text("VNC 서버를 추가해 원격 데스크톱에 연결하세요.")
                    } actions: {
                        Button("서버 추가", systemImage: "plus") {
                            isAddingConnection = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        if let loadError = store.loadError {
                            Label(loadError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        ForEach(store.connections) { connection in
                            ConnectionRow(connection: connection) {
                                connectingTo = connection
                            } edit: {
                                editingConnection = connection
                            } delete: {
                                deletingConnection = connection
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("DeskPad")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddingConnection = true
                    } label: {
                        Label("서버 추가", systemImage: "plus")
                    }
                    .accessibilityHint("새 VNC 연결 정보를 입력합니다.")
                }
            }
            .sheet(isPresented: $isAddingConnection) {
                ConnectionEditor(store: store, connection: nil) { message = $0 }
            }
            .sheet(item: $editingConnection) { connection in
                ConnectionEditor(store: store, connection: connection) { message = $0 }
            }
            .fullScreenCover(item: $connectingTo) { connection in
                SessionView(connection: connection, store: store)
            }
            .confirmationDialog(
                "이 연결을 삭제할까요?",
                isPresented: Binding(
                    get: { deletingConnection != nil },
                    set: { if !$0 { deletingConnection = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("삭제", role: .destructive) {
                    guard let deletingConnection else { return }
                    do {
                        try store.delete(deletingConnection)
                    } catch {
                        message = UserMessage(text: "연결을 삭제하지 못했습니다: \(error.localizedDescription)")
                    }
                    self.deletingConnection = nil
                }
                Button("취소", role: .cancel) { deletingConnection = nil }
            }
            .alert(item: $message) { item in
                Alert(
                    title: Text("DeskPad"),
                    message: Text(item.text),
                    dismissButton: .default(Text("확인"))
                )
            }
        }
    }
}

private struct ConnectionRow: View {
    let connection: SavedConnection
    let connect: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(connection.displayName)
                    .font(.headline)
                Text("\(connection.host):\(connection.port)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let date = connection.lastConnected {
                    Text("최근 연결 \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Button(action: connect) {
                Label("연결", systemImage: "arrow.up.right")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("\(connection.displayName)에 연결")
        }
        .padding(.vertical, 5)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: delete) {
                Label("삭제", systemImage: "trash")
            }
            Button(action: edit) {
                Label("편집", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button(action: connect) { Label("연결", systemImage: "arrow.up.right") }
            Button(action: edit) { Label("편집", systemImage: "pencil") }
            Button(role: .destructive, action: delete) { Label("삭제", systemImage: "trash") }
        }
    }
}

private struct ConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let store: ConnectionStore
    let connection: SavedConnection?
    let report: (UserMessage) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = "5900"
    @State private var username = ""
    @State private var password = ""
    @State private var hasExistingPassword = false

    var body: some View {
        NavigationStack {
            Form {
                Section("서버") {
                    TextField("표시 이름 (선택)", text: $name)
                        .textContentType(.nickname)
                    TextField("호스트 이름 또는 IP", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                    TextField("포트", text: $port)
                        .keyboardType(.numberPad)
                }
                Section("로그인") {
                    TextField("Mac 계정 사용자 이름", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                    SecureField(hasExistingPassword ? "Mac 계정 암호 변경 (비워두면 유지)" : "Mac 계정 암호", text: $password)
                        .textContentType(.password)
                    Text("macOS 화면 공유의 Apple Diffie–Hellman 인증에는 Mac 계정 사용자 이름과 암호가 필요합니다. 인증 후 화면 데이터는 암호화되지 않으므로 신뢰할 수 있는 네트워크에서만 연결하세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(connection == nil ? "연결 추가" : "연결 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장", action: save)
                }
            }
            .task {
                guard let connection else { return }
                name = connection.name
                host = connection.host
                port = String(connection.port)
                username = connection.username
                do {
                    hasExistingPassword = try store.hasPassword(for: connection)
                } catch {
                    report(UserMessage(text: "Keychain 자격 증명을 확인하지 못했습니다: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func save() {
        do {
            let parsedPort = try ConnectionStore.parsePort(port)
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            try ConnectionStore.validate(host: trimmedHost, port: parsedPort)
            let saved = SavedConnection(
                id: connection?.id ?? UUID(),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                host: trimmedHost,
                port: parsedPort,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                lastConnected: connection?.lastConnected
            )
            try store.save(saved, newPassword: password.isEmpty ? nil : password)
            dismiss()
        } catch {
            report(UserMessage(text: "연결을 저장하지 못했습니다: \(error.localizedDescription)"))
        }
    }
}

private struct SessionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session = VNCSessionModel()
    @State private var keyboardController = RemoteKeyboardController()
    @State private var isDragging = false
    @State private var password: String?

    let connection: SavedConnection
    let store: ConnectionStore

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    if case .failed = session.state {
                        Label(session.state.title, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                    }
                    if session.screenWidth > 0, let image = makeImage() {
                        GeometryReader { geometry in
                            ZStack {
                                Color.black
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { value in
                                                isDragging = true
                                                sendPointer(at: value.location, in: geometry.size, pressed: true)
                                            }
                                            .onEnded { value in
                                                sendPointer(at: value.location, in: geometry.size, pressed: false)
                                                isDragging = false
                                            }
                                    )
                                    .accessibilityLabel("원격 데스크톱 화면. 탭하거나 드래그해 포인터를 조작합니다.")
                            }
                        }
                        .background(.black)
                    } else {
                        ContentUnavailableView {
                            Label(session.state.title, systemImage: session.stateIcon)
                        } description: {
                            Text(sessionDescription)
                        } actions: {
                            if case .failed = session.state {
                                Button("다시 시도") { session.connect(to: connection, password: password) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                RemoteKeyboardInput(controller: keyboardController) { key, pressed in
                    session.sendKey(keysym: key, pressed: pressed)
                }
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
            }
            .ignoresSafeArea(.keyboard)
            .navigationTitle(connection.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") {
                        session.disconnect()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if case .connected = session.state {
                        Button {
                            if keyboardController.isFocused {
                                keyboardController.dismiss()
                            } else {
                                keyboardController.focus()
                            }
                        } label: {
                            Label(
                                keyboardController.isFocused ? "키보드 닫기" : "키보드",
                                systemImage: keyboardController.isFocused
                                    ? "keyboard.chevron.compact.down"
                                    : "keyboard"
                            )
                        }
                        .accessibilityHint("Mac에 문자와 키 입력을 보냅니다.")
                        Text("\(session.screenWidth) × \(session.screenHeight)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                do {
                    password = try store.password(for: connection)
                    session.connect(to: connection, password: password)
                } catch {
                    session.reportError("저장된 VNC 암호를 읽지 못했습니다: \(error.localizedDescription)")
                }
            }
            .onChange(of: session.state) { _, newState in
                if case .connected = newState {
                    do {
                        try store.markConnected(connection)
                    } catch {
                        session.reportError("화면은 연결됐지만 최근 연결 시각을 저장하지 못했습니다: \(error.localizedDescription)")
                    }
                }
            }
            .onDisappear {
                keyboardController.dismiss()
                session.disconnect()
            }
        }
    }

    private var sessionDescription: String {
        switch session.state {
        case .failed(let message): message
        case .connecting, .handshaking, .authenticating, .initializing: "서버 응답을 기다리고 있습니다."
        case .connected: "첫 번째 화면 업데이트를 기다리고 있습니다."
        case .disconnected: "연결이 종료되었습니다."
        }
    }

    private func sendPointer(at location: CGPoint, in size: CGSize, pressed: Bool) {
        guard size.width > 0, size.height > 0, session.screenWidth > 0, session.screenHeight > 0 else { return }
        let scale = min(size.width / CGFloat(session.screenWidth), size.height / CGFloat(session.screenHeight))
        let displayedWidth = CGFloat(session.screenWidth) * scale
        let displayedHeight = CGFloat(session.screenHeight) * scale
        let offsetX = (size.width - displayedWidth) / 2
        let offsetY = (size.height - displayedHeight) / 2
        let x = Int((location.x - offsetX) / scale)
        let y = Int((location.y - offsetY) / scale)
        session.sendPointer(x: x, y: y, buttonMask: pressed ? 1 : 0)
    }

    private func makeImage() -> CGImage? {
        guard session.screenWidth > 0, session.screenHeight > 0,
              session.framebuffer.count == session.screenWidth * session.screenHeight * 4,
              let provider = CGDataProvider(data: session.framebuffer as CFData) else { return nil }
        return CGImage(
            width: session.screenWidth,
            height: session.screenHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: session.screenWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

private extension VNCSessionModel {
    var stateIcon: String {
        switch state {
        case .failed: "exclamationmark.triangle"
        case .connecting, .handshaking, .authenticating, .initializing: "network"
        case .connected: "display"
        case .disconnected: "wifi.slash"
        }
    }

    func reportError(_ message: String) {
        setState(.failed(message))
    }
}

private struct UserMessage: Identifiable {
    let id = UUID()
    let text: String
}

@Observable
@MainActor
private final class RemoteKeyboardController {
    fileprivate weak var inputView: RemoteKeyboardInputView?
    fileprivate var isFocused = false

    func focus() {
        _ = inputView?.becomeFirstResponder()
    }

    func dismiss() {
        _ = inputView?.resignFirstResponder()
    }
}

private struct RemoteKeyboardInput: UIViewRepresentable {
    let controller: RemoteKeyboardController
    let sendKey: (UInt32, Bool) -> Void

    func makeUIView(context: Context) -> RemoteKeyboardInputView {
        let view = RemoteKeyboardInputView()
        view.onKey = sendKey
        view.onFocusChanged = { [weak controller] isFocused in
            controller?.isFocused = isFocused
        }
        controller.inputView = view
        return view
    }

    func updateUIView(_ uiView: RemoteKeyboardInputView, context: Context) {
        uiView.onKey = sendKey
        controller.inputView = uiView
    }
}

@MainActor
private final class RemoteKeyboardInputView: UIView, UIKeyInput {
    var onKey: ((UInt32, Bool) -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    private var pressedKeys: [UIKeyboardHIDUsage: UInt32] = [:]

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { false }
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            onFocusChanged?(true)
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChanged?(false)
        }
        return resigned
    }

    func insertText(_ text: String) {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let keysym = value <= 0xff ? value : 0x0100_0000 | value
            onKey?(keysym, true)
            onKey?(keysym, false)
        }
    }

    func deleteBackward() {
        onKey?(0xff08, true)
        onKey?(0xff08, false)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let handled = presses.compactMap { press -> (UIKeyboardHIDUsage, UInt32)? in
            guard let keyCode = press.key?.keyCode, let keysym = Self.keysym(for: keyCode) else { return nil }
            return (keyCode, keysym)
        }
        guard !handled.isEmpty else {
            super.pressesBegan(presses, with: event)
            return
        }
        for (keyCode, keysym) in handled {
            pressedKeys[keyCode] = keysym
            onKey?(keysym, true)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let handled = presses.compactMap { press -> UIKeyboardHIDUsage? in
            guard let keyCode = press.key?.keyCode, pressedKeys[keyCode] != nil else { return nil }
            return keyCode
        }
        guard !handled.isEmpty else {
            super.pressesEnded(presses, with: event)
            return
        }
        for keyCode in handled {
            if let keysym = pressedKeys.removeValue(forKey: keyCode) {
                onKey?(keysym, false)
            }
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let keyCode = press.key?.keyCode,
                  let keysym = pressedKeys.removeValue(forKey: keyCode) else { continue }
            onKey?(keysym, false)
        }
        super.pressesCancelled(presses, with: event)
    }

    private static func keysym(for keyCode: UIKeyboardHIDUsage) -> UInt32? {
        switch keyCode {
        case .keyboardReturnOrEnter: 0xff0d
        case .keypadEnter: 0xff8d
        case .keyboardTab: 0xff09
        case .keyboardEscape: 0xff1b
        case .keyboardDeleteOrBackspace: 0xff08
        case .keyboardHome: 0xff50
        case .keyboardEnd: 0xff57
        case .keyboardPageUp: 0xff55
        case .keyboardPageDown: 0xff56
        case .keyboardLeftArrow: 0xff51
        case .keyboardUpArrow: 0xff52
        case .keyboardRightArrow: 0xff53
        case .keyboardDownArrow: 0xff54
        case .keyboardF1: 0xffbe
        case .keyboardF2: 0xffbf
        case .keyboardF3: 0xffc0
        case .keyboardF4: 0xffc1
        case .keyboardF5: 0xffc2
        case .keyboardF6: 0xffc3
        case .keyboardF7: 0xffc4
        case .keyboardF8: 0xffc5
        case .keyboardF9: 0xffc6
        case .keyboardF10: 0xffc7
        case .keyboardF11: 0xffc8
        case .keyboardF12: 0xffc9
        default: nil
        }
    }
}
