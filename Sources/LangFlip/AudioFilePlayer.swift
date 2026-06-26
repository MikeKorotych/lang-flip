import AVFoundation
import Foundation

final class AudioFilePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioFilePlayer()

    private var player: AVAudioPlayer?
    private(set) var currentURL: URL?
    private(set) var isPaused = false

    private override init() {}

    var isPlaying: Bool {
        player?.isPlaying == true
    }

    func isCurrent(_ url: URL) -> Bool {
        currentURL?.standardizedFileURL == url.standardizedFileURL
    }

    @discardableResult
    func play(_ url: URL) -> Bool {
        stop()
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.delegate = self
            next.prepareToPlay()
            player = next
            currentURL = url.standardizedFileURL
            isPaused = false
            let started = next.play()
            notify()
            return started
        } catch {
            Notifications.show(title: "Audio playback failed", body: error.localizedDescription)
            notify()
            return false
        }
    }

    @discardableResult
    func pause() -> Bool {
        guard let player, player.isPlaying else { return false }
        player.pause()
        isPaused = true
        notify()
        return true
    }

    @discardableResult
    func resume() -> Bool {
        guard let player, isPaused else { return false }
        isPaused = false
        let started = player.play()
        notify()
        return started
    }

    func stop() {
        if let player {
            player.stop()
        }
        player = nil
        currentURL = nil
        isPaused = false
        notify()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if self.player === player {
            self.player = nil
            currentURL = nil
            isPaused = false
            notify()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if self.player === player {
            self.player = nil
            currentURL = nil
            isPaused = false
            if let error {
                Notifications.show(title: "Audio playback failed", body: error.localizedDescription)
            }
            notify()
        }
    }

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .langFlipTTSStateChanged, object: nil)
        }
    }
}
