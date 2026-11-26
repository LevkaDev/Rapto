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

// MARK: - Snapping & Splitting Geometry

nonisolated enum ZoneSnapAxis: Equatable, Sendable {
    case vertical
    case horizontal
}

nonisolated enum ZoneSnapKind: Equatable, Sendable {
    case screenEdge
    case neighbor
    case fraction(String)
}

nonisolated struct ZoneSnapGuide: Equatable, Sendable {
    let axis: ZoneSnapAxis
    /// Position in SwiftUI editor coordinates (points from top-left)
    let position: CGFloat
    let kind: ZoneSnapKind
}

nonisolated enum ZoneSplitAxis: Equatable, Sendable {
    /// Splits left and right (side by side)
    case vertical
    /// Splits top and bottom (stacked)
    case horizontal
}

nonisolated enum ZoneEditorGeometry {
    static let defaultSnapThreshold: CGFloat = 12

    private static let guideFractions: [(value: CGFloat, label: String)] = [
        (1.0 / 4.0, "1/4"),
        (1.0 / 3.0, "1/3"),
        (1.0 / 2.0, "1/2"),
        (2.0 / 3.0, "2/3"),
        (3.0 / 4.0, "3/4"),
    ]

    private struct SnapCandidate {
        let position: CGFloat
        let kind: ZoneSnapKind
        /// Lower priority wins ties at the same distance (edges and neighbors beat screen fractions)
        let priority: Int
    }

    private static func candidates(
        axis: ZoneSnapAxis,
        containerSize: CGSize,
        otherFrames: [CGRect],
        includeCenters: Bool
    ) -> [SnapCandidate] {
        let span = axis == .vertical ? containerSize.width : containerSize.height
        var result: [SnapCandidate] = [
            SnapCandidate(position: 0, kind: .screenEdge, priority: 0),
            SnapCandidate(position: span, kind: .screenEdge, priority: 0),
        ]
        for frame in otherFrames {
            if axis == .vertical {
                result.append(SnapCandidate(position: frame.minX, kind: .neighbor, priority: 1))
                result.append(SnapCandidate(position: frame.maxX, kind: .neighbor, priority: 1))
                if includeCenters {
                    result.append(SnapCandidate(position: frame.midX, kind: .neighbor, priority: 2))
                }
            } else {
                result.append(SnapCandidate(position: frame.minY, kind: .neighbor, priority: 1))
                result.append(SnapCandidate(position: frame.maxY, kind: .neighbor, priority: 1))
                if includeCenters {
                    result.append(SnapCandidate(position: frame.midY, kind: .neighbor, priority: 2))
                }
            }
        }
        for fraction in guideFractions {
            result.append(SnapCandidate(position: span * fraction.value, kind: .fraction(fraction.label), priority: 2))
        }
        return result
    }

    private static func bestDelta(
        anchors: [CGFloat],
        candidates: [SnapCandidate],
        threshold: CGFloat
    ) -> (delta: CGFloat, candidate: SnapCandidate)? {
        var best: (distance: CGFloat, delta: CGFloat, candidate: SnapCandidate)?
        for anchor in anchors {
            for candidate in candidates {
                let delta = candidate.position - anchor
                let distance = abs(delta)
                guard distance <= threshold else { continue }
                if let current = best {
                    let closer = distance < current.distance - 0.01
                    let sameDistanceBetterPriority = abs(distance - current.distance) <= 0.01
                        && candidate.priority < current.candidate.priority
                    if closer || sameDistanceBetterPriority {
                        best = (distance, delta, candidate)
                    }
                } else {
                    best = (distance, delta, candidate)
                }
            }
        }
        return best.map { ($0.delta, $0.candidate) }
    }

    /// Snaps a moved zone to screen edges, neighbor zone edges, and 1/4, 1/3, 1/2 guides.
    static func snapMovedFrame(
        _ frame: CGRect,
        containerSize: CGSize,
        otherFrames: [CGRect],
        threshold: CGFloat = defaultSnapThreshold,
        enabled: Bool = true
    ) -> (frame: CGRect, guides: [ZoneSnapGuide]) {
        var snapped = frame
        snapped.origin.x = max(0, min(snapped.origin.x, containerSize.width - snapped.width))
        snapped.origin.y = max(0, min(snapped.origin.y, containerSize.height - snapped.height))
        guard enabled else { return (snapped, []) }

        var guides: [ZoneSnapGuide] = []

        let xCandidates = candidates(axis: .vertical, containerSize: containerSize, otherFrames: otherFrames, includeCenters: true)
        if let match = bestDelta(anchors: [snapped.minX, snapped.maxX, snapped.midX], candidates: xCandidates, threshold: threshold) {
            let proposedX = snapped.origin.x + match.delta
            if proposedX >= -0.01 && proposedX + snapped.width <= containerSize.width + 0.01 {
                snapped.origin.x = max(0, min(proposedX, containerSize.width - snapped.width))
                guides.append(ZoneSnapGuide(axis: .vertical, position: match.candidate.position, kind: match.candidate.kind))
            }
        }

        let yCandidates = candidates(axis: .horizontal, containerSize: containerSize, otherFrames: otherFrames, includeCenters: true)
        if let match = bestDelta(anchors: [snapped.minY, snapped.maxY, snapped.midY], candidates: yCandidates, threshold: threshold) {
            let proposedY = snapped.origin.y + match.delta
            if proposedY >= -0.01 && proposedY + snapped.height <= containerSize.height + 0.01 {
                snapped.origin.y = max(0, min(proposedY, containerSize.height - snapped.height))
                guides.append(ZoneSnapGuide(axis: .horizontal, position: match.candidate.position, kind: match.candidate.kind))
            }
        }

        return (snapped, guides)
    }

    /// Snaps the edges currently being dragged during a resize while keeping opposite edges fixed.
    static func snapResizedFrame(
        _ frame: CGRect,
        edges: Set<ResizableZoneWindow.Edge>,
        minSize: CGFloat,
        containerSize: CGSize,
        otherFrames: [CGRect],
        threshold: CGFloat = defaultSnapThreshold,
        enabled: Bool = true
    ) -> (frame: CGRect, guides: [ZoneSnapGuide]) {
        var snapped = ResizableZoneWindow.clamped(frame, to: containerSize)
        guard enabled, snapped.width >= minSize, snapped.height >= minSize else {
            return (snapped, [])
        }

        var guides: [ZoneSnapGuide] = []

        let xCandidates = candidates(axis: .vertical, containerSize: containerSize, otherFrames: otherFrames, includeCenters: false)
        if edges.contains(.left),
           let match = bestDelta(anchors: [snapped.minX], candidates: xCandidates, threshold: threshold) {
            let newMinX = match.candidate.position
            let newWidth = snapped.maxX - newMinX
            if newMinX >= 0 && newWidth >= minSize {
                snapped.origin.x = newMinX
                snapped.size.width = newWidth
                guides.append(ZoneSnapGuide(axis: .vertical, position: newMinX, kind: match.candidate.kind))
            }
        } else if edges.contains(.right),
                  let match = bestDelta(anchors: [snapped.maxX], candidates: xCandidates, threshold: threshold) {
            let newMaxX = match.candidate.position
            let newWidth = newMaxX - snapped.minX
            if newMaxX <= containerSize.width && newWidth >= minSize {
                snapped.size.width = newWidth
                guides.append(ZoneSnapGuide(axis: .vertical, position: newMaxX, kind: match.candidate.kind))
            }
        }

        let yCandidates = candidates(axis: .horizontal, containerSize: containerSize, otherFrames: otherFrames, includeCenters: false)
        if edges.contains(.top),
           let match = bestDelta(anchors: [snapped.minY], candidates: yCandidates, threshold: threshold) {
            let newMinY = match.candidate.position
            let newHeight = snapped.maxY - newMinY
            if newMinY >= 0 && newHeight >= minSize {
                snapped.origin.y = newMinY
                snapped.size.height = newHeight
                guides.append(ZoneSnapGuide(axis: .horizontal, position: newMinY, kind: match.candidate.kind))
            }
        } else if edges.contains(.bottom),
                  let match = bestDelta(anchors: [snapped.maxY], candidates: yCandidates, threshold: threshold) {
            let newMaxY = match.candidate.position
            let newHeight = newMaxY - snapped.minY
            if newMaxY <= containerSize.height && newHeight >= minSize {
                snapped.size.height = newHeight
                guides.append(ZoneSnapGuide(axis: .horizontal, position: newMaxY, kind: match.candidate.kind))
            }
        }

        return (snapped, guides)
    }

    /// Splits a SwiftUI editor frame into two equal adjacent frames, or nil if either half would
    /// be smaller than `minSize`. Left comes before right; top comes before bottom.
    static func split(
        _ frame: CGRect,
        axis: ZoneSplitAxis,
        minSize: CGFloat
    ) -> (first: CGRect, second: CGRect)? {
        switch axis {
        case .vertical:
            let halfWidth = frame.width / 2
            guard halfWidth >= minSize else { return nil }
            let left = CGRect(x: frame.minX, y: frame.minY, width: halfWidth, height: frame.height)
            let right = CGRect(x: frame.minX + halfWidth, y: frame.minY, width: frame.width - halfWidth, height: frame.height)
            return (left, right)
        case .horizontal:
            let halfHeight = frame.height / 2
            guard halfHeight >= minSize else { return nil }
            let top = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: halfHeight)
            let bottom = CGRect(x: frame.minX, y: frame.minY + halfHeight, width: frame.width, height: frame.height - halfHeight)
            return (top, bottom)
        }
    }

    /// Splits a draft frame into a first half to place immediately and a second half for the live draft.
    static func splitDraft(
        currentFrame: CGRect,
        axis: ZoneSplitAxis,
        minSize: CGFloat
    ) -> (placed: CGRect, nextDraft: CGRect)? {
        guard let halves = split(currentFrame, axis: axis, minSize: minSize) else { return nil }
        return (placed: halves.first, nextDraft: halves.second)
    }

    /// Vertical center for the zone's control cluster (+/checkmark, split, delete) so it stays
    /// visible below the top toolbar and above the bottom instruction bar whenever the zone has room.
    static func controlsCenterY(
        for frame: CGRect,
        containerSize: CGSize,
        topOverlayClearance: CGFloat = 114,
        bottomOverlayClearance: CGFloat = 114,
        minTopInset: CGFloat = 34,
        minBottomInset: CGFloat = 46
    ) -> CGFloat {
        let minY = frame.minY + minTopInset
        let maxY = frame.maxY - minBottomInset
        guard minY <= maxY else { return frame.midY }

        let safeTop = topOverlayClearance
        let safeBottom = max(safeTop, containerSize.height - bottomOverlayClearance)

        if frame.midY < safeTop, maxY > frame.midY {
            return min(safeTop, maxY)
        }
        if frame.midY > safeBottom, minY < frame.midY {
            return max(safeBottom, minY)
        }
        return min(max(frame.midY, minY), maxY)
    }

    /// Creates a draft rect centered around `point` and clamped inside `containerSize`.
    static func draftFrame(
        centeredAt point: CGPoint,
        size: CGSize = CGSize(width: 300, height: 200),
        in containerSize: CGSize
    ) -> CGRect {
        let width = min(size.width, containerSize.width)
        let height = min(size.height, containerSize.height)
        let maxX = max(0, containerSize.width - width)
        let maxY = max(0, containerSize.height - height)
        let x = min(max(0, point.x - width / 2), maxX)
        let y = min(max(0, point.y - height / 2), maxY)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Picks a starting frame for a new draft zone, preferring an open area away from existing zones.
    static func defaultDraftFrame(
        in containerSize: CGSize,
        existingFrames: [CGRect],
        preferredSize: CGSize = CGSize(width: 300, height: 200)
    ) -> CGRect {
        let candidates: [(CGFloat, CGFloat)] = [
            (0.5, 0.5),
            (0.75, 0.5),
            (0.25, 0.5),
            (0.5, 0.72),
            (0.5, 0.28),
            (0.75, 0.72),
            (0.25, 0.72),
            (0.75, 0.28),
            (0.25, 0.28),
        ]

        var bestFrame = draftFrame(
            centeredAt: CGPoint(x: containerSize.width / 2, y: containerSize.height / 2),
            size: preferredSize,
            in: containerSize
        )
        if existingFrames.isEmpty {
            return bestFrame
        }

        var bestOverlap = CGFloat.greatestFiniteMagnitude
        for (fx, fy) in candidates {
            let candidate = draftFrame(
                centeredAt: CGPoint(x: containerSize.width * fx, y: containerSize.height * fy),
                size: preferredSize,
                in: containerSize
            )
            let overlap = existingFrames.reduce(CGFloat(0)) { total, other in
                let rect = candidate.intersection(other)
                guard !rect.isNull, rect.width > 0, rect.height > 0 else { return total }
                return total + rect.width * rect.height
            }
            if overlap < bestOverlap {
                bestOverlap = overlap
                bestFrame = candidate
                if overlap == 0 {
                    break
                }
            }
        }
        return bestFrame
    }
}

struct ZoneCreatorView: View {
    /// Screen size (width x height) to calculate relative frames
    /// This should be the visible screen area size, NOT including origin
    let screenSize: CGSize
    
    /// Currently created zones (relative frames)
    @Binding var zones: [Zone]

    /// Whether a new draft zone is currently active on the canvas
    @Binding var isShowingDraft: Bool

    /// False in single-zone editors (such as Focus Mode zone selection)
    var allowsSplitting: Bool = true
    
    let onZoneCreated: (Zone) -> Void

    let onZoneUpdated: (Zone) -> Void
    
    let onZoneDeleted: (Zone) -> Void

    var onZoneSplit: ((Zone, Zone, Zone) -> Void)? = nil
    
    @State private var currentZoneFrame: CGRect = CGRect(x: 100, y: 100, width: 300, height: 200)

    /// Zone being resized again. Nil while drawing a new zone or idle.
    @State private var editingZoneID: UUID?

    /// Frame of the draft zone, kept while an earlier zone is being edited
    @State private var draftFrame: CGRect?

    /// Set when a canvas click spawned the draft at a specific point so onChange doesn't recenter it
    @State private var didPositionDraftFromTap = false

    /// Single click waits briefly so a double-click can still delete the zone
    @State private var pendingEdit: DispatchWorkItem?

    /// Active magnetic alignment guides shown while dragging or resizing a zone
    @State private var activeSnapGuides: [ZoneSnapGuide] = []
    
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
            let existingFrames = zones.map { absoluteFrame(for: $0.relativeFrame, in: normalizationSize) }
            
            ZStack {
                // Transparent, hit-testable background: click empty space to finish editing or start a new zone
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        if editingZoneID != nil {
                            finishEditing(in: normalizationSize)
                        } else if !isShowingDraft && (allowsSplitting || zones.isEmpty) {
                            withAnimation(editAnimation) {
                                currentZoneFrame = ZoneEditorGeometry.draftFrame(
                                    centeredAt: location,
                                    in: normalizationSize
                                )
                                didPositionDraftFromTap = true
                                isShowingDraft = true
                            }
                        }
                    }
                
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
                
                if editingZoneID != nil || isShowingDraft {
                    let otherFrames = zones
                        .filter { $0.id != editingZoneID }
                        .map { absoluteFrame(for: $0.relativeFrame, in: normalizationSize) }

                    ResizableZoneWindow(
                        frame: $currentZoneFrame,
                        minSize: minSize,
                        containerSize: normalizationSize,
                        otherZoneFrames: otherFrames,
                        activeGuides: $activeSnapGuides,
                        isEditing: editingZoneID != nil,
                        zoneNumber: editingZoneNumber,
                        showsFirstZonePrompt: zones.isEmpty,
                        onConfirm: {
                            if editingZoneID != nil {
                                finishEditing(in: normalizationSize)
                            } else {
                                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.4, dampingFraction: 0.75)) {
                                    createZone(from: currentZoneFrame, in: normalizationSize)
                                    isShowingDraft = false
                                }
                            }
                        },
                        onSplit: allowsSplitting ? { axis in
                            withAnimation(editAnimation) {
                                splitCurrentZone(along: axis, in: normalizationSize)
                            }
                        } : nil,
                        onDelete: editingZoneID == nil ? nil : {
                            deleteEditingZone()
                        },
                        onDismissDraft: (editingZoneID == nil && !zones.isEmpty) ? {
                            withAnimation(editAnimation) {
                                isShowingDraft = false
                            }
                        } : nil
                    )
                }

                if !activeSnapGuides.isEmpty {
                    SnapGuidesOverlay(guides: activeSnapGuides, size: normalizationSize)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                currentZoneFrame = ZoneEditorGeometry.defaultDraftFrame(
                    in: normalizationSize,
                    existingFrames: existingFrames
                )
                isShowingDraft = zones.isEmpty
            }
            .onChange(of: zones.isEmpty) { _, isEmpty in
                if isEmpty {
                    editingZoneID = nil
                    draftFrame = nil
                    currentZoneFrame = ZoneEditorGeometry.defaultDraftFrame(
                        in: normalizationSize,
                        existingFrames: []
                    )
                    isShowingDraft = true
                }
            }
            .onChange(of: isShowingDraft) { _, showing in
                guard showing else { return }
                if didPositionDraftFromTap {
                    didPositionDraftFromTap = false
                    return
                }
                if editingZoneID != nil {
                    commitEditing(in: normalizationSize)
                    editingZoneID = nil
                    draftFrame = nil
                }
                let latestFrames = zones.map { absoluteFrame(for: $0.relativeFrame, in: normalizationSize) }
                currentZoneFrame = ZoneEditorGeometry.defaultDraftFrame(
                    in: normalizationSize,
                    existingFrames: latestFrames
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
    /// Any open draft zone is remembered and comes back on confirm.
    private func beginEditing(_ zone: Zone, in size: CGSize) {
        guard zones.contains(where: { $0.id == zone.id }) else { return }
        guard zone.id != editingZoneID else { return }
        if editingZoneID != nil {
            commitEditing(in: size)
        } else {
            draftFrame = isShowingDraft ? currentZoneFrame : nil
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

    /// Keep the resized zone and restore any draft that was open before editing
    private func finishEditing(in size: CGSize) {
        commitEditing(in: size)
        let savedDraft = draftFrame
        withAnimation(editAnimation) {
            editingZoneID = nil
            if let savedDraft {
                currentZoneFrame = savedDraft
            } else {
                isShowingDraft = false
            }
            draftFrame = nil
        }
    }

    /// Remove the zone being resized and restore any draft that was open before editing
    private func deleteEditingZone() {
        guard let id = editingZoneID,
              let zone = zones.first(where: { $0.id == id }) else { return }
        let savedDraft = draftFrame
        withAnimation(editAnimation) {
            editingZoneID = nil
            if let savedDraft {
                currentZoneFrame = savedDraft
            } else {
                isShowingDraft = false
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

    /// Splits either the zone being edited into two placed halves, or the draft zone into a placed
    /// first half and a live draft occupying the second half.
    private func splitCurrentZone(along axis: ZoneSplitAxis, in size: CGSize) {
        if let id = editingZoneID,
           let zone = zones.first(where: { $0.id == id }) {
            guard let split = ZoneEditorGeometry.split(currentZoneFrame, axis: axis, minSize: minSize) else { return }
            let first = Zone(
                id: zone.id,
                relativeFrame: relativeFrame(from: split.first, in: size),
                fillOrder: zone.fillOrder
            )
            let second = Zone(
                relativeFrame: relativeFrame(from: split.second, in: size),
                fillOrder: zone.fillOrder + 1
            )
            if let onZoneSplit {
                onZoneSplit(zone, first, second)
            } else {
                onZoneUpdated(first)
                onZoneCreated(second)
            }
            let savedDraft = draftFrame
            editingZoneID = nil
            if let savedDraft {
                currentZoneFrame = savedDraft
            } else {
                isShowingDraft = false
            }
            draftFrame = nil
        } else {
            guard let split = ZoneEditorGeometry.splitDraft(
                currentFrame: currentZoneFrame,
                axis: axis,
                minSize: minSize
            ) else { return }
            let first = Zone(
                relativeFrame: relativeFrame(from: split.placed, in: size),
                fillOrder: zones.count
            )
            onZoneCreated(first)
            currentZoneFrame = split.nextDraft
        }
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
    /// Frames of other placed zones (SwiftUI editor coordinates) used as magnetic snap targets
    var otherZoneFrames: [CGRect] = []
    /// Active snap guides driven during drag/resize gestures
    @Binding var activeGuides: [ZoneSnapGuide]
    /// True while an already placed zone is being resized
    var isEditing: Bool = false
    /// Badge number of the zone being resized
    var zoneNumber: Int? = nil
    /// Shows a brief prompt inside the frame before the first zone has been placed
    var showsFirstZonePrompt: Bool = false
    let onConfirm: () -> Void
    /// Splits this zone into two equal halves (left/right or top/bottom)
    var onSplit: ((ZoneSplitAxis) -> Void)? = nil
    /// Deletes the zone being resized. Absent while drawing a new zone.
    var onDelete: (() -> Void)? = nil
    /// Dismisses an extra draft zone without placing it. Present only once at least one zone exists.
    var onDismissDraft: (() -> Void)? = nil
    
    @State private var dragStartFrame: CGRect? = nil
    
    @State private var isHoveringAdd = false

    /// Split axis currently hovered, used to preview the cut line across the zone
    @State private var hoveredSplitAxis: ZoneSplitAxis? = nil
    
    /// Drives the pulsing border glow
    @State private var pulseAnimation = false
    
    nonisolated enum Edge: Hashable, Sendable { case top, bottom, left, right }
    nonisolated enum Corner: Hashable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }

    private var canSplitVertically: Bool {
        onSplit != nil && frame.width >= minSize * 2
    }

    private var canSplitHorizontally: Bool {
        onSplit != nil && frame.height >= minSize * 2
    }

    private var hasSplitActions: Bool {
        canSplitVertically || canSplitHorizontally
    }

    private var hasSecondaryActions: Bool {
        hasSplitActions || onDelete != nil || onDismissDraft != nil
    }

    private var activeSplitPreview: ZoneSplitAxis? {
        switch hoveredSplitAxis {
        case .vertical where canSplitVertically:
            return .vertical
        case .horizontal where canSplitHorizontally:
            return .horizontal
        default:
            return nil
        }
    }

    private var isSnappingEnabled: Bool {
        !NSEvent.modifierFlags.contains(.option)
    }

    private var stacksActionsBelowConfirm: Bool {
        frame.height >= 190
    }

    private var confirmButtonDiameter: CGFloat {
        frame.height < 130 ? 46 : 56
    }

    private var hasTopStatusBadge: Bool {
        (isEditing && zoneNumber != nil) || (showsFirstZonePrompt && frame.width >= 210 && frame.height >= 200)
    }

    private var controlsCenterY: CGFloat {
        let minTop: CGFloat = stacksActionsBelowConfirm ? (hasTopStatusBadge ? 66 : 54) : 30
        let minBottom: CGFloat = stacksActionsBelowConfirm ? (hasTopStatusBadge ? 94 : 78) : 44
        return ZoneEditorGeometry.controlsCenterY(
            for: frame,
            containerSize: containerSize,
            minTopInset: minTop,
            minBottomInset: minBottom
        )
    }
    
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

            if let previewAxis = activeSplitPreview {
                splitPreviewOverlay(for: previewAxis)
                    .allowsHitTesting(false)
            }
            
            centerControlsCluster
                .position(x: frame.midX, y: controlsCenterY)
            
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
            .allowsHitTesting(false)
            .position(x: frame.midX, y: frame.maxY - 20)
            
            cornerHandle(at: .topLeft)
            cornerHandle(at: .topRight)
            cornerHandle(at: .bottomLeft)
            cornerHandle(at: .bottomRight)
            
            edgeHandle(at: .top)
            edgeHandle(at: .bottom)
            edgeHandle(at: .left)
            edgeHandle(at: .right)
        }
    }

    @ViewBuilder
    private var centerControlsCluster: some View {
        if stacksActionsBelowConfirm {
            VStack(spacing: 8) {
                topStatusBadge
                confirmButton
                if hasSecondaryActions {
                    secondaryActionsRow(showSplitLabel: frame.width >= 150)
                }
            }
        } else {
            HStack(spacing: frame.width < 140 ? 6 : 10) {
                confirmButton
                if hasSecondaryActions {
                    secondaryActionsRow(showSplitLabel: frame.width >= 260)
                }
            }
        }
    }

    @ViewBuilder
    private var topStatusBadge: some View {
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
        } else if showsFirstZonePrompt, frame.width >= 210, frame.height >= 200 {
            Text("Click ✓ to place Zone 1")
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
        }
    }

    // Place a new zone and finish the draft, or keep the resize of one already placed
    private var confirmButton: some View {
        let diameter = confirmButtonDiameter
        let iconSize: CGFloat = diameter < 50 ? 22 : 26
        return Button(action: onConfirm) {
            ZStack {
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
                    .frame(width: diameter, height: diameter)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.5), lineWidth: 2)
                    )
                    .shadow(color: confirmHue.opacity(0.6), radius: isHoveringAdd ? 15 : 10, y: 3)
                
                Image(systemName: "checkmark")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundColor(.white)
            }
            .contentShape(Circle())
            .background(
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
                    .allowsHitTesting(false)
            )
            .scaleEffect(isHoveringAdd ? 1.08 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHoveringAdd)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isEditing ? "Done resizing" : "Place zone")
        .help(isEditing ? "Keep this size" : "Place zone")
        .onHover { hovering in
            isHoveringAdd = hovering
        }
    }

    @ViewBuilder
    private func secondaryActionsRow(showSplitLabel: Bool) -> some View {
        HStack(spacing: 6) {
            if hasSplitActions, let onSplit {
                HStack(spacing: 4) {
                    if showSplitLabel {
                        Text("Split")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.82))
                            .padding(.leading, 6)
                            .padding(.trailing, 2)
                    }

                    if canSplitVertically {
                        splitButton(
                            axis: .vertical,
                            systemImage: "rectangle.split.2x1",
                            accessibilityLabel: "Split zone vertically",
                            helpText: "Split into left and right halves",
                            onSplit: onSplit
                        )
                    }

                    if canSplitHorizontally {
                        splitButton(
                            axis: .horizontal,
                            systemImage: "rectangle.split.1x2",
                            accessibilityLabel: "Split zone horizontally",
                            helpText: "Split into top and bottom halves",
                            onSplit: onSplit
                        )
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.62))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.75)
                        )
                )
            }

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.red.opacity(0.85)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete zone")
                .help("Delete zone")
            } else if let onDismissDraft {
                Button(action: onDismissDraft) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.black.opacity(0.62)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel new zone")
                .help("Close without adding a zone")
            }
        }
    }

    private func splitButton(
        axis: ZoneSplitAxis,
        systemImage: String,
        accessibilityLabel: String,
        helpText: String,
        onSplit: @escaping (ZoneSplitAxis) -> Void
    ) -> some View {
        let isHovered = hoveredSplitAxis == axis
        return Button {
            hoveredSplitAxis = nil
            onSplit(axis)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 24)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(isHovered ? 0.28 : 0.1))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(helpText)
        .onHover { hovering in
            if hovering {
                hoveredSplitAxis = axis
            } else if hoveredSplitAxis == axis {
                hoveredSplitAxis = nil
            }
        }
    }

    @ViewBuilder
    private func splitPreviewOverlay(for axis: ZoneSplitAxis) -> some View {
        ZStack {
            // Subtle highlight on the half that will be placed first
            let highlightWidth = axis == .vertical ? frame.width / 2 : frame.width
            let highlightHeight = axis == .horizontal ? frame.height / 2 : frame.height
            let highlightCenter = axis == .vertical
                ? CGPoint(x: frame.minX + frame.width / 4, y: frame.midY)
                : CGPoint(x: frame.midX, y: frame.minY + frame.height / 4)

            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.08))
                .frame(width: max(0, highlightWidth - 6), height: max(0, highlightHeight - 6))
                .position(highlightCenter)

            Path { path in
                switch axis {
                case .vertical:
                    path.move(to: CGPoint(x: frame.midX, y: frame.minY + 8))
                    path.addLine(to: CGPoint(x: frame.midX, y: frame.maxY - 8))
                case .horizontal:
                    path.move(to: CGPoint(x: frame.minX + 8, y: frame.midY))
                    path.addLine(to: CGPoint(x: frame.maxX - 8, y: frame.midY))
                }
            }
            .stroke(
                Color.white.opacity(0.95),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [7, 5])
            )
            .shadow(color: Color(hue: 0.58, saturation: 0.9, brightness: 1.0).opacity(0.8), radius: 5)
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
                    hoveredSplitAxis = nil
                }
                
                guard let startFrame = dragStartFrame else { return }
                
                let rawFrame = CGRect(
                    x: startFrame.origin.x + value.translation.width,
                    y: startFrame.origin.y + value.translation.height,
                    width: startFrame.width,
                    height: startFrame.height
                )
                let snapped = ZoneEditorGeometry.snapMovedFrame(
                    rawFrame,
                    containerSize: containerSize,
                    otherFrames: otherZoneFrames,
                    enabled: isSnappingEnabled
                )
                frame = snapped.frame
                activeGuides = snapped.guides
            }
            .onEnded { _ in
                dragStartFrame = nil
                activeGuides = []
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
                    activeGuides = []
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
        let activeEdges: Set<Edge>
        
        switch corner {
        case .topLeft:
            newFrame.origin.x = startFrame.origin.x + translation.width
            newFrame.origin.y = startFrame.origin.y + translation.height
            newFrame.size.width = startFrame.width - translation.width
            newFrame.size.height = startFrame.height - translation.height
            activeEdges = [.top, .left]
        case .topRight:
            newFrame.origin.y = startFrame.origin.y + translation.height
            newFrame.size.width = startFrame.width + translation.width
            newFrame.size.height = startFrame.height - translation.height
            activeEdges = [.top, .right]
        case .bottomLeft:
            newFrame.origin.x = startFrame.origin.x + translation.width
            newFrame.size.width = startFrame.width - translation.width
            newFrame.size.height = startFrame.height + translation.height
            activeEdges = [.bottom, .left]
        case .bottomRight:
            newFrame.size.width = startFrame.width + translation.width
            newFrame.size.height = startFrame.height + translation.height
            activeEdges = [.bottom, .right]
        }
        let snapped = ZoneEditorGeometry.snapResizedFrame(
            newFrame,
            edges: activeEdges,
            minSize: minSize,
            containerSize: containerSize,
            otherFrames: otherZoneFrames,
            enabled: isSnappingEnabled
        )
        
        if snapped.frame.width >= minSize && snapped.frame.height >= minSize {
            frame = snapped.frame
            activeGuides = snapped.guides
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
                    activeGuides = []
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
        let snapped = ZoneEditorGeometry.snapResizedFrame(
            newFrame,
            edges: [edge],
            minSize: minSize,
            containerSize: containerSize,
            otherFrames: otherZoneFrames,
            enabled: isSnappingEnabled
        )
        
        if snapped.frame.width >= minSize && snapped.frame.height >= minSize {
            frame = snapped.frame
            activeGuides = snapped.guides
        }
    }
}

private struct SnapGuidesOverlay: View {
    let guides: [ZoneSnapGuide]
    let size: CGSize

    var body: some View {
        ZStack {
            Canvas { context, canvasSize in
                for guide in guides {
                    let isFraction: Bool
                    if case .fraction = guide.kind { isFraction = true } else { isFraction = false }
                    let color: Color = isFraction
                        ? Color(hue: 0.12, saturation: 0.85, brightness: 1.0).opacity(0.9)
                        : Color(hue: 0.56, saturation: 0.85, brightness: 1.0).opacity(0.95)
                    let style = StrokeStyle(lineWidth: 1.25, dash: isFraction ? [6, 4] : [])
                    let path = Path { p in
                        switch guide.axis {
                        case .vertical:
                            let x = max(0.75, min(guide.position, canvasSize.width - 0.75))
                            p.move(to: CGPoint(x: x, y: 0))
                            p.addLine(to: CGPoint(x: x, y: canvasSize.height))
                        case .horizontal:
                            let y = max(0.75, min(guide.position, canvasSize.height - 0.75))
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: canvasSize.width, y: y))
                        }
                    }
                    context.stroke(path, with: .color(color), style: style)
                }
            }

            ForEach(Array(guides.enumerated()), id: \.offset) { _, guide in
                if case .fraction(let label) = guide.kind {
                    Text(label)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.black.opacity(0.88))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color(hue: 0.12, saturation: 0.85, brightness: 1.0).opacity(0.95))
                        )
                        .position(
                            x: guide.axis == .vertical ? max(24, min(guide.position, size.width - 24)) : 28,
                            y: guide.axis == .horizontal ? max(20, min(guide.position, size.height - 20)) : 84
                        )
                }
            }
        }
        .frame(width: size.width, height: size.height)
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
        @State private var isShowingDraft = true
        
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
                    isShowingDraft: $isShowingDraft,
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
