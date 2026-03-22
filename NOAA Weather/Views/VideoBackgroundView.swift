import SwiftUI
import AVFoundation

struct VideoBackgroundView: UIViewRepresentable {
    let videoName: String

    func makeUIView(context: Context) -> VideoLoopView {
        return VideoLoopView()
    }

    func updateUIView(_ uiView: VideoLoopView, context: Context) {
        uiView.play(named: videoName)
    }
    
    // Crucial for cleaning up memory when swiping between pages
    static func dismantleUIView(_ uiView: VideoLoopView, coordinator: ()) {
        uiView.cleanup()
    }
}

final class VideoLoopView: UIView {
    private var playerLooper: AVPlayerLooper?
    private var queuePlayer: AVQueuePlayer?
    private var currentName: String?
    private var foregroundObserver: Any?

    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var avLayer: AVPlayerLayer { self.layer as! AVPlayerLayer }

    func play(named name: String) {
        guard name != currentName else {
            queuePlayer?.play()
            return
        }
        
        cleanup() // Clear old resources before starting new ones
        currentName = name

        guard let url = Bundle.main.url(forResource: name, withExtension: "mov") else { return }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        
        playerLooper = AVPlayerLooper(player: player, templateItem: item)
        queuePlayer = player

        avLayer.player = player
        avLayer.videoGravity = .resizeAspectFill
        
        // Use a single managed observer
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.queuePlayer?.play()
        }

        player.play()
    }

    func cleanup() {
        queuePlayer?.pause()
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
        playerLooper = nil
        queuePlayer = nil
        avLayer.player = nil
        currentName = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        avLayer.frame = bounds
    }
    
    deinit {
        cleanup()
    }
}

