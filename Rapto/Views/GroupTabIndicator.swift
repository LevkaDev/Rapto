//
//  GroupTabIndicator.swift
//  Rapto
//
//  Visual indicator for window groups - shows app name, window count, and active window indicator.
//

import SwiftUI
import AppKit

struct GroupTabIndicator: View {
    let slot: Slot
    @ObservedObject var appState: AppState
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 8) {
            if let icon = getAppIcon() {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(applicationName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                
                Text("\(slot.windows.count) windows")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            // Active window indicator (dots) - first window is always active
            HStack(spacing: 4) {
                ForEach(0..<slot.windows.count, id: \.self) { index in
                    Circle()
                        .fill(index == 0 ? Color.white : Color.white.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.leading, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.white.opacity(0.25) : Color.black.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.3), lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    private var applicationName: String {
        slot.originalOwnerName ?? slot.windows.first?.ownerName ?? "Unknown"
    }
    
    private func getAppIcon() -> NSImage? {
        guard let window = slot.windows.first else { return nil }
        guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else {
            return nil
        }
        return app.icon
    }
}

/// Row of group tab indicators under the zone preview of the overlay: the groups of the screen the overlay is on
struct GroupTabIndicatorsView: View {
    @ObservedObject var appState: AppState
    
    /// Slots with more than one window on the overlay's screen
    static func groupSlots(in appState: AppState) -> [Slot] {
        let screenID = appState.screenManager.identifier(for: appState.screenManager.activeScreen())
        return appState.layoutManager.state(forScreenID: screenID).slots.filter { $0.windows.count > 1 }
    }
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.groupSlots(in: appState), id: \.id) { slot in
                GroupTabIndicator(slot: slot, appState: appState)
            }
        }
    }
}
