//
//  GridTemplatePreview.swift
//  Rapto
//
//  Visual preview of a grid template showing zone layout.
//

import SwiftUI

struct GridTemplatePreview: View {
    let template: GridTemplate
    
    let isSelected: Bool
    
    private let previewWidth: CGFloat = 100
    private let previewHeight: CGFloat = 62
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: isSelected 
                                ? [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0.15)]
                                : [Color.white.opacity(0.15), Color.white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: previewWidth, height: previewHeight)
                
                GeometryReader { geo in
                    ForEach(template.zones) { zone in
                        // Flip Y coordinate: AppKit uses bottom-left origin, SwiftUI uses top-left
                        let flippedY = 1.0 - zone.relativeFrame.origin.y - zone.relativeFrame.height
                        let flippedMidY = flippedY + zone.relativeFrame.height / 2
                        
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.white.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(
                                        isSelected ? Color.accentColor : Color.white.opacity(0.6),
                                        lineWidth: isSelected ? 1.5 : 1
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
                    }
                }
                .frame(width: previewWidth - 8, height: previewHeight - 8)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor : (isHovered ? Color.white.opacity(0.3) : Color.clear),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : Color.clear, radius: 8, x: 0, y: 2)
            .scaleEffect(isHovered && !isSelected ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .animation(.easeOut(duration: 0.15), value: isSelected)
            
            Text(template.name)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : .white.opacity(0.8))
                .lineLimit(1)
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Preview

#if DEBUG
struct GridTemplatePreview_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 16) {
            GridTemplatePreview(template: PredefinedTemplates.halvesVertical, isSelected: false)
            GridTemplatePreview(template: PredefinedTemplates.quarters, isSelected: true)
            GridTemplatePreview(template: PredefinedTemplates.thirdsVertical, isSelected: false)
        }
        .padding()
        .background(Color.black)
    }
}
#endif
