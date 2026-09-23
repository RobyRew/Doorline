import HomeKit
import SwiftUI

struct EntranceView: View {
    @Environment(HomeStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var snapshot: PlatformImage?
    @State private var working = false
    @State private var showGear = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.doorInk.ignoresSafeArea()
                if !store.authorized && store.ready {
                    permission
                } else if store.homes.isEmpty && store.ready {
                    emptyHome
                } else {
                    layout
                }
            }
            .navigationTitle(store.home?.name ?? "Entrance")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showGear = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Choose lock and camera")
                }
            }
            .sheet(isPresented: $showGear) {
                PreferencesView()
                    .environment(store)
            }
            .task { await reloadSnapshot() }
        }
        .tint(.doorBrass)
    }

    private var layout: some View {
        Group {
            if sizeClass == .compact {
                VStack(spacing: 0) {
                    snapshotPane
                    controlPane
                }
            } else {
                HStack(spacing: 0) {
                    snapshotPane
                    controlPane
                        .frame(width: 360)
                }
            }
        }
    }

    private var snapshotPane: some View {
        ZStack(alignment: .bottomLeading) {
            snapshotView
            VStack(alignment: .leading, spacing: 6) {
                Text(store.camera?.name ?? "No camera")
                    .font(.system(.title2, design: .serif))
                Text(store.home?.name ?? "Apple Home")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(24)
        }
        .background(Color.doorSurface)
    }

    @ViewBuilder
    private var snapshotView: some View {
        if let snapshot {
            #if canImport(UIKit)
            Image(uiImage: snapshot)
                .resizable()
                .scaledToFill()
            #else
            Image(nsImage: snapshot)
                .resizable()
                .scaledToFill()
            #endif
        } else {
            VStack(spacing: 12) {
                Image(systemName: "video.slash")
                    .font(.system(size: 36, weight: .light))
                Text(store.camera == nil ? "Pick a Home camera" : "Waiting for a still")
                    .font(.callout)
            }
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controlPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            statusRow("Lock", store.lockState().rawValue, store.lock?.name)
            statusRow("Leaf", store.contactState().rawValue, store.contact?.name)

            Button {
                Task { await pulseOpen() }
            } label: {
                HStack {
                    Image(systemName: "lock.open")
                    Text(working ? "Opening" : "Open")
                        .font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.lock == nil || working)

            Button {
                Task { await store.setLocked(true) }
            } label: {
                Label("Lock", systemImage: "lock")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.lock == nil || working)

            if let lastError = store.lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(Color.doorWarn)
            }

            Spacer(minLength: 0)

            Text("Siri uses the lock and camera you pick. The Classe 300X does not appear in Home on its own.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.doorInk)
    }

    private func statusRow(_ title: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title, design: .serif))
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permission: some View {
        message(
            title: "Allow Home access",
            body: "Doorline only sees accessories already in the Home app. Enable Home data for Doorline in Settings."
        )
    }

    private var emptyHome: some View {
        message(
            title: "No home yet",
            body: "Set up a home in the Apple Home app on this Apple Account. Then come back."
        )
    }

    private func message(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(.largeTitle, design: .serif))
            Text(body)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func pulseOpen() async {
        working = true
        await store.setLocked(false)
        working = false
        await reloadSnapshot()
    }

    private func reloadSnapshot() async {
        snapshot = await store.snapshot()
    }
}

struct PreferencesView: View {
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if store.homes.isEmpty {
                    Text("No homes shared with this Apple Account.")
                } else {
                    Picker("Home", selection: homeBinding) {
                        ForEach(store.homes, id: \.uniqueIdentifier) { home in
                            Text(home.name).tag(Optional(home.uniqueIdentifier))
                        }
                    }
                    accessoryPicker("Lock", store.locks, \.lockID)
                    accessoryPicker("Camera", store.cameras, \.cameraID)
                    accessoryPicker("Door sensor", store.contacts, \.contactID)
                }
                Section("Siri") {
                    Text("“Open the door with Doorline”")
                    Text("“Is the door open in Doorline”")
                    Text("“Show the entrance in Doorline”")
                }
                .font(.footnote)
            }
            .navigationTitle("Entrance")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private var homeBinding: Binding<UUID?> {
        Binding(
            get: { store.pick.homeID ?? store.home?.uniqueIdentifier },
            set: { id in
                if let id, let home = store.homes.first(where: { $0.uniqueIdentifier == id }) {
                    store.choose(home: home)
                }
            }
        )
    }

    private func accessoryPicker(_ title: String, _ list: [HMAccessory], _ keyPath: ReferenceWritableKeyPath<DoorPick, UUID?>) -> some View {
        Picker(title, selection: Binding(
            get: { store.pick[keyPath: keyPath] },
            set: { store.pick[keyPath: keyPath] = $0 }
        )) {
            Text("None").tag(UUID?.none)
            ForEach(list, id: \.uniqueIdentifier) { accessory in
                Text(accessory.name).tag(Optional(accessory.uniqueIdentifier))
            }
        }
    }
}
