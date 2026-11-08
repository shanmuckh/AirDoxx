import Foundation
import MediaPlayer

/// Current macOS sends the play/pause, next and previous keys (F7–F9, AirPods, Control Center)
/// only to the app registered as "Now Playing". While mirroring, AirDoxx registers
/// itself and forwards those commands to the phone.
final class NowPlayingBridge {
    /// Receives an Android media keycode.
    var onKey: ((UInt32) -> Void)?
    private var registered = false

    func activate(title: String) {
        registerCommandsOnce()
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "AirDoxx",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        center.playbackState = .playing
    }

    func deactivate() {
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = .stopped
        center.nowPlayingInfo = nil
    }

    private func registerCommandsOnce() {
        guard !registered else { return }
        registered = true
        let cc = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ keycode: UInt32) {
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                guard let self, let onKey = self.onKey else { return .noActionableNowPlayingItem }
                onKey(keycode)
                return .success
            }
        }
        bind(cc.togglePlayPauseCommand, 85) // KEYCODE_MEDIA_PLAY_PAUSE
        bind(cc.playCommand, 85)
        bind(cc.pauseCommand, 85)
        bind(cc.nextTrackCommand, 87)       // KEYCODE_MEDIA_NEXT
        bind(cc.previousTrackCommand, 88)   // KEYCODE_MEDIA_PREVIOUS
    }
}
