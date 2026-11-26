//
//  DragSnapLayout.swift
//  Rapto
//
//  The layout a Drag to Snap desktop snaps windows into. Kept apart from the Manual layout.
//

import AppKit
import SwiftUI

/// Layout submenu of a Drag to Snap desktop in the menu bar menu
struct DragSnapLayoutMenu: View {
    @ObservedObject var appState: AppState
    let screen: NSScreen

    var body: some View {
        let current = appState.dragSnapTemplate(for: screen)
        let partitioned = appState.partitionedTemplates(for: screen)
        Menu("Layout: \(current?.name ?? DragSnapLayoutName.standard)") {
            Toggle(DragSnapLayoutName.standard, isOn: Binding(
                get: { current == nil },
                set: { _ in appState.setDragSnapTemplate(nil, for: screen) }
            ))
            Divider()
            ForEach(partitioned.primary) { template in
                Toggle(template.name, isOn: Binding(
                    get: { template.id == current?.id },
                    set: { _ in appState.setDragSnapTemplate(template, for: screen) }
                ))
            }
            if !partitioned.ultrawide.isEmpty {
                Divider()
                Menu("Ultrawide") {
                    ForEach(partitioned.ultrawide) { template in
                        Toggle(template.name, isOn: Binding(
                            get: { template.id == current?.id },
                            set: { _ in appState.setDragSnapTemplate(template, for: screen) }
                        ))
                    }
                }
            }
        }
    }
}

enum DragSnapLayoutName {
    /// Menu name of the halves, quarters and thirds used when no layout is chosen
    static let standard = "Standard Zones"
}

extension AppState {
    /// Layout chosen for Drag to Snap on the desktop on this screen; nil means the standard zones
    func dragSnapTemplate(for screen: NSScreen) -> GridTemplate? {
        let screenID = screenManager.identifier(for: screen)
        return dragSnapTemplate(forSpaceKey: spaceID(for: screen), screenID: screenID)
    }

    func dragSnapTemplate(forSpaceKey spaceKey: String, screenID: String) -> GridTemplate? {
        let config = configuration(forSpaceID: spaceKey, screenID: screenID)
        guard let id = config.dragSnapTemplateID else { return nil }
        return template(withID: id)
    }

    /// Only remembers the layout: in Drag to Snap windows stay where they are until dragged
    func setDragSnapTemplate(_ template: GridTemplate?, forSpaceKey spaceKey: String, screenID: String) {
        var config = configuration(forSpaceID: spaceKey, screenID: screenID)
        config.dragSnapTemplateID = template?.id
        ScreenConfigurationStorage.setConfiguration(config, forSpaceID: spaceKey, screenID: screenID, in: &screenConfigurations)
    }

    func setDragSnapTemplate(_ template: GridTemplate?, for screen: NSScreen) {
        let screenID = screenManager.identifier(for: screen)
        setDragSnapTemplate(template, forSpaceKey: spaceID(for: screen), screenID: screenID)
    }
}
