//
//  OverlayView.swift
//  Rapto
//
//  Main overlay view that composes all UI components for window management.
//

import SwiftUI

struct OverlayView: View {
    @EnvironmentObject var appState: AppState
    
    @State private var customTemplateName: String = ""
    @FocusState private var isLayoutNameFocused: Bool
    @State private var highlightMissingLayoutName: Bool = false
    @State private var isShowingCustomDraft: Bool = true
    @State private var isShowingFocusDraft: Bool = true
    
    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            if appState.isCreatingCustomGrid {
                customGridCreationView
            } else if appState.isCreatingFocusZone {
                focusZoneCreationView
            } else {
                normalModeView
            }
        }
        .onAppear {
            debugLog("OverlayView", "onAppear called - overlay opened")
            // Screen recording permission is only requested during onboarding
            // to avoid spamming users who don't want window previews
            loadWindows()
            debugLog("OverlayView", "onAppear completed, windows count: \(appState.windows.count)")
        }
    }
    
    // MARK: - Normal Mode View
    
    private var normalModeView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 0) {
                let partitioned = appState.partitionedTemplates(for: appState.screenManager.activeScreen())
                GridTemplatePicker(
                    templates: partitioned.primary,
                    selectedTemplate: $appState.selectedTemplate,
                    onSelect: { template in
                        appState.selectTemplate(template)
                    },
                    onAddCustom: {
                        appState.startCustomGridCreation()
                    },
                    onDeleteCustom: { template in
                        appState.deleteCustomTemplate(template)
                    },
                    onRenameCustom: { template, newName in
                        appState.renameCustomTemplate(template, newName: newName)
                    },
                    customTemplateIDs: Set(appState.customTemplates.map { $0.id }),
                    dragSnapPickerTemplateIDs: appState.dragSnapPickerTemplateIDs,
                    onToggleDragSnapPicker: { template in
                        appState.toggleInDragSnapPicker(template)
                    },
                    onHideStandard: { template in
                        appState.hideStandardTemplate(template)
                    },
                    onUnhideStandard: { template in
                        appState.unhideStandardTemplate(template)
                    },
                    ultrawideTemplates: partitioned.ultrawide,
                    hiddenTemplates: appState.hiddenStandardTemplates,
                    trailingContent: focusZoneButton
                )
                OverlayCloseButton { dismissOverlay() }
                    .padding(.trailing, 24)
            }
            .padding(.top, 24)
            
            if let template = appState.selectedTemplate {
                VStack(spacing: 8) {
                    ZoneIndicator(
                        template: template,
                        currentIndex: appState.currentZoneIndex,
                        assignedCount: appState.assignedWindows.count
                    )
                    
                    if appState.isGroupingEnabled && !GroupTabIndicatorsView.groupSlots(in: appState).isEmpty {
                        GroupTabIndicatorsView(appState: appState)
                    }
                }
            }
            
            WindowGrid(
                windows: appState.windows,
                otherDisplayWindows: appState.windowsOnOtherDisplays,
                assignedWindows: appState.assignedWindows,
                onWindowSelect: { window in
                    appState.assignWindow(window)
                }
            )
            
            Spacer(minLength: 0)
            
            VStack(spacing: 12) {
                if appState.selectedTemplate != nil && !appState.assignedWindows.isEmpty {
                    Button(action: {
                        appState.applyLayout()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                            Text("Apply Layout")
                                .fontWeight(.semibold)
                            Text("(\(appState.assignedWindows.count)/\(appState.selectedTemplate?.zones.count ?? 0))")
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
                }
                
                Text("Press ESC to cancel • Enter to apply")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.bottom, 24)
        }
    }
    
    // MARK: - Custom Grid Creation View
    
    private var visibleScreenFrame: CGRect {
        appState.screenManager.visibleFrame()
    }
    
    private var customGridCreationView: some View {
        GeometryReader { geometry in
            let screenFrame = NSScreen.main?.frame ?? .zero
            let visibleFrame = visibleScreenFrame
            
            // visibleFrame is in AppKit coordinates (bottom-left origin)
            let offset = Self.visibleAreaOffset(screenFrame: screenFrame, visibleFrame: visibleFrame)
            let offsetX = offset.x
            let offsetY = offset.y
            
            ZStack {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.85),
                        Color(hue: 0.65, saturation: 0.3, brightness: 0.1).opacity(0.85)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: visibleFrame.width, height: visibleFrame.height)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color(hue: 0.58, saturation: 0.7, brightness: 0.9).opacity(0.6),
                                        Color(hue: 0.65, saturation: 0.5, brightness: 0.8).opacity(0.4)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                    )
                    .position(
                        x: offsetX + visibleFrame.width / 2,
                        y: offsetY + visibleFrame.height / 2
                    )
                
                // Pass only the size (not the full frame with origin) since ZoneCreatorView
                // works in SwiftUI coordinates and is positioned separately
                ZoneCreatorView(
                    screenSize: CGSize(width: visibleFrame.width, height: visibleFrame.height),
                    zones: $appState.tempZones,
                    isShowingDraft: $isShowingCustomDraft,
                    allowsSplitting: true,
                    onZoneCreated: { zone in
                        appState.addTempZone(zone)
                    },
                    onZoneUpdated: { zone in
                        appState.updateTempZone(zone)
                    },
                    onZoneDeleted: { zone in
                        appState.removeTempZone(zone)
                    },
                    onZoneSplit: { original, first, second in
                        appState.splitTempZone(original, into: first, and: second)
                    }
                )
                .frame(width: visibleFrame.width, height: visibleFrame.height)
                .position(
                    x: offsetX + visibleFrame.width / 2,
                    y: offsetY + visibleFrame.height / 2
                )
                
                VStack {
                    customGridToolbar
                        .padding(.horizontal, 40)
                        .padding(.top, offsetY + 20)
                    
                    Spacer()
                    
                    customGridInstructions
                        .padding(.bottom, 40)
                }
            }
        }
    }
    
    private var customGridInstructions: some View {
        HStack(spacing: 20) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color(hue: 0.58, saturation: 0.7, brightness: 0.95))
                Text("Drag to move or resize (hold ⌥ for free)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
            
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: 20)
            
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color(hue: 0.35, saturation: 0.7, brightness: 0.85))
                Text("Click empty area or + Add Zone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }

            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: 20)

            HStack(spacing: 8) {
                Image(systemName: "list.number")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color(hue: 0.12, saturation: 0.75, brightness: 0.95))
                Text("Zones fill in order 1 → 2 → 3")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
            
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: 20)
            
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color(hue: 0.58, saturation: 0.7, brightness: 0.95))
                Text("Click zone to edit · Double-click to delete")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
            
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: 20)
            
            HStack(spacing: 8) {
                Text("ESC")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                            )
                    )
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.2), Color.white.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.3), radius: 20, y: 10)
        )
    }
    
    private var customGridSaveRequirement: CustomLayoutSaveRequirement {
        CustomLayoutSaveRequirement.evaluate(
            zoneCount: appState.tempZones.count,
            layoutName: customTemplateName
        )
    }

    private func focusLayoutNameField() {
        NSApp.windows.first(where: { $0 is OverlayPanel })?.makeKey()
        withAnimation(.easeInOut(duration: 0.18)) {
            highlightMissingLayoutName = true
        }
        isLayoutNameFocused = true
    }

    private var customGridToolbar: some View {
        let saveReq = customGridSaveRequirement
        let isSaveReady: Bool = {
            if case .ready = saveReq { return true }
            return false
        }()

        return HStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Color(hue: 0.58, saturation: 0.7, brightness: 0.95))
                
                TextField("Layout name...", text: $customTemplateName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .focused($isLayoutNameFocused)
                    .onChange(of: customTemplateName) { _, newValue in
                        if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            highlightMissingLayoutName = false
                        }
                    }
                    .frame(width: 190)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(highlightMissingLayoutName ? 0.16 : 0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        highlightMissingLayoutName
                                            ? Color.orange.opacity(0.95)
                                            : Color.white.opacity(0.2),
                                        lineWidth: highlightMissingLayoutName ? 1.5 : 1
                                    )
                            )
                    )
            }
            
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(
                            appState.tempZones.isEmpty
                                ? AnyShapeStyle(Color.white.opacity(0.2))
                                : AnyShapeStyle(LinearGradient(
                                    colors: [
                                        Color(hue: 0.35, saturation: 0.7, brightness: 0.85),
                                        Color(hue: 0.38, saturation: 0.6, brightness: 0.7)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                        )
                        .frame(width: 28, height: 28)
                    
                    Text("\(appState.tempZones.count)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                
                Text("zone\(appState.tempZones.count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }

            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isShowingCustomDraft = true
                }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Add Zone")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundColor(isShowingCustomDraft ? .white.opacity(0.4) : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            isShowingCustomDraft
                                ? Color.white.opacity(0.06)
                                : Color(hue: 0.58, saturation: 0.75, brightness: 0.92).opacity(0.32)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    isShowingCustomDraft
                                        ? Color.white.opacity(0.12)
                                        : Color(hue: 0.58, saturation: 0.75, brightness: 0.95).opacity(0.65),
                                    lineWidth: 1
                                )
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(isShowingCustomDraft)
            .help(isShowingCustomDraft ? "Place or close the active draft zone first" : "Add another zone (or click any empty area)")

            if appState.canPopulateTempZonesFromWindows(on: NSScreen.main) {
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        let count = appState.populateTempZonesFromOpenWindows(on: NSScreen.main)
                        if count > 0 {
                            isShowingCustomDraft = false
                            if customTemplateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                customTemplateName = appState.newLayoutFromWindowsName()
                                highlightMissingLayoutName = false
                            }
                        }
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("Use Open Windows")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.88))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .help("Fill zones from the windows currently open on this display")
            }
            
            Spacer()

            if let statusText = saveReq.statusText, let statusIcon = saveReq.statusIcon {
                let isNameHint = (saveReq == .needsName)
                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(isNameHint ? .orange : Color(hue: 0.58, saturation: 0.7, brightness: 0.95))
                    Text(statusText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.86))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isNameHint ? Color.orange.opacity(0.16) : Color.white.opacity(0.08))
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isNameHint ? Color.orange.opacity(0.4) : Color.white.opacity(0.15),
                                    lineWidth: 1
                                )
                        )
                )
                .contentShape(Capsule())
                .onTapGesture {
                    if isNameHint {
                        focusLayoutNameField()
                    }
                }
            }
            
            HStack(spacing: 12) {
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        appState.clearTempZones()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .medium))
                        Text("Clear")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(appState.tempZones.isEmpty ? .white.opacity(0.3) : .white.opacity(0.8))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(appState.tempZones.isEmpty ? 0.05 : 0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(appState.tempZones.isEmpty)
                
                Button(action: {
                    highlightMissingLayoutName = false
                    customTemplateName = ""
                    isShowingCustomDraft = true
                    appState.cancelCustomGridCreation()
                }) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    switch saveReq {
                    case .needsZones:
                        break
                    case .needsName:
                        focusLayoutNameField()
                    case .ready(let trimmedName):
                        highlightMissingLayoutName = false
                        isShowingCustomDraft = true
                        appState.saveCustomTemplate(name: trimmedName)
                        customTemplateName = ""
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Save Layout")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(saveReq == .needsZones ? .white.opacity(0.45) : .white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                !isSaveReady
                                    ? AnyShapeStyle(Color.white.opacity(saveReq == .needsName ? 0.14 : 0.08))
                                    : AnyShapeStyle(LinearGradient(
                                        colors: [
                                            Color(hue: 0.35, saturation: 0.7, brightness: 0.85),
                                            Color(hue: 0.38, saturation: 0.8, brightness: 0.7)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        saveReq == .needsName ? Color.orange.opacity(0.45) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                            .shadow(
                                color: !isSaveReady
                                    ? Color.clear
                                    : Color(hue: 0.35, saturation: 0.7, brightness: 0.85).opacity(0.4),
                                radius: 8,
                                y: 4
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(saveReq == .needsZones)
                .help(saveReq.statusText ?? "Save custom layout")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.white.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.3), radius: 20, y: 10)
        )
    }
    
    // MARK: - Focus Zone UI
    
    private var focusZoneButton: some View {
        Menu {
            Button {
                appState.startFocusZoneCreation()
            } label: {
                Label(appState.focusModeZone != nil ? "Edit custom zone" : "Create custom zone", systemImage: "pencil.and.outline")
            }
            
            if appState.focusModeZone != nil {
                Divider()
                Button(role: .destructive) {
                    appState.clearFocusZone()
                } label: {
                    Label("Reset to full screen", systemImage: "arrow.counterclockwise")
                }
            }
            
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "eye")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(appState.focusModeZone != nil ? .orange : .purple)
                    
                    Text("FOCUS MODE")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1)
                        .foregroundColor(.white.opacity(0.9))
                    
                    Spacer()
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
                
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black.opacity(0.4))
                        .frame(width: 120, height: 75)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                        )
                    
                    if let zone = appState.focusModeZone {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [Color.orange, Color.orange.opacity(0.6)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(
                                width: 112 * zone.width,
                                height: 67 * zone.height
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Color.white, lineWidth: 2)
                            )
                            .offset(
                                x: 112 * (zone.origin.x - 0.5 + zone.width / 2),
                                y: 67 * (zone.origin.y - 0.5 + zone.height / 2)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [Color.purple.opacity(0.6), Color.purple.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 112, height: 67)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5)
                            )
                        
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(appState.focusModeZone != nil ? Color.orange : Color.purple)
                        .frame(width: 6, height: 6)
                    
                    Text(appState.focusModeZone != nil ? "Custom zone" : "Full screen")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 150)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                LinearGradient(
                                    colors: appState.focusModeZone != nil 
                                        ? [Color.orange.opacity(0.6), Color.orange.opacity(0.2)]
                                        : [Color.purple.opacity(0.5), Color.purple.opacity(0.2)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                    )
                    .shadow(color: (appState.focusModeZone != nil ? Color.orange : Color.purple).opacity(0.3), radius: 8, x: 0, y: 4)
            )
        }
        .menuStyle(.borderlessButton)
        .help("Configure Focus Mode zone — click to customize where windows expand")
    }
    
    private var focusZoneCreationView: some View {
        GeometryReader { geometry in
            let screenFrame = NSScreen.main?.frame ?? .zero
            let visibleFrame = visibleScreenFrame
            
            let offset = Self.visibleAreaOffset(screenFrame: screenFrame, visibleFrame: visibleFrame)
            let offsetX = offset.x
            let offsetY = offset.y
            
            ZStack {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.85),
                        Color(hue: 0.08, saturation: 0.3, brightness: 0.12).opacity(0.85)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: visibleFrame.width, height: visibleFrame.height)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.orange.opacity(0.6),
                                        Color(hue: 0.08, saturation: 0.8, brightness: 0.9).opacity(0.4)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                    )
                    .position(
                        x: offsetX + visibleFrame.width / 2,
                        y: offsetY + visibleFrame.height / 2
                    )
                
                ZoneCreatorView(
                    screenSize: CGSize(width: visibleFrame.width, height: visibleFrame.height),
                    zones: $appState.tempZones,
                    isShowingDraft: $isShowingFocusDraft,
                    allowsSplitting: false,
                    onZoneCreated: { zone in
                        // Only allow one zone for focus mode
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            appState.tempZones = [zone]
                        }
                    },
                    onZoneUpdated: { zone in
                        appState.updateTempZone(zone)
                    },
                    onZoneDeleted: { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            appState.tempZones = []
                        }
                    }
                )
                .frame(width: visibleFrame.width, height: visibleFrame.height)
                .position(
                    x: offsetX + visibleFrame.width / 2,
                    y: offsetY + visibleFrame.height / 2
                )
                
                VStack {
                    focusZoneToolbar
                        .padding(.horizontal, 40)
                        .padding(.top, offsetY + 20)
                    
                    Spacer()
                    
                    focusZoneInstructions
                        .padding(.bottom, 40)
                }
            }
        }
    }
    
    private var focusZoneInstructions: some View {
        HStack(spacing: 24) {
            HStack(spacing: 8) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.orange)
                Text("Drag handles to set zone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
            
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: 20)
            
            HStack(spacing: 8) {
                Image(systemName: "1.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.orange.opacity(0.8))
                Text("Single zone only")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }

            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: 20)

            HStack(spacing: 8) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.orange)
                Text("Click the zone to resize it")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
            
            Rectangle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 1, height: 20)
            
            HStack(spacing: 8) {
                Text("ESC")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                            )
                    )
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.2), Color.white.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.3), radius: 20, y: 10)
        )
    }
    
    private var focusZoneToolbar: some View {
        HStack(spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.orange)
                
                Text("Focus Zone")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            
            HStack(spacing: 8) {
                if !appState.tempZones.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color(hue: 0.35, saturation: 0.7, brightness: 0.85))
                        Text("Zone defined")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color(hue: 0.35, saturation: 0.7, brightness: 0.85).opacity(0.2))
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color(hue: 0.35, saturation: 0.7, brightness: 0.85).opacity(0.4), lineWidth: 1)
                            )
                    )
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.orange.opacity(0.6))
                            .frame(width: 8, height: 8)
                        Text("Click + to create zone")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button(action: {
                    appState.cancelFocusZoneSelection()
                }) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    appState.saveFocusZoneFromTemp()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Save Zone")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                appState.tempZones.isEmpty
                                    ? AnyShapeStyle(Color.gray.opacity(0.3))
                                    : AnyShapeStyle(LinearGradient(
                                        colors: [
                                            Color.orange,
                                            Color(hue: 0.08, saturation: 0.8, brightness: 0.8)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                            )
                            .shadow(
                                color: appState.tempZones.isEmpty
                                    ? Color.clear
                                    : Color.orange.opacity(0.4),
                                radius: 8,
                                y: 4
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(appState.tempZones.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.white.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.3), radius: 20, y: 10)
        )
    }
    
    // MARK: - Private Methods
    
    /// Windows are loaded via CGWindowListCopyWindowInfo (doesn't trigger permission dialog)
    /// Thumbnails in WindowThumbnail.swift check permission before using ScreenCaptureKit
    private func loadWindows() {
        debugLog("OverlayView", "loadWindows() called")
        appState.loadOverlayWindows()
        debugLog("OverlayView", "Loaded \(appState.windows.count) windows, \(appState.windowsOnOtherDisplays.count) on other displays")
    }
    
    private func dismissOverlay() {
        appState.dismissOverlay()
    }
}

/// Round close button for the overlay, the same as pressing ESC
private struct OverlayCloseButton: View {
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.accentColor)
                        .overlay(Circle().fill(Color.white.opacity(isHovered ? 0.2 : 0)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                        .shadow(color: Color.accentColor.opacity(0.5), radius: isHovered ? 12 : 8, y: 3)
                )
                .scaleEffect(isHovered ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .help("Close (Esc)")
        .accessibilityLabel("Close")
    }
}

extension OverlayView {
    /// Where the visible area starts inside the screen, counted from the screen's top-left corner
    /// (both frames in AppKit coordinates, as screens below or above the main one have a non-zero origin).
    static func visibleAreaOffset(screenFrame: CGRect, visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: visibleFrame.minX - screenFrame.minX, y: screenFrame.maxY - visibleFrame.maxY)
    }
}

#if DEBUG
struct OverlayView_Previews: PreviewProvider {
    static var previews: some View {
        OverlayView()
            .environmentObject(AppState())
            .frame(width: 800, height: 600)
    }
}
#endif
