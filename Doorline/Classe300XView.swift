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
    @State private var rememberEmail = true
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
                    .disabled(session.link == nil)
                }
            }
            .sheet(isPresented: $showSettings) {
                ClasseSettingsView()
                    .environment(session)
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
                field("Email", text: $email, prompt: "Email", secure: false)
                    .textContentType(.username)
                field("Password", text: $password, prompt: "Password", secure: true)
                    .textContentType(.password)
                Toggle("Remember email", isOn: $rememberEmail)
                    .font(.subheadline)
                DoorCommandButton(title: working ? "Signing in" : "Sign in", systemImage: "checkmark", prominent: true) {
                    Task { await signIn() }
                }
                .disabled(working || !email.contains("@") || password.isEmpty)
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

    private func field(_ title: String, text: Binding<String>, prompt: String, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            Group {
                if secure {
                    SecureField(prompt, text: text)
                } else {
                    TextField(prompt, text: text)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        #endif
                        .autocorrectionDisabled()
                }
            }
            .textFieldStyle(.plain)
            .padding(12)
            .doorGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func signIn() async {
        working = true
        await session.signIn(email: email, password: password, rememberEmail: rememberEmail)
        password = ""
        working = false
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

    var body: some View {
        NavigationStack {
            Form {
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
