//
//  VisualEffectView.swift
//  Rapto
//
//  NSViewRepresentable wrapper for NSVisualEffectView to use in SwiftUI.
//

import SwiftUI
import AppKit

struct VisualEffectView: NSViewRepresentable {
    
    let material: NSVisualEffectView.Material
    
    let blendingMode: NSVisualEffectView.BlendingMode
    
    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Preview

#if DEBUG
struct VisualEffectView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.red
            VisualEffectView()
                .frame(width: 200, height: 200)
        }
        .frame(width: 400, height: 400)
    }
}
#endif
