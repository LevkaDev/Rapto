//
//  InteractiveTourView.swift
//  Rapto
//
//  Pure two-part state machine (`InteractiveTourModel`) and compact floating Window Flow HUD
//  for the mouse-first interactive tour:
//    Part 1 — chosen tiling mode (Drag to Snap, Auto-tiling, or Manual)
//    Part 2 — Desktops Bar (add desktop if needed, drag an app across) & Window Flow
//

import Combine
import SwiftUI

nonisolated enum TourPhase: Int, Equatable, Hashable, Sendable {
    case mode = 1
    case desktopsAndFlow = 2
}

nonisolated enum TourTaskID: String, Equatable, Hashable, CaseIterable, Sendable, Identifiable {
    // Part 1: chosen window mode
    case dragToEdge
    case dragToTopPicker
    case arrangeWindows
    case swapWindows
    case resizeSharedBorder
    case groupWindows
    case switchGroupWindow

    // Part 2: Desktops Bar & Window Flow
    case revealNotchBar
    case addSecondDesktop
    case moveAppToDesktop
    case openWindowFlow

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
        case .addSecondDesktop: return "plus.rectangle.on.rectangle"
        case .moveAppToDesktop: return "arrow.right.square"
        case .openWindowFlow: return "rectangle.stack.badge.play"
        }
    }

    var title: String {
        switch self {
        case .dragToEdge: return "Snap a window near a screen edge"
        case .dragToTopPicker: return "Drop a window on the top layout bar"
        case .arrangeWindows: return "Arrange your open windows"
        case .swapWindows: return "Swap two windows"
        case .resizeSharedBorder: return "Resize a shared border"
        case .groupWindows: return "Group two windows in one slot"
        case .switchGroupWindow: return "Switch windows with the group indicator"
        case .revealNotchBar: return "Find the Desktops Bar under the notch"
        case .addSecondDesktop: return "Add a second desktop"
        case .moveAppToDesktop: return "Move an app to another desktop"
        case .openWindowFlow: return "Open Window Flow"
        }
    }

    func detail(windowFlowShortcut: String? = nil) -> String {
        switch self {
        case .dragToEdge:
            return "Move near the left, right or bottom edge and let go as soon as the highlight appears"
        case .dragToTopPicker:
            return "Start dragging to reveal the bar at the top, then drop on a zone"
        case .arrangeWindows:
            return "Click Arrange Now below to place windows into the grid"
        case .swapWindows:
            return "Drag one window on top of another and drop"
        case .resizeSharedBorder:
            return "Drag the border between two windows — both adjust together"
        case .groupWindows:
            return "Drag one window onto another to stack them in one slot"
        case .switchGroupWindow:
            return "Click or scroll the small badge on the window edge"
        case .revealNotchBar:
            return "Move your pointer up to the camera notch to reveal the Desktops Bar"
        case .addSecondDesktop:
            return "Click + in the Desktops Bar at the top, or press Add Desktop below"
        case .moveAppToDesktop:
            return "Drag any app icon in the Desktops Bar onto another desktop number"
        case .openWindowFlow:
            if let shortcut = windowFlowShortcut, !shortcut.isEmpty {
                return "Press \(shortcut) or click Open Window Flow below to browse all windows in 3D"
            }
            return "Click Open Window Flow below to browse all windows across desktops in 3D"
        }
    }
}

nonisolated struct InteractiveTourModel: Equatable, Sendable {
    let mode: TilingMode
    let modeTasks: [TourTaskID]
    let desktopsTasks: [TourTaskID]
    private(set) var phase: TourPhase = .mode
    private(set) var completed: Set<TourTaskID> = []

    init(
        mode: TilingMode,
        hasNotchedHoverBar: Bool,
        alreadyArranged: Bool,
        showsSpaceBar: Bool = true,
        desktopCount: Int = 2
    ) {
        self.mode = mode
        self.modeTasks = Self.modeTasks(for: mode, alreadyArranged: alreadyArranged)
        self.desktopsTasks = Self.desktopsAndFlowTasks(
            hasNotchedHoverBar: hasNotchedHoverBar,
            showsSpaceBar: showsSpaceBar,
            desktopCount: desktopCount
        )
    }

    /// Part 1: mouse-first tasks tailored to the chosen tiling mode.
    static func modeTasks(for mode: TilingMode, alreadyArranged: Bool) -> [TourTaskID] {
        switch mode {
        case .dragSnap, .none:
            return [.dragToTopPicker, .dragToEdge]
        case .autoTiling:
            return alreadyArranged ? [.swapWindows, .resizeSharedBorder] : [.arrangeWindows, .swapWindows, .resizeSharedBorder]
        case .manualAssignment:
            return alreadyArranged ? [.groupWindows, .switchGroupWindow] : [.arrangeWindows, .groupWindows, .switchGroupWindow]
        }
    }

    /// Part 2: Desktops Bar (find under notch if hidden, add 2nd desktop if needed, move an app)
    /// culminating in Window Flow.
    static func desktopsAndFlowTasks(
        hasNotchedHoverBar: Bool,
        showsSpaceBar: Bool,
        desktopCount: Int
    ) -> [TourTaskID] {
        var list: [TourTaskID] = []
        if showsSpaceBar {
            if hasNotchedHoverBar {
                list.append(.revealNotchBar)
            }
            if desktopCount < 2 {
                list.append(.addSecondDesktop)
            }
            list.append(.moveAppToDesktop)
        }
        list.append(.openWindowFlow)
        return list
    }

    /// Tasks shown in the currently active phase.
    var tasks: [TourTaskID] {
        switch phase {
        case .mode: return modeTasks
        case .desktopsAndFlow: return desktopsTasks
        }
    }

    var allTasks: [TourTaskID] {
        modeTasks + desktopsTasks
    }

    var activeTask: TourTaskID? {
        tasks.first { !completed.contains($0) }
    }

    var completedCount: Int {
        tasks.filter { completed.contains($0) }.count
    }

    var isCurrentPhaseDone: Bool {
        !tasks.isEmpty && tasks.allSatisfy(completed.contains)
    }

    var isAllDone: Bool {
        phase == .desktopsAndFlow && isCurrentPhaseDone
    }

    @discardableResult
    mutating func markCompleted(_ task: TourTaskID) -> Bool {
        guard allTasks.contains(task) else { return false }
        return completed.insert(task).inserted
    }

    /// Advances from Part 1 (Mode) into Part 2 (Desktops & Window Flow).
    @discardableResult
    mutating func advanceToDesktopsAndFlow() -> Bool {
        guard phase == .mode else { return false }
        phase = .desktopsAndFlow
        return true
    }
}

struct InteractiveTourView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var launchAtLogin = LaunchAtLoginManager.shared

    @State private var model: InteractiveTourModel
    @State private var hasEnoughWindows: Bool = false
    @State private var hasRealAppWindows: Bool = true
    @State private var pendingPhaseAdvance: DispatchWorkItem?

    let windowFlowShortcut: String?
    let onLayoutChange: () -> Void
    let onFinish: () -> Void

    init(
        mode: TilingMode,
        hasNotchedHoverBar: Bool,
        alreadyArranged: Bool,
        showsSpaceBar: Bool = true,
        initialDesktopCount: Int = 2,
        windowFlowShortcut: String? = nil,
        onLayoutChange: @escaping () -> Void = {},
        onFinish: @escaping () -> Void
    ) {
        _model = State(initialValue: InteractiveTourModel(
            mode: mode,
            hasNotchedHoverBar: hasNotchedHoverBar,
            alreadyArranged: alreadyArranged,
            showsSpaceBar: showsSpaceBar,
            desktopCount: initialDesktopCount
        ))
        self.windowFlowShortcut = windowFlowShortcut
        self.onLayoutChange = onLayoutChange
        self.onFinish = onFinish
    }

    private var modeLabel: String {
        model.mode == .none ? TilingMode.dragSnap.displayName : model.mode.displayName
    }

    private var headerTitle: String {
        if model.isAllDone {
            return "You're all set!"
        }
        switch model.phase {
        case .mode:
            return "Part 1 of 2 · \(modeLabel)"
        case .desktopsAndFlow:
            return "Part 2 of 2 · Desktops & Window Flow"
        }
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
        .frame(width: 420)
        .background {
            ZStack {
                WindowFlowMaskedBlurView(cornerRadius: 16)
                shape.fill(WindowFlowThemeTokens.glassFill)
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(WindowFlowThemeTokens.rimGradient, lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            refreshWindowCounts()
            triggerNotchPointerIfActive()
            onLayoutChange()
        }
        .onDisappear {
            pendingPhaseAdvance?.cancel()
            pendingPhaseAdvance = nil
        }
        .onChange(of: model.phase) { _, newPhase in
            if newPhase == .desktopsAndFlow {
                appState.closeTourSandboxWindows()
                refreshWindowCounts()
                syncDesktopCountCompletion()
            }
            triggerNotchPointerIfActive()
            onLayoutChange()
        }
        .onChange(of: model.activeTask) { _, _ in
            refreshWindowCounts()
            triggerNotchPointerIfActive()
            onLayoutChange()
        }
        .onChange(of: model.isAllDone) { _, _ in
            onLayoutChange()
        }
        .onChange(of: appState.hasUndoableFirstArrange) { _, _ in
            onLayoutChange()
        }
        .onReceive(appState.spaceBarController.$displays.receive(on: RunLoop.main)) { _ in
            refreshWindowCounts()
            syncDesktopCountCompletion()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dragSnapDidSnap).receive(on: RunLoop.main)) { notification in
            let fromPicker = notification.userInfo?["fromPicker"] as? Bool ?? false
            if !fromPicker {
                complete(.dragToEdge)
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .raptoTourDidAddDesktop).receive(on: RunLoop.main)) { _ in
            complete(.addSecondDesktop)
        }
        .onReceive(NotificationCenter.default.publisher(for: .raptoTourDidMoveWindowToDesktop).receive(on: RunLoop.main)) { _ in
            complete(.moveAppToDesktop)
        }
        .onReceive(NotificationCenter.default.publisher(for: .raptoTourDidOpenWindowFlow).receive(on: RunLoop.main)) { _ in
            complete(.openWindowFlow)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isAllDone ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.isAllDone ? Color(red: 0.32, green: 0.86, blue: 0.50) : WindowFlowThemeTokens.accentSky)

            Text(headerTitle)
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
                .foregroundStyle(
                    isDone
                        ? Color(red: 0.32, green: 0.86, blue: 0.50)
                        : (isCurrent ? WindowFlowThemeTokens.accentSky : Color.white.opacity(0.35))
                )
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(task.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                    .strikethrough(isDone, color: .white.opacity(0.4))
                    .foregroundStyle(isDone ? Color.white.opacity(0.45) : Color.white.opacity(isCurrent ? 0.96 : 0.72))

                if isCurrent {
                    Text(task.detail(windowFlowShortcut: windowFlowShortcut))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.74))
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
                leadingActionButtons

                Spacer()

                if model.phase == .mode && !model.isAllDone {
                    Button("Next: Desktops & Flow") {
                        advanceToPartTwoNow()
                    }
                    .buttonStyle(WindowFlowSecondaryButtonStyle(compact: true))
                }

                Button(model.isAllDone ? "Done" : "Finish") {
                    onFinish()
                }
                .buttonStyle(WindowFlowPrimaryButtonStyle(compact: true))
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var leadingActionButtons: some View {
        switch model.phase {
        case .mode:
            if !hasEnoughWindows && !model.isCurrentPhaseDone {
                Button("Open 2 Sample Windows") {
                    appState.openTourSandboxWindows()
                    refreshWindowCounts()
                }
                .buttonStyle(WindowFlowSecondaryButtonStyle(compact: true))
            } else if model.activeTask == .arrangeWindows {
                Button("Arrange Now") {
                    appState.arrangeWindowsForFirstRun(mode: model.mode)
                    complete(.arrangeWindows)
                }
                .buttonStyle(WindowFlowPrimaryButtonStyle(compact: true))
            }

            if appState.hasUndoableFirstArrange {
                Button("Put Windows Back") {
                    appState.undoFirstRunArrange()
                }
                .buttonStyle(WindowFlowSecondaryButtonStyle(compact: true))
            }

        case .desktopsAndFlow:
            switch model.activeTask {
            case .addSecondDesktop:
                Button("Add Desktop") {
                    appState.addDesktopOnActiveScreen()
                }
                .buttonStyle(WindowFlowPrimaryButtonStyle(compact: true))

            case .moveAppToDesktop:
                if !hasRealAppWindows {
                    Button("Open Finder") {
                        appState.openSampleFinderWindowForTour()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            refreshWindowCounts()
                        }
                    }
                    .buttonStyle(WindowFlowPrimaryButtonStyle(compact: true))
                }

            case .openWindowFlow:
                Button("Open Window Flow") {
                    appState.openWindowFlowFromTour()
                }
                .buttonStyle(WindowFlowPrimaryButtonStyle(compact: true))

            default:
                EmptyView()
            }
        }
    }

    private func complete(_ task: TourTaskID) {
        let wasPartOneDone = model.phase == .mode && model.isCurrentPhaseDone
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            _ = model.markCompleted(task)
        }
        if !wasPartOneDone && model.phase == .mode && model.isCurrentPhaseDone {
            scheduleAdvanceToPartTwo()
        }
    }

    private func scheduleAdvanceToPartTwo() {
        pendingPhaseAdvance?.cancel()
        let work = DispatchWorkItem { [self] in
            advanceToPartTwoNow()
        }
        pendingPhaseAdvance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func advanceToPartTwoNow() {
        pendingPhaseAdvance?.cancel()
        pendingPhaseAdvance = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.80)) {
            _ = model.advanceToDesktopsAndFlow()
        }
    }

    private func refreshWindowCounts() {
        let screen = appState.screenManager.activeScreen()
        hasEnoughWindows = appState.eligibleWindowsForFirstArrange(on: screen).count >= 2
        hasRealAppWindows = appState.hasRealAppWindowsOnActiveScreen
    }

    private func syncDesktopCountCompletion() {
        guard appState.desktopCountOnActiveScreen >= 2 else { return }
        if model.allTasks.contains(.addSecondDesktop) && !model.completed.contains(.addSecondDesktop) {
            complete(.addSecondDesktop)
        }
    }

    private func triggerNotchPointerIfActive() {
        guard model.activeTask == .revealNotchBar else { return }
        appState.showNotchDesktopsBarHintIfNeeded(force: true)
    }
}
