import AppKit
import SwiftUI

// MARK: - Permission card (island opens by itself when Claude Code asks)

struct PermissionCardView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var claude: ClaudeMonitor
    let ask: PermissionAsk

    var body: some View {
        VStack(spacing: 0) {
            EarsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
                HStack(spacing: 8) {
                    MascotFace(mood: .attention, size: 15)
                    Text(ask.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                .padding(.leading, IslandModel.inset - 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } right: {
                Text(claude.permissions.count > 1 ? "ещё \(claude.permissions.count - 1)" : "Claude Code")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, IslandModel.inset)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(ask.title).font(.system(size: 14, weight: .semibold))
                Text(ask.detail.isEmpty ? ask.toolName : ask.detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.08)))
                    .help(ask.detail)

                HStack(spacing: 8) {
                    Button("В терминале") { claude.answer(ask, .terminal) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Не отвечать здесь — Claude Code спросит в терминале")
                    Spacer()
                    AnswerButton(title: "Запретить", style: .secondary) { claude.answer(ask, .deny) }
                    if !ask.suggestions.isEmpty {
                        AnswerButton(title: "Всегда", style: .secondary) { claude.answer(ask, .always) }
                            .help("Разрешить и больше не спрашивать для таких действий")
                    }
                    AnswerButton(title: "Разрешить", style: .primary) { claude.answer(ask, .allow) }
                }
            }
            .padding(.horizontal, IslandModel.inset)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
    }
}

private struct AnswerButton: View {
    enum Style { case primary, secondary }
    let title: String
    let style: Style
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style == .primary ? Color.black : Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(style == .primary ? Color.white.opacity(hover ? 0.85 : 1) : Color.white.opacity(hover ? 0.2 : 0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

// MARK: - Collapsed: face on the left, status (or the music EQ) on the right

struct AgentCompactView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var claude: ClaudeMonitor

    var body: some View {
        if model.showsMascot {
            // The mascot always lives on the right; the left shows what's going on.
            EarsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
                if model.nowPlaying?.isPlaying == true {
                    ArtworkView(image: model.artwork, size: 22, corner: 6)
                } else {
                    AgentStatusGlyph(mood: claude.mood)
                }
            } right: {
                MascotView(mood: model.mascotMood, size: 17, gaze: model.mascotGaze)
            }
        } else {
            EarsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
                MascotFace(mood: claude.mood, size: 17)
            } right: {
                if model.nowPlaying?.isPlaying == true {
                    EqualizerView(isPlaying: true, tint: .white).frame(width: 22, height: 17)
                } else {
                    AgentStatusGlyph(mood: claude.mood)
                }
            }
        }
    }
}

struct AgentStatusGlyph: View {
    let mood: MascotMood

    var body: some View {
        switch mood {
        case .attention:
            Image(systemName: "exclamationmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(.orange)
        case .happy:
            Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.green)
        case .working:
            ThinkingDotsCA()
        default:
            EmptyView()
        }
    }
}

/// Three dots pulsing in turn while an agent works.
struct ThinkingDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(.white).frame(width: 4, height: 4)
                    .opacity(phase == i ? 1 : 0.3)
                    .scaleEffect(phase == i ? 1.15 : 1)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(.easeInOut(duration: 0.25)) { phase = (phase + 1) % 3 }
            }
        }
    }
}

// MARK: - Peek ("готово" / "ждёт ответа")

struct AgentPeekView: View {
    @ObservedObject var model: IslandModel
    let peek: AgentPeek

    var body: some View {
        EarsLayout(notchWidth: model.notchSize.width, height: model.notchSize.height) {
            HStack(spacing: 8) {
                MascotFace(mood: peek.mood, size: 16)
                Text(peek.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } right: {
            Text(peek.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(peek.mood == .happy ? Color.green : Color.orange)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Agents tab

struct AgentsTab: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var claude: ClaudeMonitor
    @State private var installed = ClaudeHooks.isInstalled

    var body: some View {
        Group {
            if !installed {
                HStack(spacing: 14) {
                    faceTile(.sleeping)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Подключи Claude Code — остров покажет, что делает агент, и спросит разрешения")
                            .font(.system(size: 13, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        PillButton(title: "Подключить") {
                            ClaudeHooks.install()
                            installed = ClaudeHooks.isInstalled
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else if claude.sessions.isEmpty {
                HStack(spacing: 14) {
                    faceTile(.idle)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Нет активных сессий").font(.system(size: 13, weight: .semibold))
                        Text("Запусти Claude Code — сессии появятся здесь")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    faceTile(claude.mood)
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(claude.sessions) { s in SessionRow(claude: claude, session: s) }
                        }
                    }
                }
            }
        }
        .onAppear { installed = ClaudeHooks.isInstalled }
    }

    private func faceTile(_ mood: MascotMood) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.08))
            .frame(width: IslandModel.artworkSize, height: IslandModel.artworkSize)
            .overlay(MascotFace(mood: mood, size: 34))
    }
}

private struct SessionRow: View {
    @ObservedObject var claude: ClaudeMonitor
    let session: ClaudeSession
    @State private var hover = false

    private var mood: MascotMood {
        switch session.status {
        case .working: return .working
        case .waiting: return .attention
        case .done: return .happy
        case .idle: return session.updatedAt < Date().addingTimeInterval(-5 * 60) ? .sleeping : .idle
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            MascotFace(mood: mood, size: 12).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(session.activity).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(session.updatedAt, style: .relative)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: 70, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { claude.jump(to: session) }
        .help("Открыть окно, где запущена сессия")
    }
}
