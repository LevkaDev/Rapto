//
//  ZoneIndicator.swift
//  Rapto
//
//  Visual indicator showing zone assignment progress.
//

import SwiftUI

/// Visual indicator showing which zone is being filled next and overall progress
struct ZoneIndicator: View {
    let template: GridTemplate
    
    let currentIndex: Int
    
    let assignedCount: Int
    
    private let previewWidth: CGFloat = 120
    private let previewHeight: CGFloat = 75
    
    var body: some View {
        HStack(spacing: 20) {
            zonePreview
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Filling Zone \(currentIndex + 1)")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text("\(assignedCount) of \(template.zones.count) zones filled")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ProgressView(value: Double(assignedCount), total: Double(template.zones.count))
                    .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                    .frame(width: 150)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.3))
        )
    }
    
    // MARK: - Zone Preview
    
    private var zonePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.3))
                .frame(width: previewWidth, height: previewHeight)
            
            GeometryReader { geo in
                ForEach(Array(template.zones.enumerated()), id: \.element.id) { index, zone in
                    let isCurrentZone = zone.fillOrder == currentIndex
                    let isFilled = zone.fillOrder < currentIndex
                    
                    // Flip Y coordinate: AppKit uses bottom-left origin, SwiftUI uses top-left
                    let flippedY = 1.0 - zone.relativeFrame.origin.y - zone.relativeFrame.height
                    let flippedMidY = flippedY + zone.relativeFrame.height / 2
                    
                    RoundedRectangle(cornerRadius: 3)
                        .fill(zoneColor(isCurrentZone: isCurrentZone, isFilled: isFilled))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(
                                    isCurrentZone ? Color.accentColor : Color.white.opacity(0.5),
                                    lineWidth: isCurrentZone ? 2 : 1
                                )
                        )
                        .frame(
                            width: zone.relativeFrame.width * geo.size.width - 4,
                            height: zone.relativeFrame.height * geo.size.height - 4
                        )
                        .position(
                            x: zone.relativeFrame.midX * geo.size.width,
                            y: flippedMidY * geo.size.height
                        )
                        .overlay(
                            Text("\(zone.fillOrder + 1)")
                                .font(.caption2.bold())
                                .foregroundColor(isCurrentZone ? .white : .white.opacity(0.7))
                                .position(
                                    x: zone.relativeFrame.midX * geo.size.width,
                                    y: flippedMidY * geo.size.height
                                )
                        )
                }
            }
            .frame(width: previewWidth - 8, height: previewHeight - 8)
        }
    }
    
    private func zoneColor(isCurrentZone: Bool, isFilled: Bool) -> Color {
        if isCurrentZone {
            return Color.accentColor.opacity(0.4)
        } else if isFilled {
            return Color.green.opacity(0.3)
        } else {
            return Color.clear
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ZoneIndicator_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            ZoneIndicator(
                template: PredefinedTemplates.quarters,
                currentIndex: 0,
                assignedCount: 0
            )
            
            ZoneIndicator(
                template: PredefinedTemplates.quarters,
                currentIndex: 1,
                assignedCount: 1
            )
            
            ZoneIndicator(
                template: PredefinedTemplates.quarters,
                currentIndex: 2,
                assignedCount: 2
            )
            
            ZoneIndicator(
                template: PredefinedTemplates.halvesVertical,
                currentIndex: 1,
                assignedCount: 1
            )
        }
        .padding()
        .background(Color.black.opacity(0.8))
    }
}
#endif
