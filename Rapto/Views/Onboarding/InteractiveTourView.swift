//
//  InteractiveTourView.swift
//  Rapto
//
//  Pure state machine (`InteractiveTourModel`) and compact floating HUD view for the
//  mouse-first interactive tour launched after first-run setup.
//

import Combine
import SwiftUI

nonisolated enum TourTaskID: String, Equatable, Hashable, CaseIterable, Sendable, Identifiable {
    case dragToEdge
    case dragToTopPicker
    case arrangeWindows
    case swapWindows
    case resizeSharedBorder
    case groupWindows
    case switchGroupWindow
    case revealNotchBar

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dragToEdge: return "rectangle.lefthalf.inset.filled"
        case .dragToTopPicker: return "menubar.dock.rectangle"
        case .arrangeWindows: return "square.grid.2x2"
        case .swapWindows: return "arrow.left.arrow.right"
        case .resizeSharedBorder: return "arrow.left.and.right"
        case .groupWindows: return "rectangle.stack"
        case .switchGroupWindow: return "cursorarrow.click.2"
        case .revealNotchBar: return "arrow.up.circle"
        }
    }

    var title: String {
        switch self {
        case .dragToEdge: return "Drag a window to the left or right edge"
        case .dragToTopPicker: return "Drop a window on the top layout bar"
        case .arrangeWindows: return "Arrange your open windows"
        case .swapWindows: return "Swap two windows"
        case .resizeSharedBorder: return "Resize a shared border"
        case .groupWindows: return "Group two windows in one slot"
        case .switchGroupWindow: return "Switch windows with the group indicator"
        case .revealNotchBar: return "Find the Desktops Bar under the notch"
        }
    }

    var detail: String {
        switch self {
        case .dragToEdge: return "Pull any title bar to the edge — it snaps to half the screen"
        case .dragToTopPicker: return "Start dragging to reveal the bar at the top, then drop on a zone"
        case .arrangeWindows: return "Click Arrange below to place windows into the grid"
        case .swapWindows: return "Drag one window on top of another and drop"
        case .resizeSharedBorder: return "Drag the border between two windows — both adjust together"
        case .groupWindows: return "Drag one window onto another to stack them in one slot"
        case .switchGroupWindow: return "Click or scroll the small badge on the window edge"
        case .revealNotchBar: return "Move your pointer up to the camera notch to reveal it"
        }
    }
}

nonisolated struct InteractiveTourModel: Equatable, Sendable {
    let mode: TilingMode
    let tasks: [TourTaskID]
    private(set) var completed: Set<TourTaskID> = []

    init(mode: TilingMode, hasNotchedHoverBar: Bool, alreadyArranged: Bool) {
        self.mode = mode
        self.tasks = Self.tasks(for: mode, hasNotchedHoverBar: hasNotchedHoverBar, alreadyArranged: alreadyArranged)
    }

    /// Mouse-first tour tasks tailored to the chosen mode and display hardware (no shortcuts required).
    static func tasks(for mode: TilingMode, hasNotchedHoverBar: Bool, alreadyArranged: Bool) -> [TourTaskID] {
        var list: [TourTaskID]
        switch mode {
        case .dragSnap, .none:
            list = [.dragToEdge, .dragToTopPicker]
        case .autoTiling:
            list = alreadyArranged ? [.swapWindows, .resizeSharedBorder] : [.arrangeWindows, .swapWindows, .resizeSharedBorder]
        case .manualAssignment:
            list = alreadyArranged ? [.groupWindows, .switchGroupWindow] : [.arrangeWindows, .groupWindows, .switchGroupWindow]
        }
        if hasNotchedHoverBar {
            list.append(.revealNotchBar)
        }
        return list
    }

    var activeTask: TourTaskID? {
        tasks.first { !completed.contains($0) }
    }

    var completedCount: Int {
        tasks.filter { completed.contains($0) }.count
    }

    var isAllDone: Bool {
        !tasks.isEmpty && tasks.allSatisfy(completed.contains)
    }

    @discardableResult
    mutating func markCompleted(_ task: TourTaskID) -> Bool {
        guard tasks.contains(task) else { return false }
        return completed.insert(task).inserted
    }
}

struct InteractiveTourView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var launchAtLogin = LaunchAtLoginManager.shared

    @State private var model: InteractiveTourModel
    @State private var hasEnoughWindows: Bool = false

    let onFinish: () -> Void

    init(mode: TilingMode, hasNotchedHoverBar: Bool, alreadyArranged: Bool, onFinish: @escaping () -> Void) {
        _model = State(initialValue: InteractiveTourModel(
            mode: mode,
            hasNotchedHoverBar: hasNotchedHoverBar,
            alreadyArranged: alreadyArranged
        ))
        self.onFinish = onFinish
    }

    private var modeLabel: String {
        model.mode == .none ? TilingMode.dragSnap.displayName : model.mode.displayName
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        VStack(alignment: .leading, spacing: 12) {
            header

            VStack(spacing: 6) {
                ForEach(model.tasks) { task in
                    taskRow(task)
                }
            }

            footer
        }
        .padding(16)
        .frame(width: 400)
        .background {
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                shape.fill(Color(red: 0.06, green: 0.07, blue: 0.10).opacity(0.76))
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.24), Color.white.opacity(0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            refreshWindowCount()
            triggerNotchPointerIfActive()
        }
        .onChange(of: model.activeTask) { _, _ in
            triggerNotchPointerIfActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dragSnapDidSnap).receive(on: RunLoop.main)) { _ in
            complete(.dragToEdge)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dragSnapDidSnapFromPicker).receive(on: RunLoop.main)) { _ in
            complete(.dragToTopPicker)
        }
        .onReceive(NotificationCenter.default.publisher(for: .raptoTourDidSwapWindows).receive(on: RunLoop.main)) { _ in
            complete(.swapWindows)
        }
        .onReceive(NotificationCenter.default.publisher(for: .raptoTourDidResizeSlot).receive(on: RunLoop.main)) { _ in
            complete(.resizeSharedBorder)
        }
        .onReceive(NotificationCenter.default.publisher(for: .raptoTourDidGroupWindows).receive(on: RunLoop.main)) { _ in
            complete(.groupWindows)
        }
        .onReceive(NotificationCenter.default.publisher(for: .raptoTourDidCycleGroup).receive(on: RunLoop.main)) { _ in
            complete(.switchGroupWindow)
        }
        .onReceive(NotificationCenter.default.publisher(for: .raptoTourDidRevealNotchBar).receive(on: RunLoop.main)) { _ in
            complete(.revealNotchBar)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isAllDone ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.isAllDone ? Color.green : Color.accentColor)

            Text(model.isAllDone ? "You're all set!" : "Quick Tour · \(modeLabel)")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            Text("\(model.completedCount)/\(model.tasks.count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.1), in: Capsule())

            Button(action: onFinish) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close tour")
        }
    }

    private func taskRow(_ task: TourTaskID) -> some View {
        let isDone = model.completed.contains(task)
        let isCurrent = model.activeTask == task

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: isDone ? "checkmark.circle.fill" : (isCurrent ? task.icon : "circle"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isDone ? Color.green : (isCurrent ? Color.accentColor : Color.white.opacity(0.35)))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                    .strikethrough(isDone, color: .white.opacity(0.4))
                    .foregroundStyle(isDone ? Color.white.opacity(0.45) : Color.white.opacity(isCurrent ? 0.96 : 0.72))

                if isCurrent {
                    Text(task.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isCurrent ? Color.white.opacity(0.10) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isCurrent ? Color.white.opacity(0.20) : Color.clear, lineWidth: 0.75)
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isDone)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isAllDone && !launchAtLogin.isEnabled {
                Toggle("Launch Rapto at Login", isOn: $launchAtLogin.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
            }

            HStack(spacing: 8) {
                if !hasEnoughWindows && !model.isAllDone {
                    Button("Open 2 Sample Windows") {
                        appState.openTourSandboxWindows()
                        refreshWindowCount()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if model.activeTask == .arrangeWindows {
                    Button("Arrange Now") {
                        appState.arrangeWindowsForFirstRun(mode: model.mode)
                        complete(.arrangeWindows)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if appState.hasUndoableFirstArrange {
                    Button("Put Windows Back") {
                        appState.undoFirstRunArrange()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button(model.isAllDone ? "Done" : "Finish") {
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.top, 2)
    }

    private func complete(_ task: TourTaskID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            _ = model.markCompleted(task)
        }
    }

    private func refreshWindowCount() {
        let screen = appState.screenManager.activeScreen()
        hasEnoughWindows = appState.eligibleWindowsForFirstArrange(on: screen).count >= 2
    }

    private func triggerNotchPointerIfActive() {
        guard model.activeTask == .revealNotchBar else { return }
        appState.showNotchDesktopsBarHintIfNeeded(force: true)
    }
}
