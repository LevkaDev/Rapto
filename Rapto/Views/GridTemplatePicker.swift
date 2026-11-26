//
//  GridTemplatePicker.swift
//  Rapto
//
//  Horizontal scrollable picker for selecting grid templates.
//

import SwiftUI

struct GridTemplatePicker<TrailingContent: View>: View {
    let templates: [GridTemplate]
    
    @Binding var selectedTemplate: GridTemplate?
    
    let onSelect: (GridTemplate) -> Void
    
    var onAddCustom: (() -> Void)? = nil
    
    var onDeleteCustom: ((GridTemplate) -> Void)? = nil
    
    var onRenameCustom: ((GridTemplate, String) -> Void)? = nil
    
    /// IDs of custom templates (for showing delete option)
    var customTemplateIDs: Set<UUID> = []

    /// Custom layout IDs currently shown in the top Drag to Snap bar
    var dragSnapPickerTemplateIDs: Set<UUID> = []

    var onToggleDragSnapPicker: ((GridTemplate) -> Void)? = nil
    
    var onHideStandard: ((GridTemplate) -> Void)? = nil
    
    var onUnhideStandard: ((GridTemplate) -> Void)? = nil
    
    /// Ultrawide layouts tucked into an expandable group on laptops and regular monitors.
    var ultrawideTemplates: [GridTemplate] = []

    /// Standard layouts removed from the list. Shown dimmed after the "Hidden" tile is clicked.
    var hiddenTemplates: [GridTemplate] = []
    
    @State private var showsUltrawide = false
    @State private var isUltrawideHovered = false
    @State private var showsHidden = false
    @State private var hoveredTemplateID: UUID?
    
    /// Optional trailing content (shown after + button)
    var trailingContent: TrailingContent?
    
    @State private var renamingTemplate: GridTemplate? = nil
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(templates) { template in
                    templateView(for: template)
                }
                
                if !ultrawideTemplates.isEmpty {
                    tileButton(
                        title: "Ultrawide (\(ultrawideTemplates.count))",
                        systemImage: showsUltrawide ? "chevron.left" : "rectangle.split.3x1",
                        isHovered: $isUltrawideHovered
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) { showsUltrawide.toggle() }
                    }
                    .help(showsUltrawide ? "Fold ultrawide layouts" : "Show layouts designed for wide monitors")
                    
                    if showsUltrawide {
                        ForEach(ultrawideTemplates) { template in
                            templateView(for: template)
                        }
                    }
                }

                if onAddCustom != nil {
                    addCustomButton
                }
                
                if !hiddenTemplates.isEmpty {
                    tileButton(
                        title: "Hidden (\(hiddenTemplates.count))",
                        systemImage: showsHidden ? "chevron.left" : "eye.slash",
                        isHovered: $isRestoreHovered
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) { showsHidden.toggle() }
                    }
                    .help(showsHidden ? "Fold the hidden layouts" : "Show the layouts you hid")
                    
                    if showsHidden {
                        ForEach(hiddenTemplates) { template in
                            hiddenTemplateView(for: template)
                        }
                    }
                }
                
                if let trailing = trailingContent {
                    trailing
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
        )
        .padding(.horizontal, 40)
        .sheet(item: $renamingTemplate) { template in
            RenameTemplateSheet(
                template: template,
                initialName: template.name,
                onSave: { newName in
                    onRenameCustom?(template, newName)
                    renamingTemplate = nil
                },
                onCancel: {
                    renamingTemplate = nil
                }
            )
        }
    }
    
    // MARK: - Template View
    
    @ViewBuilder
    private func templateView(for template: GridTemplate) -> some View {
        let isCustom = customTemplateIDs.contains(template.id)
        
        GridTemplatePreview(
            template: template,
            isSelected: selectedTemplate?.id == template.id
        )
        .onTapGesture {
            onSelect(template)
        }
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if !isCustom, let onHideStandard, hoveredTemplateID == template.id {
                badge("Hide", systemImage: "eye.slash") { onHideStandard(template) }
            } else if isCustom, dragSnapPickerTemplateIDs.contains(template.id) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(4)
                    .background(Circle().fill(Color.accentColor))
                    .offset(x: 4, y: -4)
                    .help("Shown in the top Drag to Snap bar")
            }
        }
        .onHover { hovering in
            if hovering {
                hoveredTemplateID = template.id
            } else if hoveredTemplateID == template.id {
                hoveredTemplateID = nil
            }
        }
        .contextMenu {
            if isCustom {
                if let onToggleDragSnapPicker {
                    let isPinned = dragSnapPickerTemplateIDs.contains(template.id)
                    Button {
                        onToggleDragSnapPicker(template)
                    } label: {
                        Label(
                            isPinned ? "Remove from Drag to Snap Bar" : "Show in Drag to Snap Bar",
                            systemImage: isPinned ? "pin.slash" : "pin"
                        )
                    }
                    Divider()
                }

                Button {
                    renamingTemplate = template
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                
                if let onDelete = onDeleteCustom {
                    Button(role: .destructive) {
                        onDelete(template)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } else if let onHideStandard {
                Button(role: .destructive) {
                    onHideStandard(template)
                } label: {
                    Label("Hide from List", systemImage: "eye.slash")
                }
            }
        }
    }
    
    /// A layout hidden from the lists: dimmed, with a badge that brings it back
    private func hiddenTemplateView(for template: GridTemplate) -> some View {
        GridTemplatePreview(template: template, isSelected: false)
            .opacity(0.45)
            .overlay(alignment: .topTrailing) {
                badge("Unhide", systemImage: "eye") { onUnhideStandard?(template) }
            }
    }
    
    /// Small button in the corner of a layout tile
    private func badge(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .offset(x: 6, y: -6)
        .help(title == "Hide" ? "Hide this layout from the lists" : "Show this layout in the lists again")
    }
    
    // MARK: - Add Custom Button
    
    @State private var isCustomHovered: Bool = false
    @State private var isRestoreHovered: Bool = false
    
    private var addCustomButton: some View {
        tileButton(title: "Custom", systemImage: "plus", isHovered: $isCustomHovered) {
            onAddCustom?()
        }
    }
    
    /// Dashed tile at the end of the list, the size of a layout preview
    private func tileButton(title: String, systemImage: String, isHovered: Binding<Bool>, action: @escaping () -> Void) -> some View {
        let isCustomHovered = isHovered.wrappedValue
        return Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.1), Color.white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 100, height: 62)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                                )
                                .foregroundColor(isCustomHovered ? Color.white.opacity(0.5) : Color.white.opacity(0.25))
                        )
                    
                    Image(systemName: systemImage)
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(isCustomHovered ? .white : .white.opacity(0.6))
                }
                .scaleEffect(isCustomHovered ? 1.05 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isCustomHovered)
                
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered.wrappedValue = hovering
        }
    }
}

// MARK: - Rename Sheet

struct RenameTemplateSheet: View {
    let template: GridTemplate
    let initialName: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    
    @State private var name: String = ""
    @FocusState private var isNameFocused: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Rename Template")
                .font(.headline)
            
            TextField("Template Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                .focused($isNameFocused)
                .onSubmit {
                    if !name.isEmpty {
                        onSave(name)
                    }
                }
            
            HStack(spacing: 16) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape)
                
                Button("Save") {
                    onSave(name)
                }
                .keyboardShortcut(.return)
                .disabled(name.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .onAppear {
            name = initialName
            isNameFocused = true
        }
    }
}

// MARK: - Convenience Init (no trailing content)

extension GridTemplatePicker where TrailingContent == EmptyView {
    init(
        templates: [GridTemplate],
        selectedTemplate: Binding<GridTemplate?>,
        onSelect: @escaping (GridTemplate) -> Void,
        onAddCustom: (() -> Void)? = nil,
        onDeleteCustom: ((GridTemplate) -> Void)? = nil,
        onRenameCustom: ((GridTemplate, String) -> Void)? = nil,
        customTemplateIDs: Set<UUID> = [],
        onHideStandard: ((GridTemplate) -> Void)? = nil,
        onUnhideStandard: ((GridTemplate) -> Void)? = nil,
        hiddenTemplates: [GridTemplate] = []
    ) {
        self.templates = templates
        self._selectedTemplate = selectedTemplate
        self.onSelect = onSelect
        self.onAddCustom = onAddCustom
        self.onDeleteCustom = onDeleteCustom
        self.onRenameCustom = onRenameCustom
        self.customTemplateIDs = customTemplateIDs
        self.onHideStandard = onHideStandard
        self.onUnhideStandard = onUnhideStandard
        self.hiddenTemplates = hiddenTemplates
        self.trailingContent = nil
    }
}

// MARK: - Preview

#if DEBUG
struct GridTemplatePicker_Previews: PreviewProvider {
    struct PreviewWrapper: View {
        @State private var selected: GridTemplate? = PredefinedTemplates.halvesVertical
        
        var body: some View {
            GridTemplatePicker(
                templates: PredefinedTemplates.all,
                selectedTemplate: $selected,
                onSelect: { selected = $0 }
            )
            .padding(.vertical, 20)
            .background(Color.black.opacity(0.8))
        }
    }
    
    static var previews: some View {
        PreviewWrapper()
    }
}
#endif
