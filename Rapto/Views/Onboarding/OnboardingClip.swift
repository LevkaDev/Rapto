//
//  OnboardingClip.swift
//  Rapto
//
//  Looping demo videos for the onboarding stage. They are authored with Clayzo in
//  `Animations/` and exported to `Resources/Onboarding`; run `npm run build` there to remake them.
//

import AVFoundation
import SwiftUI

enum OnboardingClip: String {
    case welcome
    case dragSnap = "dragsnap"
    case manual
    case autoTiling = "autotiling"
    case desktops
    case workspaces

    var url: URL? {
        Bundle.main.url(forResource: "onboarding-\(rawValue)", withExtension: "mp4")
    }

    /// The frame shown instead of the loop when Reduce Motion is on: the idea at a glance
    var posterSeconds: Double {
        switch self {
        case .welcome: return 1.3
        case .dragSnap: return 2.7
        case .manual: return 2.85
        case .autoTiling: return 4.6
        case .desktops: return 1.6
        case .workspaces: return 3.4
        }
    }

    static func forMode(_ mode: TilingMode?) -> OnboardingClip {
        switch mode {
        case .autoTiling: return .autoTiling
        case .manualAssignment: return .manual
        default: return .dragSnap
        }
    }
}

/// Plays a clip on a loop, muted. With Reduce Motion it shows a still frame with a play button.
struct OnboardingClipView: View {
    let clip: OnboardingClip

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playsAnyway = false

    var body: some View {
        OnboardingClipPlayer(clip: clip, isPlaying: !reduceMotion || playsAnyway)
            .accessibilityHidden(true)
            .overlay {
                if reduceMotion && !playsAnyway {
                    Button { playsAnyway = true } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(.black.opacity(0.55), in: Circle())
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Play animation")
                    .accessibilityLabel("Play animation")
                }
            }
    }
}

private struct OnboardingClipPlayer: NSViewRepresentable {
    let clip: OnboardingClip
    let isPlaying: Bool

    func makeNSView(context: Context) -> OnboardingPlayerView {
        OnboardingPlayerView(clip: clip)
    }

    func updateNSView(_ view: OnboardingPlayerView, context: Context) {
        view.setPlaying(isPlaying)
    }

    static func dismantleNSView(_ view: OnboardingPlayerView, coordinator: ()) {
        view.stop()
    }
}

final class OnboardingPlayerView: NSView {
    private let clip: OnboardingClip
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var isPlaying: Bool?

    init(clip: OnboardingClip) {
        self.clip = clip
        super.init(frame: .zero)
        wantsLayer = true
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = NSColor(OnboardingPalette.field).cgColor
        return layer
    }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        guard let url = clip.url else {
            debugLog("Onboarding", "Missing clip \(clip.rawValue)")
            return
        }
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()

        let item = AVPlayerItem(url: url)
        if playing {
            looper = AVPlayerLooper(player: player, templateItem: item)
            player.play()
        } else {
            player.insert(item, after: nil)
            player.pause()
            player.seek(to: CMTime(seconds: clip.posterSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func stop() {
        looper?.disableLooping()
        player.pause()
        player.removeAllItems()
    }
}

#Preview {
    OnboardingClipView(clip: .workspaces)
        .frame(width: 700, height: 230)
}
