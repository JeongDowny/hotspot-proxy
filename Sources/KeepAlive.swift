import AVFoundation
import UIKit

/// Loops silent audio so the app (and the proxy) stays alive in the background.
///
/// iOS suspends the app the moment the audio session stops being "playing": an interruption,
/// a media-services reset, or the player simply stopping. A suspended app keeps its listening
/// socket, so clients can still connect but never get a reply — which looks like a dead proxy.
/// So: re-assert the session on every lifecycle edge and run a watchdog that restarts playback.
final class KeepAlive {
    private var player: AVAudioPlayer?
    private var watchdog: Timer?
    private var wanted = false

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 99
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt ?? 99
            Diag.log("audio: interruption type=\(raw) reason=\(reason)")
            // Resume after *any* interruption notification; a stale .began is harmless (play() is idempotent).
            self?.resume()
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            Diag.log("audio: route change reason=\(note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 99)")
            self?.resume()
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Diag.log("audio: media services reset")
            self?.player = nil   // the old player is invalid after a reset
            self?.resume()
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Diag.log("app: background")
            self?.resume()
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Diag.log("app: foreground")
            self?.resume()
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in Diag.log("app: willTerminate") }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in Diag.log("app: memory warning") }
    }

    func start() {
        wanted = true
        Diag.log("keepalive: start")
        resume()
        watchdog?.invalidate()
        var tick = 0
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            tick += 1
            if tick % 6 == 0 { Diag.log("heartbeat playing=\(self?.player?.isPlaying == true) otherAudio=\(AVAudioSession.sharedInstance().isOtherAudioPlaying)") }
            self?.resume()
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    func stop() {
        wanted = false
        Diag.log("keepalive: stop")
        watchdog?.invalidate(); watchdog = nil
        player?.stop()
        player = nil
        StatusProbe.shared.setAudioPlaying(false)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Idempotent: (re)activates the session and makes sure the silent loop is playing.
    private func resume() {
        guard wanted else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        if player == nil {
            player = try? AVAudioPlayer(data: Self.silentWav())
            player?.numberOfLoops = -1
        }
        // The samples are silence, so full volume is inaudible; a zero-volume player is a known
        // trigger for iOS deciding the app is not really playing audio.
        player?.volume = 1
        if player?.isPlaying != true { let ok = player?.play() ?? false; Diag.log("audio: (re)start play -> \(ok)") }
        StatusProbe.shared.setAudioPlaying(player?.isPlaying == true)
    }

    /// Long (30s), low-rate (8kHz 8-bit) silence minimizes wakeups at loop boundaries.
    private static func silentWav(seconds: Int = 30, rate: Int = 8000) -> Data {
        let samples = seconds * rate
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + samples))
        d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate)); u16(1); u16(8)
        d.append("data".data(using: .ascii)!); u32(UInt32(samples))
        d.append(Data(repeating: 0x80, count: samples))
        return d
    }
}
