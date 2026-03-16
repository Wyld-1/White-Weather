//
//  VideoBackgroundView.swift
//  NOAA Weather
//
//  Wraps AVPlayerLooper to play a looping .mov background video.

import SwiftUI
import AVFoundation
import AVKit

struct VideoBackgroundView: UIViewRepresentable {
    let videoName: String

    func makeUIView(context: Context) -> VideoLoopView {
        let view = VideoLoopView()
        view.play(named: videoName)
        return view
    }

    func updateUIView(_ uiView: VideoLoopView, context: Context) {
        uiView.play(named: videoName)
    }
}

// UIView subclass that owns the player and looper
final class VideoLoopView: UIView {
    private var playerLooper: AVPlayerLooper?
    private var queuePlayer: AVQueuePlayer?
    private var currentName: String?

    // self.layer IS the AVPlayerLayer because of layerClass override
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var avLayer: AVPlayerLayer { self.layer as! AVPlayerLayer }

    func play(named name: String) {
        guard name != currentName else {
            // Same video — make sure it's still playing (e.g. after backgrounding)
            queuePlayer?.play()
            return
        }
        currentName = name

        // Tear down previous
        playerLooper = nil
        queuePlayer?.pause()
        queuePlayer = nil

        guard let url = Bundle.main.url(forResource: name, withExtension: "mov") else {
            print("VideoBackgroundView: could not find \(name).mov in bundle")
            return
        }

        let player = AVQueuePlayer()
        let item = AVPlayerItem(url: url)
        playerLooper = AVPlayerLooper(player: player, templateItem: item)
        queuePlayer = player

        avLayer.player = player
        avLayer.videoGravity = .resizeAspectFill

        // Resume playback when app returns to foreground
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.queuePlayer?.play()
        }

        player.play()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        avLayer.frame = bounds
    }
}
