import PhotosUI
import SwiftUI

@main
struct PortalCompanionApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var link = PortalLink()
    @StateObject private var outbox = Outbox()
    @State private var picked: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var showSettings = false
    @State private var sending: Sending?
    @State private var flash: String?

    struct Sending: Equatable {
        var name: String
        var progress: Double
    }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if outbox.items.isEmpty {
                    empty
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(outbox.items) { item in
                            SwipeCard(item: item, canSend: link.connectedMac != nil) { throwItem(item) }
                        }
                    }
                    .padding(16)
                }
            }
            .safeAreaInset(edge: .top) { status }
            .navigationTitle("Portal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PhotosPicker(selection: $picked, maxSelectionCount: 30, matching: .any(of: [.images, .videos])) {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                    Button { showFiles = true } label: { Image(systemName: "folder") }
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .onChange(of: picked) { _, new in
                guard !new.isEmpty else { return }
                Task { await outbox.add(photos: new); picked = [] }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await outbox.add(files: urls) } }
            }
            .sheet(isPresented: $showSettings) { SettingsSheet(link: link) }
        }
    }

    // MARK: Status

    private var status: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(statusText).font(.subheadline)
                Spacer()
                if link.macs.count > 1 || (link.macs.count == 1 && link.connectedMac == nil) {
                    Menu("Mac") {
                        ForEach(link.macs, id: \.self) { mac in
                            Button(mac.displayName) { link.connect(to: mac) }
                        }
                    }
                    .font(.subheadline)
                }
            }
            if let sending {
                ProgressView(value: sending.progress) {
                    Text("Отправка «\(sending.name)»").font(.caption).lineLimit(1)
                }
            } else if let flash {
                Text(flash).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusText: String {
        switch link.state {
        case .searching: return link.macs.isEmpty ? "Ищу Mac с NotchIsland…" : "Выбери Mac"
        case .connecting(let name): return "Подключаюсь к «\(name)»… подтверди на Mac"
        case .connected(let name): return "«\(name)» — смахни карточку вправо"
        }
    }

    private var dotColor: Color {
        switch link.state {
        case .searching: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Добавь фото или файлы").font(.headline)
            Text("Потом резко смахни карточку вправо — она улетит на Mac.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            PhotosPicker(selection: $picked, maxSelectionCount: 30, matching: .any(of: [.images, .videos])) {
                Label("Выбрать фото", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.borderedProminent)
            Button("Выбрать файлы") { showFiles = true }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: Sending

    /// The card has flown off: send it; on failure it comes back.
    private func throwItem(_ item: PortalItem) {
        let index = outbox.items.firstIndex(of: item) ?? 0
        withAnimation(.spring(duration: 0.35)) { outbox.items.removeAll { $0.id == item.id } }
        Task {
            sending = Sending(name: item.name, progress: 0)
            do {
                try await link.send(item.url, name: item.name) { sending?.progress = $0 }
                Inbox.remove(item.url)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                flash = "«\(item.name)» на Mac"
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                flash = "Не отправилось: \(error.localizedDescription)"
                withAnimation(.spring) { outbox.restore(item, at: index) }
            }
            sending = nil
        }
    }
}

// MARK: - Card

/// A thumbnail that flies away when flicked to the right fast enough (or dragged far enough).
struct SwipeCard: View {
    let item: PortalItem
    let canSend: Bool
    let onThrow: () -> Void

    @State private var offset: CGSize = .zero
    @State private var gone = false

    /// Points per second to the right that count as a throw.
    static let throwVelocity: CGFloat = 900
    /// Or a drag that would end this far to the right.
    static let throwDistance: CGFloat = 260

    var body: some View {
        thumbnail
            .frame(minWidth: 0, maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Text(item.name).font(.caption2).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule()).padding(6)
            }
            .shadow(color: .black.opacity(offset == .zero ? 0.1 : 0.3), radius: offset == .zero ? 3 : 12, y: 4)
            .offset(offset)
            .rotationEffect(.degrees(Double(offset.width) / 18))
            .scaleEffect(offset == .zero ? 1 : 1.05)
            .opacity(gone ? 0 : 1)
            .zIndex(offset == .zero ? 0 : 1)
            .gesture(drag)
            .sensoryFeedback(.impact(weight: .heavy), trigger: gone) { _, now in now }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = item.thumbnail {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color(.secondarySystemBackground)
                Image(systemName: "doc").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                // Mostly sideways: follow the finger; resist going left.
                let dx = value.translation.width
                offset = CGSize(width: dx > 0 ? dx : dx / 4, height: value.translation.height / 3)
            }
            .onEnded { value in
                let flicked = value.velocity.width > Self.throwVelocity && value.velocity.width > abs(value.velocity.height)
                let far = value.predictedEndTranslation.width > Self.throwDistance
                guard canSend, flicked || far else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { offset = .zero }
                    return
                }
                let speed = max(value.velocity.width, 1200)
                withAnimation(.easeIn(duration: Double(min(0.35, 700 / speed)))) {
                    offset = CGSize(width: 700, height: value.translation.height / 3 + value.velocity.height / 8)
                    gone = true
                } completion: {
                    onThrow()
                }
            }
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @ObservedObject var link: PortalLink
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Имя", text: $name).onSubmit { link.deviceName = name }
                } header: {
                    Text("Как этот iPhone видит Mac")
                } footer: {
                    Text("Mac спросит один раз, можно ли принимать файлы от этого имени.")
                }
                Section("Mac рядом") {
                    if link.macs.isEmpty { Text("Не найдено. Включи Portal в настройках NotchIsland.").foregroundStyle(.secondary) }
                    ForEach(link.macs, id: \.self) { mac in
                        Button {
                            link.connect(to: mac)
                        } label: {
                            HStack {
                                Text(mac.displayName)
                                Spacer()
                                if link.connectedMac == mac { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Настройки")
            .toolbar { Button("Готово") { link.deviceName = name; dismiss() } }
            .onAppear { name = link.deviceName }
        }
    }
}
