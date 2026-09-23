import SwiftUI

enum DoorSection: String, CaseIterable, Identifiable, Hashable {
    case entrance
    case messages
    case history
    case home

    var id: String { rawValue }

    var title: String {
        switch self {
        case .entrance: "Entrance"
        case .messages: "Messages"
        case .history: "History"
        case .home: "Home"
        }
    }

    var symbol: String {
        switch self {
        case .entrance: "video.doorbell"
        case .messages: "recordingtape"
        case .history: "clock.arrow.circlepath"
        case .home: "homekit"
        }
    }
}

struct DoorlineRootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var section: DoorSection = .entrance

    private var sections: [DoorSection] {
        #if canImport(HomeKit)
        DoorSection.allCases
        #else
        DoorSection.allCases.filter { $0 != .home }
        #endif
    }

    var body: some View {
        Group {
            #if os(macOS)
            split
            #else
            if sizeClass == .regular {
                split
            } else {
                tabs
            }
            #endif
        }
        .tint(.doorBrass)
    }

    private var tabs: some View {
        TabView(selection: $section) {
            ForEach(sections) { item in
                page(item)
                    .tabItem { Label(item.title, systemImage: item.symbol) }
                    .tag(item)
            }
        }
    }

    private var split: some View {
        NavigationSplitView {
            // Non-optional selection is unavailable on iOS. The sidebar writes back into `section`.
            List(selection: Binding<DoorSection?>(
                get: { section },
                set: { section = $0 ?? section }
            )) {
                ForEach(sections) { item in
                    Label(item.title, systemImage: item.symbol)
                        .tag(Optional(item))
                }
            }
            .navigationTitle("Doorline")
        } detail: {
            page(section)
        }
    }

    @ViewBuilder
    private func page(_ section: DoorSection) -> some View {
        switch section {
        case .entrance:
            ClasseEntranceView()
        case .messages:
            MessagesView()
        case .history:
            HistoryView()
        case .home:
            #if canImport(HomeKit)
            EntranceView()
            #else
            ClasseEntranceView()
            #endif
        }
    }
}

struct ClasseEntranceView: View {
    @Environment(Classe300XSession.self) private var session
    @State private var confirmDoor = false
    @State private var confirmGate = false
    @State private var showSettings = false
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var keepSignedIn = true
    @State private var showReset = false
    @State private var showRegister = false
    @State private var working = false

    private var ringing: Binding<Bool> {
        Binding(
            get: { session.call.phase == .ringing },
            set: { presented in
                if !presented, session.call.phase == .ringing {
                    Task { await session.decline() }
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.doorInk.ignoresSafeArea()
                if session.link == nil {
                    association
                } else {
                    linked
                }
            }
            .navigationTitle("Entrance")
            .onAppear {
                if email.isEmpty { email = session.rememberedEmail }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Entrance settings")
                    .tint(Color.doorBrass)
                }
            }
            .sheet(isPresented: $showSettings) {
                ClasseSettingsView()
                    .environment(session)
            }
            .sheet(isPresented: $showReset) {
                EliotClaimsSheet(title: "Reset password") { journey in
                    try await journey.loadPasswordReset()
                }
            }
            .sheet(isPresented: $showRegister) {
                EliotClaimsSheet(title: "Create account") { journey in
                    try await journey.loadRegistration()
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: ringing) {
                IncomingCallView()
                    .environment(session)
            }
            #else
            .sheet(isPresented: ringing) {
                IncomingCallView()
                    .environment(session)
                    .frame(minWidth: 420, minHeight: 520)
            }
            #endif
        }
    }

    private var association: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Sign in")
                    .font(.system(.largeTitle, design: .serif))
                Text("Use the same email and password as Door Entry. Eliot tells Doorline which Classe 300X is on that account.")
                    .foregroundStyle(.secondary)
                field("Email", text: $email, prompt: "Email", secure: false, account: true)
                field("Password", text: $password, prompt: "Password", secure: !showPassword, account: false)
                Toggle("Show password", isOn: $showPassword)
                    .font(.subheadline)
                Toggle("Keep me signed in", isOn: $keepSignedIn)
                    .font(.subheadline)
                DoorCommandButton(title: working ? "Signing in" : "Sign in", systemImage: "checkmark", prominent: true) {
                    Task { await signIn() }
                }
                .disabled(working || !email.contains("@") || password.isEmpty)
                VStack(alignment: .leading, spacing: 10) {
                    Button("Forgot your password?") { showReset = true }
                    Button("Not yet registered?") { showRegister = true }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.doorBrass)
                receipt
            }
            .padding(28)
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    private var linked: some View {
        VStack(spacing: 0) {
            cameraStage
            controls
        }
    }

    private var cameraStage: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(spacing: 14) {
                Image(systemName: session.call.phase == .active && session.call.videoLive ? "video.fill" : "video")
                    .font(.system(size: 42, weight: .light))
                    .symbolEffect(.pulse, isActive: session.call.phase == .ringing)
                    .contentTransition(.symbolEffect(.replace))
                Text(stageTitle)
                    .font(.callout)
            }
            .foregroundStyle(.white.opacity(0.78))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Text(session.currentCamera?.name ?? "No camera")
                    .font(.system(.title2, design: .serif))
                    .contentTransition(.opacity)
                    .id(session.currentCameraID ?? "")
                Text(session.link?.plantID ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                Menu {
                    ForEach(session.cameras) { camera in
                        Button(camera.name) {
                            Task { await session.selectCamera(camera.id) }
                        }
                    }
                } label: {
                    Label("Cameras", systemImage: "video.badge.ellipsis")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .doorGlass(in: Capsule())
            }
            .padding(24)
        }
        .background(Color.doorSurface)
        .animation(.spring(duration: 0.4), value: session.currentCameraID)
        .animation(.spring(duration: 0.4), value: session.call.phase)
    }

    private var stageTitle: String {
        switch session.call.phase {
        case .idle: "Panel idle"
        case .ringing: "Ringing"
        case .active: session.call.videoLive ? "Live picture and sound" : "Sound to the internal unit"
        case .declined: "Declined"
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                statusChip("Forwarding", session.forwarding.title)
                statusChip("Studio", session.professionalStudio ? "Auto-open" : "Off")
            }
            DoorGlassGroup {
                DoorCommandButton(title: "Open door lock", systemImage: "lock.open", prominent: true) {
                    confirmDoor = true
                }
                DoorCommandButton(title: "Open gate", systemImage: "door.garage.open") {
                    confirmGate = true
                }
            }
            DoorCommandButton(title: "Call the internal unit", systemImage: "phone.arrow.up.right") {
                Task { await session.callHome() }
            }
            .disabled(session.call.phase == .ringing || session.call.phase == .active)
            if session.call.phase == .active {
                DoorCommandButton(title: "End call", systemImage: "phone.down") {
                    session.endCall()
                }
            }
            receipt
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.doorInk)
        .confirmationDialog("Open the entrance door lock?", isPresented: $confirmDoor, titleVisibility: .visible) {
            Button("Open door lock") { Task { await session.releaseDoorLock() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Open the gate?", isPresented: $confirmGate, titleVisibility: .visible) {
            Button("Open gate") { Task { await session.releaseActuator() } }
            Button("Cancel", role: .cancel) {}
        }
        .sensoryFeedback(.success, trigger: session.history.first { $0.kind == .unlock }?.id)
    }

    private var receipt: some View {
        Group {
            if case .rejected(let reason) = session.lastReceipt {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(Color.doorWarn)
            } else if case .queued = session.lastReceipt, session.link != nil {
                Text("Commands are addressed to this plant. The portal has not accepted them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusChip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .doorGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, secure: Bool, account: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            Group {
                if secure {
                    SecureField(prompt, text: text)
                        .textContentType(.password)
                } else {
                    TextField(prompt, text: text)
                        .textContentType(account ? .username : .password)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(account ? .emailAddress : .default)
                        #endif
                }
            }
            .textFieldStyle(.plain)
            .padding(12)
            .doorGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func signIn() async {
        working = true
        await session.signIn(email: email, password: password, keepSignedIn: keepSignedIn)
        if session.link != nil { password = "" }
        working = false
    }
}

struct EliotClaimsSheet: View {
    var title: String
    var load: (EliotWebJourney) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var journey = EliotWebJourney(wire: URLSessionEliotWire())
    @State private var values: [String: String] = [:]
    @State private var codes: [String: String] = [:]
    @State private var reveal = false
    @State private var note = ""
    @State private var busy = false
    @State private var verified: Set<String> = []
    @State private var formID = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.doorInk.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let page = journey.page {
                            if !subtitle.isEmpty {
                                Text(subtitle)
                                    .foregroundStyle(.secondary)
                            }
                            if !note.isEmpty {
                                noteBanner
                            }
                            ForEach(page.fields) { field in
                                fieldBlock(field)
                            }
                            if page.fields.contains(where: { $0.kind == .password }) {
                                Toggle("Show password", isOn: $reveal)
                                    .font(.subheadline)
                                    .tint(Color.doorBrass)
                            }
                        } else if note.isEmpty {
                            ProgressView("Opening Eliot")
                                .tint(Color.doorBrass)
                                .frame(maxWidth: .infinity, minHeight: 240)
                        } else {
                            noteBanner
                        }
                    }
                    .padding(28)
                    .padding(.bottom, 8)
                    .id(formID)
                }
                .safeAreaInset(edge: .bottom) {
                    if journey.page != nil {
                        DoorCommandButton(title: busy ? "Sending" : "Continue", systemImage: "checkmark", prominent: true) {
                            Task { await submit() }
                        }
                        .disabled(busy)
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                        .background(Color.doorInk)
                    }
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.doorInk, for: .navigationBar)
            #endif
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Color.doorBrass)
                }
            }
            .task { await open() }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    private var subtitle: String {
        guard let page = journey.page else { return "" }
        let choosingPassword = page.fields.contains { $0.id == "newPassword" }
        let verifyingEmail = page.fields.contains { $0.verify }
        if choosingPassword && verifyingEmail {
            return "Same details Door Entry asks for. Eliot emails a code before the account is created."
        }
        if verifyingEmail {
            return "Enter the email on the account. Eliot sends a code, then you choose a new password."
        }
        if choosingPassword {
            return "Choose a new password for this account."
        }
        return ""
    }

    private var noteBanner: some View {
        Text(note)
            .font(.footnote)
            .foregroundStyle(Color.doorWarn)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .doorGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func fieldBlock(_ field: EliotField) -> some View {
        if field.verify {
            labeledField(field.label, text: binding(field.id), secure: false, input: .email)
            brassButton(busy ? "Sending" : "Send code") { Task { await send(field) } }
            labeledField("Verification code", text: codeBinding(field.id), secure: false, input: .code)
            brassButton(busy ? "Sending" : "Verify code") { Task { await verify(field) } }
        } else if field.kind == .password {
            labeledField(field.label, text: binding(field.id), secure: !reveal, input: .newPassword)
        } else if field.kind == .menu {
            menuField(field)
        } else if field.kind == .checkbox {
            Toggle(isOn: Binding(
                get: { values[field.id] == "1" },
                set: { values[field.id] = $0 ? "1" : "" }
            )) {
                Text(field.label)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tint(Color.doorBrass)
        } else {
            labeledField(field.label, text: binding(field.id), secure: false, input: textInput(field))
        }
    }

    /// The value stays empty until a row is chosen. A form picker with every country was drawing an unselected row as Spain.
    private func menuField(_ field: EliotField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(field.label)
            Menu {
                Button("Choose") { values[field.id] = "" }
                ForEach(field.options, id: \.value) { option in
                    Button(option.label) { values[field.id] = option.value }
                }
            } label: {
                HStack {
                    Text(menuTitle(field))
                        .foregroundStyle((values[field.id] ?? "").isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.doorBrass)
                }
                .padding(12)
                .doorGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func menuTitle(_ field: EliotField) -> String {
        let value = values[field.id] ?? ""
        guard !value.isEmpty else { return "Choose" }
        return field.options.first { $0.value == value }?.label ?? "Choose"
    }

    private enum FieldInput {
        case plain
        case email
        case code
        case newPassword
        case givenName
        case familyName
        case nickname
    }

    private func labeledField(_ title: String, text: Binding<String>, secure: Bool, input: FieldInput) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(title)
            Group {
                if secure {
                    SecureField(title, text: text)
                        #if os(iOS)
                        .textContentType(input == .newPassword ? .newPassword : .password)
                        #endif
                } else {
                    TextField(title, text: text)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(input == .email ? .emailAddress : input == .code ? .numberPad : .default)
                        .textContentType(iosContent(input))
                        #endif
                }
            }
            .textFieldStyle(.plain)
            .padding(12)
            .doorGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    #if os(iOS)
    private func iosContent(_ input: FieldInput) -> UITextContentType? {
        switch input {
        case .email: .emailAddress
        case .code: .oneTimeCode
        case .newPassword: .newPassword
        case .givenName: .givenName
        case .familyName: .familyName
        case .nickname: .nickname
        case .plain: nil
        }
    }
    #endif

    private func caption(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
    }

    private func brassButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.doorBrass)
            .disabled(busy)
    }

    private func textInput(_ field: EliotField) -> FieldInput {
        switch field.id {
        case "givenName": .givenName
        case "surname": .familyName
        case "displayName": .nickname
        default: field.kind == .email ? .email : .plain
        }
    }

    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { values[id] ?? "" }, set: { values[id] = $0 })
    }

    private func codeBinding(_ id: String) -> Binding<String> {
        Binding(get: { codes[id] ?? "" }, set: { codes[id] = $0 })
    }

    private func open() async {
        do {
            try await load(journey)
            note = ""
        } catch let failure as DoorEntrySignInFailure {
            note = failure.message
        } catch {
            note = error.localizedDescription
        }
    }

    private func send(_ field: EliotField) async {
        busy = true
        do {
            try await journey.sendCode(claimId: field.id, claimValue: values[field.id] ?? "")
            note = "Verification code requested."
        } catch let failure as DoorEntrySignInFailure {
            note = failure.message
        } catch {
            note = error.localizedDescription
        }
        busy = false
    }

    private func verify(_ field: EliotField) async {
        busy = true
        do {
            try await journey.verifyCode(claimId: field.id, claimValue: values[field.id] ?? "", userInput: codes[field.id] ?? "")
            verified.insert(field.id)
            note = "Code accepted."
        } catch let failure as DoorEntrySignInFailure {
            note = failure.message
        } catch {
            note = error.localizedDescription
        }
        busy = false
    }

    private func submit() async {
        if let reason = blockedReason() {
            note = reason
            return
        }
        let before = journey.page?.fields.map(\.id) ?? []
        busy = true
        do {
            try await journey.submit(values)
            if journey.page == nil {
                note = title == "Reset password"
                    ? "Password updated. Close this and sign in with the new one."
                    : "Account created. Close this and sign in with that email."
            } else if journey.page?.fields.map(\.id) != before {
                note = ""
                formID += 1
            } else {
                note = journey.message ?? ""
            }
        } catch let failure as DoorEntrySignInFailure {
            note = failure.message
        } catch {
            note = error.localizedDescription
        }
        busy = false
    }

    /// Continue was posting an unfinished page and then saying to continue again.
    private func blockedReason() -> String? {
        guard let fields = journey.page?.fields else { return nil }
        if let field = fields.first(where: { $0.verify }), !verified.contains(field.id) {
            return "Enter the code from your email and tap Verify code."
        }
        let missing = fields.filter { field in
            guard field.required else { return false }
            if field.kind == .checkbox { return values[field.id] != "1" }
            return (values[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let texts = missing.filter { $0.kind != .checkbox }.map(\.label)
        let boxes = missing.filter { $0.kind == .checkbox }.map(\.label)
        var parts: [String] = []
        if !texts.isEmpty { parts.append("Fill in \(texts.joined(separator: ", ")).") }
        if !boxes.isEmpty { parts.append(boxes.joined(separator: " ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

struct IncomingCallView: View {
    @Environment(Classe300XSession.self) private var session

    var body: some View {
        ZStack {
            Color.doorInk.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "bell.and.waves.left.and.right")
                    .font(.system(size: 56, weight: .light))
                    .symbolEffect(.pulse, options: .repeating)
                    .foregroundStyle(Color.doorBrass)
                VStack(spacing: 8) {
                    Text("Someone is at the door")
                        .font(.system(.largeTitle, design: .serif))
                        .multilineTextAlignment(.center)
                    Text(session.call.caller.isEmpty ? "Entrance panel" : session.call.caller)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                DoorGlassGroup {
                    DoorCommandButton(title: "Answer", systemImage: "phone.fill", prominent: true) {
                        Task { await session.answer() }
                    }
                    .accessibilityLabel("Answer call")
                    DoorCommandButton(title: "Decline", systemImage: "phone.down.fill") {
                        Task { await session.decline() }
                    }
                    .accessibilityLabel("Decline call")
                }
            }
            .padding(28)
        }
        .animation(.spring(duration: 0.45), value: session.call.phase)
    }
}

struct MessagesView: View {
    @Environment(Classe300XSession.self) private var session

    var body: some View {
        NavigationStack {
            Group {
                if session.messages.isEmpty {
                    ContentUnavailableView(
                        "No messages",
                        systemImage: "recordingtape",
                        description: Text("Recorded calls show up here when the answering machine has them.")
                    )
                } else {
                    List(session.messages) { message in
                        Button {
                            Task { await session.playMessage(message.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.caller)
                                        .font(.body.weight(.semibold))
                                    Text(message.recordedAt, format: .dateTime.month().day().hour().minute())
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if session.playingMessageID == message.id {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(Color.doorBrass)
                                        .accessibilityLabel("Playing")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Messages")
            .safeAreaInset(edge: .bottom) {
                if session.link != nil {
                    Toggle(isOn: Binding(
                        get: { session.answeringMachineEnabled },
                        set: { enabled in Task { await session.setAnsweringMachineEnabled(enabled) } }
                    )) {
                        Text("Answering machine")
                    }
                    .padding(20)
                    .doorGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

struct HistoryView: View {
    @Environment(Classe300XSession.self) private var session

    var body: some View {
        NavigationStack {
            Group {
                if session.history.isEmpty {
                    ContentUnavailableView(
                        "No events yet",
                        systemImage: "clock",
                        description: Text("Calls and door-lock releases are listed here.")
                    )
                } else {
                    List(session.history) { entry in
                        HStack(spacing: 14) {
                            Image(systemName: entry.kind == .unlock ? "lock.open" : "phone")
                                .foregroundStyle(Color.doorBrass)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.kind == .unlock ? "Door lock" : "Call")
                                    .font(.body.weight(.semibold))
                                Text(entry.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.date, format: .dateTime.month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("History")
        }
    }
}

struct ClasseSettingsView: View {
    @Environment(Classe300XSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("This build") {
                    LabeledContent("Version", value: version)
                    LabeledContent("Build", value: build)
                }
                if let link = session.link {
                    Section("Account") {
                        LabeledContent("Email", value: link.account)
                        LabeledContent("Plant", value: link.plantID)
                        LabeledContent("Gateway", value: link.gatewayID)
                    }
                    Section("Call forwarding") {
                        Picker("Forwarding", selection: Binding(
                            get: { session.forwarding },
                            set: { mode in Task { await session.setForwarding(mode) } }
                        )) {
                            ForEach(ForwardingMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    Section {
                        Toggle(isOn: Binding(
                            get: { session.professionalStudio },
                            set: { enabled in Task { await session.setProfessionalStudio(enabled) } }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Professional studio")
                                Text("Opens the entrance lock when someone rings.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        Button("Remove link", role: .destructive) {
                            session.signOut()
                            dismiss()
                        }
                    }
                } else {
                    Section {
                        Text("Sign in to reach the Classe 300X. Forgot your password and Not yet registered stay on the sign-in screen.")
                    }
                }
            }
            .navigationTitle("Entrance")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}
