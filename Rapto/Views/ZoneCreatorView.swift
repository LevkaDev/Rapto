//
//  ZoneCreatorView.swift
//  Rapto
//
//  Interactive view for creating custom grid zones with resizable windows.
//  Features a modern, polished design with gradients, glass effects, and smooth animations.
//

import SwiftUI
import AppKit

// MARK: - Design Constants

private enum ZoneDesign {
    static let activeGradient = LinearGradient(
        colors: [
            Color(hue: 0.58, saturation: 0.8, brightness: 0.95),  // Vibrant cyan
            Color(hue: 0.65, saturation: 0.7, brightness: 0.85)   // Deep blue
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let activeBorderGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.9),
            Color(hue: 0.58, saturation: 0.6, brightness: 1.0).opacity(0.6)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let zoneColors: [(primary: Color, secondary: Color)] = [
        (Color(hue: 0.35, saturation: 0.7, brightness: 0.8), Color(hue: 0.38, saturation: 0.5, brightness: 0.6)),   // Emerald
        (Color(hue: 0.08, saturation: 0.8, brightness: 0.95), Color(hue: 0.05, saturation: 0.6, brightness: 0.7)), // Orange
        (Color(hue: 0.75, saturation: 0.6, brightness: 0.85), Color(hue: 0.78, saturation: 0.5, brightness: 0.65)), // Purple
        (Color(hue: 0.95, saturation: 0.7, brightness: 0.9), Color(hue: 0.98, saturation: 0.5, brightness: 0.7)),  // Pink
        (Color(hue: 0.15, saturation: 0.8, brightness: 0.9), Color(hue: 0.12, saturation: 0.6, brightness: 0.7)),  // Gold
        (Color(hue: 0.5, saturation: 0.6, brightness: 0.85), Color(hue: 0.52, saturation: 0.5, brightness: 0.65)), // Teal
    ]
    
    static func zoneGradient(for index: Int) -> LinearGradient {
        let colors = zoneColors[index % zoneColors.count]
        return LinearGradient(
            colors: [colors.primary, colors.secondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    static let handleSize: CGFloat = 14
    static let edgeHandleLength: CGFloat = 48
}

struct ZoneCreatorView: View {
    /// Screen size (width x height) to calculate relative frames
    /// This should be the visible screen area size, NOT including origin
    let screenSize: CGSize
    
    /// Currently created zones (relative frames)
    @Binding var zones: [Zone]
    
    let onZoneCreated: (Zone) -> Void

    let onZoneUpdated: (Zone) -> Void
    
    let onZoneDeleted: (Zone) -> Void
    
    @State private var currentZoneFrame: CGRect = CGRect(x: 100, y: 100, width: 300, height: 200)

    /// Zone being resized again. Nil while drawing the next zone.
    @State private var editingZoneID: UUID?

    /// Frame of the zone being drawn, kept while an earlier zone is resized
    @State private var draftFrame: CGRect?

    /// Single click waits briefly so a double-click can still delete the zone
    @State private var pendingEdit: DispatchWorkItem?
    
    private let minSize: CGFloat = 100

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var editAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.7)
    }
    
    var body: some View {
        GeometryReader { geometry in
            // Use provided screenSize for normalization
            // This is the actual visible screen area that windows can occupy
            let normalizationSize = screenSize
            
            ZStack {
                // Transparent, hit-testable background that fills the whole area
                Color.clear
                    .contentShape(Rectangle())
                
                // Display existing zones. The one being resized is the live window below.
                ForEach(Array(zones.enumerated()), id: \.element.id) { index, zone in
                    if zone.id != editingZoneID {
                        let absoluteFrame = absoluteFrame(for: zone.relativeFrame, in: normalizationSize)
                        ExistingZoneView(frame: absoluteFrame, index: index, totalZones: zones.count)
                            .onTapGesture(count: 2) {
                                pendingEdit?.cancel()
                                pendingEdit = nil
                                withAnimation(editAnimation) {
                                    onZoneDeleted(zone)
                                }
                            }
                            .onTapGesture(count: 1) {
                                scheduleEditing(zone, in: normalizationSize)
                            }
                    }
                }
                
                ResizableZoneWindow(
                    frame: $currentZoneFrame,
                    minSize: minSize,
                    containerSize: normalizationSize,
                    isEditing: editingZoneID != nil,
                    zoneNumber: editingZoneNumber,
                    showsFirstZonePrompt: zones.isEmpty,
                    onConfirm: {
                        if editingZoneID != nil {
                            finishEditing(in: normalizationSize)
                        } else {
                            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.4, dampingFraction: 0.75)) {
                                createZone(from: currentZoneFrame, in: normalizationSize)
                            }
                        }
                    },
                    onDelete: editingZoneID == nil ? nil : {
                        deleteEditingZone()
                    }
                )
            }
            .onAppear {
                currentZoneFrame = CGRect(
                    x: (normalizationSize.width - 300) / 2,
                    y: (normalizationSize.height - 200) / 2,
                    width: 300,
                    height: 200
                )
            }
        }
    }
    
    // MARK: - Private Methods
    
    /// Number of the zone being resized, matching the badge on placed zones
    private var editingZoneNumber: Int? {
        guard let id = editingZoneID,
              let index = zones.firstIndex(where: { $0.id == id }) else { return nil }
        return index + 1
    }

    /// Wait out the double-click, then pick the zone up for resizing
    private func scheduleEditing(_ zone: Zone, in size: CGSize) {
        pendingEdit?.cancel()
        let work = DispatchWorkItem {
            beginEditing(zone, in: size)
        }
        pendingEdit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    /// Pick up a placed zone so it can be moved and resized again.
    /// The zone still being drawn is remembered and comes back on confirm.
    private func beginEditing(_ zone: Zone, in size: CGSize) {
        guard zones.contains(where: { $0.id == zone.id }) else { return }
        guard zone.id != editingZoneID else { return }
        if editingZoneID != nil {
            commitEditing(in: size)
        } else {
            draftFrame = currentZoneFrame
        }
        withAnimation(editAnimation) {
            editingZoneID = zone.id
            currentZoneFrame = absoluteFrame(for: zone.relativeFrame, in: size)
        }
    }

    /// Write the live frame back onto the zone being resized
    private func commitEditing(in size: CGSize) {
        guard let id = editingZoneID,
              let zone = zones.first(where: { $0.id == id }) else { return }
        let updated = Zone(
            id: zone.id,
            relativeFrame: relativeFrame(from: currentZoneFrame, in: size),
            fillOrder: zone.fillOrder
        )
        onZoneUpdated(updated)
    }

    /// Keep the resized zone and return to the zone that was being drawn
    private func finishEditing(in size: CGSize) {
        commitEditing(in: size)
        let savedDraft = draftFrame
        withAnimation(editAnimation) {
            editingZoneID = nil
            if let savedDraft {
                currentZoneFrame = savedDraft
            }
            draftFrame = nil
        }
    }

    /// Remove the zone being resized and return to the zone that was being drawn
    private func deleteEditingZone() {
        guard let id = editingZoneID,
              let zone = zones.first(where: { $0.id == id }) else { return }
        let savedDraft = draftFrame
        withAnimation(editAnimation) {
            editingZoneID = nil
            if let savedDraft {
                currentZoneFrame = savedDraft
            }
            draftFrame = nil
            onZoneDeleted(zone)
        }
    }

    private func createZone(from frame: CGRect, in size: CGSize) {
        let zone = Zone(
            relativeFrame: relativeFrame(from: frame, in: size),
            fillOrder: zones.count
        )
        
        onZoneCreated(zone)
    }

    private func relativeFrame(from frame: CGRect, in size: CGSize) -> CGRect {
        Self.relativeFrame(from: frame, in: size)
    }
    
    /// Convert a SwiftUI frame (top-left origin) to the stored relative frame (AppKit, bottom-left),
    /// cut to the editor so a zone never reaches past the visible area
    nonisolated static func relativeFrame(from frame: CGRect, in size: CGSize) -> CGRect {
        let frame = ResizableZoneWindow.clamped(frame, to: size)
        let relativeX = frame.origin.x / size.width
        let relativeY = frame.origin.y / size.height
        let relativeWidth = frame.width / size.width
        let relativeHeight = frame.height / size.height
        let flippedY = 1.0 - relativeY - relativeHeight

        return CGRect(
            x: relativeX,
            y: flippedY,
            width: relativeWidth,
            height: relativeHeight
        )
    }
    
    private func absoluteFrame(for relativeFrame: CGRect, in size: CGSize) -> CGRect {
        let flippedY = 1.0 - relativeFrame.origin.y - relativeFrame.height
        return CGRect(
            x: relativeFrame.origin.x * size.width,
            y: flippedY * size.height,
            width: relativeFrame.width * size.width,
            height: relativeFrame.height * size.height
        )
    }
}

struct ResizableZoneWindow: View {
    @Binding var frame: CGRect
    let minSize: CGFloat
    let containerSize: CGSize
    /// True while an already placed zone is being resized
    var isEditing: Bool = false
    /// Badge number of the zone being resized
    var zoneNumber: Int? = nil
    /// Shows a brief prompt inside the frame before the first zone has been placed
    var showsFirstZonePrompt: Bool = false
    let onConfirm: () -> Void
    /// Deletes the zone being resized. Absent while drawing a new zone.
    var onDelete: (() -> Void)? = nil
    
    @State private var dragStartFrame: CGRect? = nil
    
    @State private var isHoveringAdd = false
    
    /// Drives the pulsing border glow
    @State private var pulseAnimation = false
    
    enum Edge { case top, bottom, left, right }
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
    
    var body: some View {
        ZStack {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(ZoneDesign.activeGradient.opacity(0.25))
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial)
                    )
                
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        ZoneDesign.activeBorderGradient,
                        lineWidth: 2.5
                    )
                    .shadow(color: Color(hue: 0.58, saturation: 0.8, brightness: 0.95).opacity(0.5), radius: pulseAnimation ? 12 : 8)
                
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.3), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .padding(1)
                
                ZoneGridPatternView()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .opacity(0.15)
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .gesture(dragGesture)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    pulseAnimation = true
                }
            }
            
            // Add a new zone, or keep the resize of one already placed
            Button(action: onConfirm) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    confirmHue.opacity(isHoveringAdd ? 0.4 : 0.2),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 20,
                                endRadius: 45
                            )
                        )
                        .frame(width: 90, height: 90)
                    
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: isEditing
                                    ? [
                                        Color(hue: 0.35, saturation: 0.7, brightness: 0.9),
                                        Color(hue: 0.38, saturation: 0.65, brightness: 0.72)
                                    ]
                                    : [
                                        Color(hue: 0.58, saturation: 0.7, brightness: 1.0),
                                        Color(hue: 0.62, saturation: 0.8, brightness: 0.85)
                                    ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 56, height: 56)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.5), lineWidth: 2)
                        )
                        .shadow(color: confirmHue.opacity(0.6), radius: isHoveringAdd ? 15 : 10, y: 3)
                    
                    Image(systemName: isEditing ? "checkmark" : "plus")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white)
                }
                .scaleEffect(isHoveringAdd ? 1.08 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHoveringAdd)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isEditing ? "Done resizing" : "Add zone")
            .help(isEditing ? "Keep this size" : "Add zone")
            .position(x: frame.midX, y: frame.midY)
            .onHover { hovering in
                isHoveringAdd = hovering
            }

            if isEditing, let zoneNumber {
                Text("Zone \(zoneNumber)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.45))
                    )
                    .position(x: frame.midX, y: frame.minY + 28)
            } else if showsFirstZonePrompt, frame.width >= 210, frame.height >= 170 {
                Text("Click + to place Zone 1")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.55))
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                            )
                    )
                    .position(x: frame.midX, y: frame.minY + 26)
            }
            
            VStack(spacing: 2) {
                Text("\(Int(frame.width)) × \(Int(frame.height))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.5))
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                            )
                    )
            }
            .position(x: frame.midX, y: frame.maxY - 20)
            
            cornerHandle(at: .topLeft)
            cornerHandle(at: .topRight)
            cornerHandle(at: .bottomLeft)
            cornerHandle(at: .bottomRight)
            
            edgeHandle(at: .top)
            edgeHandle(at: .bottom)
            edgeHandle(at: .left)
            edgeHandle(at: .right)

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.red.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete zone")
                .help("Delete zone")
                .position(x: frame.maxX - 28, y: frame.minY + 28)
            }
        }
    }

    /// Green while keeping a resize, blue while adding a zone
    private var confirmHue: Color {
        isEditing
            ? Color(hue: 0.35, saturation: 0.7, brightness: 0.85)
            : Color(hue: 0.58, saturation: 0.8, brightness: 0.95)
    }
    
    // MARK: - Drag Gesture for Moving
    
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStartFrame == nil {
                    dragStartFrame = frame
                }
                
                guard let startFrame = dragStartFrame else { return }
                
                let newX = startFrame.origin.x + value.translation.width
                let newY = startFrame.origin.y + value.translation.height
                
                let clampedX = max(0, min(newX, containerSize.width - frame.width))
                let clampedY = max(0, min(newY, containerSize.height - frame.height))
                
                frame.origin = CGPoint(x: clampedX, y: clampedY)
            }
            .onEnded { _ in
                dragStartFrame = nil
            }
    }
    
    // MARK: - Corner Resize Handles (Diamond Style)
    
    @ViewBuilder
    private func cornerHandle(at corner: Corner) -> some View {
        let position = cornerPosition(corner)
        
        ZStack {
            Circle()
                .fill(Color(hue: 0.58, saturation: 0.8, brightness: 0.95).opacity(0.3))
                .frame(width: ZoneDesign.handleSize + 8, height: ZoneDesign.handleSize + 8)
                .blur(radius: 4)
            
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(hue: 0.58, saturation: 0.2, brightness: 0.95)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: ZoneDesign.handleSize, height: ZoneDesign.handleSize)
                .rotationEffect(.degrees(45))
                .shadow(color: Color.black.opacity(0.3), radius: 3, y: 2)
        }
        .position(position)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if dragStartFrame == nil {
                        dragStartFrame = frame
                    }
                    guard let startFrame = dragStartFrame else { return }
                    resizeFromCorner(corner, startFrame: startFrame, translation: value.translation)
                }
                .onEnded { _ in
                    dragStartFrame = nil
                }
        )
    }
    
    private func cornerPosition(_ corner: Corner) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: frame.minX, y: frame.minY)
        case .topRight: return CGPoint(x: frame.maxX, y: frame.minY)
        case .bottomLeft: return CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomRight: return CGPoint(x: frame.maxX, y: frame.maxY)
        }
    }
    
    private func resizeFromCorner(_ corner: Corner, startFrame: CGRect, translation: CGSize) {
        var newFrame = startFrame
        
        switch corner {
        case .topLeft:
            newFrame.origin.x = startFrame.origin.x + translation.width
            newFrame.origin.y = startFrame.origin.y + translation.height
            newFrame.size.width = startFrame.width - translation.width
            newFrame.size.height = startFrame.height - translation.height
        case .topRight:
            newFrame.origin.y = startFrame.origin.y + translation.height
            newFrame.size.width = startFrame.width + translation.width
            newFrame.size.height = startFrame.height - translation.height
        case .bottomLeft:
            newFrame.origin.x = startFrame.origin.x + translation.width
            newFrame.size.width = startFrame.width - translation.width
            newFrame.size.height = startFrame.height + translation.height
        case .bottomRight:
            newFrame.size.width = startFrame.width + translation.width
            newFrame.size.height = startFrame.height + translation.height
        }
        newFrame = Self.clamped(newFrame, to: containerSize)
        
        if newFrame.width >= minSize && newFrame.height >= minSize {
            frame = newFrame
        }
    }
    
    /// The part of a zone inside the editor: a handle dragged past an edge stops at that edge
    nonisolated static func clamped(_ frame: CGRect, to containerSize: CGSize) -> CGRect {
        // A handle dragged past the opposite edge: left as is, the minimum size check refuses it
        guard frame.width > 0, frame.height > 0 else { return frame }
        let clipped = frame.intersection(CGRect(origin: .zero, size: containerSize))
        return clipped.isNull ? .zero : clipped
    }
    
    // MARK: - Edge Resize Handles (Sleek Bars)
    
    @ViewBuilder
    private func edgeHandle(at edge: Edge) -> some View {
        let position = edgePosition(edge)
        let size = edgeHandleSize(edge)
        let isVertical = edge == .left || edge == .right
        
        ZStack {
            Capsule()
                .fill(Color(hue: 0.58, saturation: 0.8, brightness: 0.95).opacity(0.3))
                .frame(width: size.width + 4, height: size.height + 4)
                .blur(radius: 3)
            
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.white, Color(hue: 0.58, saturation: 0.15, brightness: 0.92)],
                        startPoint: isVertical ? .top : .leading,
                        endPoint: isVertical ? .bottom : .trailing
                    )
                )
                .frame(width: size.width, height: size.height)
                .shadow(color: Color.black.opacity(0.25), radius: 2, y: 1)
        }
        .position(position)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if dragStartFrame == nil {
                        dragStartFrame = frame
                    }
                    guard let startFrame = dragStartFrame else { return }
                    resizeFromEdge(edge, startFrame: startFrame, translation: value.translation)
                }
                .onEnded { _ in
                    dragStartFrame = nil
                }
        )
    }
    
    private func edgePosition(_ edge: Edge) -> CGPoint {
        switch edge {
        case .top: return CGPoint(x: frame.midX, y: frame.minY)
        case .bottom: return CGPoint(x: frame.midX, y: frame.maxY)
        case .left: return CGPoint(x: frame.minX, y: frame.midY)
        case .right: return CGPoint(x: frame.maxX, y: frame.midY)
        }
    }
    
    private func edgeHandleSize(_ edge: Edge) -> CGSize {
        switch edge {
        case .top, .bottom: return CGSize(width: ZoneDesign.edgeHandleLength, height: 8)
        case .left, .right: return CGSize(width: 8, height: ZoneDesign.edgeHandleLength)
        }
    }
    
    private func resizeFromEdge(_ edge: Edge, startFrame: CGRect, translation: CGSize) {
        var newFrame = startFrame
        
        switch edge {
        case .top:
            newFrame.origin.y = startFrame.origin.y + translation.height
            newFrame.size.height = startFrame.height - translation.height
        case .bottom:
            newFrame.size.height = startFrame.height + translation.height
        case .left:
            newFrame.origin.x = startFrame.origin.x + translation.width
            newFrame.size.width = startFrame.width - translation.width
        case .right:
            newFrame.size.width = startFrame.width + translation.width
        }
        newFrame = Self.clamped(newFrame, to: containerSize)
        
        if newFrame.width >= minSize && newFrame.height >= minSize {
            frame = newFrame
        }
    }
}

private struct ZoneGridPatternView: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 20
            let lineWidth: CGFloat = 0.5
            
            var x: CGFloat = spacing
            while x < size.width {
                let path = Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }
                context.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: lineWidth)
                x += spacing
            }
            
            var y: CGFloat = spacing
            while y < size.height {
                let path = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: lineWidth)
                y += spacing
            }
        }
    }
}

struct ExistingZoneView: View {
    let frame: CGRect
    let index: Int
    let totalZones: Int
    
    @State private var isHovered = false
    @State private var appeared = false
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(ZoneDesign.zoneGradient(for: index).opacity(0.35))
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.ultraThinMaterial.opacity(0.5))
                )
            
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    ZoneDesign.zoneGradient(for: index),
                    lineWidth: 2.5
                )
            
            if isHovered {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.1))
            }
            
            VStack {
                HStack {
                    ZStack {
                        Circle()
                            .fill(ZoneDesign.zoneGradient(for: index))
                            .frame(width: 32, height: 32)
                            .shadow(color: Color.black.opacity(0.3), radius: 4, y: 2)
                        
                        Circle()
                            .strokeBorder(Color.white.opacity(0.5), lineWidth: 1.5)
                            .frame(width: 32, height: 32)
                        
                        Text("\(index + 1)")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(10)
                    
                    Spacer()
                }
                Spacer()
            }
            
            // Click resizes, double-click deletes
            if isHovered {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Click to resize")
                            Text("Double-click to delete")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.55))
                        )
                        .padding(8)
                    }
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .scaleEffect(appeared ? 1.0 : 0.8)
        .opacity(appeared ? 1.0 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                appeared = true
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help("Click to resize, double-click to delete")
        .accessibilityLabel("Zone \(index + 1)")
        .accessibilityHint("Click to resize, double-click to delete")
    }
}

/// Toolbar for custom grid creation mode. Unused: the toolbar on screen is built in OverlayView
struct ZoneCreatorToolbar: View {
    let zoneCount: Int
    let onSave: () -> Void
    let onCancel: () -> Void
    let onClear: () -> Void
    
    @State private var templateName: String = ""
    @FocusState private var isNameFieldFocused: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            TextField("Template Name", text: $templateName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .focused($isNameFieldFocused)
            
            Text("\(zoneCount) zone\(zoneCount == 1 ? "" : "s")")
                .foregroundColor(.secondary)
            
            Spacer()
            
            Button(action: onClear) {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(zoneCount == 0)
            
            Button("Cancel", action: onCancel)
                .buttonStyle(.borderless)
            
            Button("Save", action: {
                onSave()
            })
            .buttonStyle(.borderedProminent)
            .disabled(zoneCount == 0 || templateName.isEmpty)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            isNameFieldFocused = true
        }
    }
    
}

// MARK: - Preview

#if DEBUG
struct ZoneCreatorView_Previews: PreviewProvider {
    struct PreviewWrapper: View {
        @State private var zones: [Zone] = []
        
        var body: some View {
            ZStack {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.9),
                        Color(hue: 0.65, saturation: 0.3, brightness: 0.12).opacity(0.9)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                ZoneCreatorView(
                    screenSize: CGSize(width: 800, height: 600),
                    zones: $zones,
                    onZoneCreated: { zone in
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                            zones.append(zone)
                        }
                    },
                    onZoneUpdated: { zone in
                        if let index = zones.firstIndex(where: { $0.id == zone.id }) {
                            zones[index] = zone
                        }
                    },
                    onZoneDeleted: { zone in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            zones.removeAll { $0.id == zone.id }
                        }
                    }
                )
            }
            .frame(width: 800, height: 600)
        }
    }
    
    static var previews: some View {
        PreviewWrapper()
    }
}
#endif
