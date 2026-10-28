import Foundation
import UIKit
import AVFoundation
import Capacitor
#if canImport(ActivityKit)
import ActivityKit
#endif

// Lyrics on the lock screen and in the Dynamic Island. The page (mobile/live-activity.js) sends the song,
// its synced lyrics and every play/pause/seek; the line timing runs here, so the Live Activity keeps up
// with the song in the background without the web view having to send each line.
@objc(MurielLiveActivityPlugin)
public class MurielLiveActivityPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "MurielLiveActivityPlugin"
    public let jsName = "MurielLiveActivity"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setTrack", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setLyrics", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPlayback", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
    ]

    override public func load() {
        // an activity left over from the last run (the app was closed) would otherwise sit there frozen
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) { DispatchQueue.main.async { LyricsActivity.shared.endAll() } }
        #endif
        // the buttons in the Dynamic Island (MurielPlayerIntent): play / pause, next, previous, shuffle
        NotificationCenter.default.addObserver(forName: Notification.Name("MurielPlayerAction"), object: nil, queue: .main) { [weak self] note in
            guard let action = note.userInfo?["action"] as? String else { return }
            self?.notifyListeners("action", data: ["action": action])
        }
    }

    @objc func isAvailable(_ call: CAPPluginCall) {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            call.resolve(["available": ActivityAuthorizationInfo().areActivitiesEnabled])
            return
        }
        #endif
        call.resolve(["available": false])
    }

    @objc func setTrack(_ call: CAPPluginCall) {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            let id = call.getString("id") ?? ""
            let title = call.getString("title") ?? ""
            let artist = call.getString("artist") ?? ""
            let artwork = call.getString("artwork") ?? ""
            DispatchQueue.main.async { LyricsActivity.shared.setTrack(id: id, title: title, artist: artist, artworkURL: artwork) }
        }
        #endif
        call.resolve()
    }

    @objc func setLyrics(_ call: CAPPluginCall) {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            let id = call.getString("id") ?? ""
            let json = call.getString("lines") ?? "[]"
            DispatchQueue.main.async { LyricsActivity.shared.setLyrics(id: id, json: json) }
        }
        #endif
        call.resolve()
    }

    @objc func setPlayback(_ call: CAPPluginCall) {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            let playing = call.getBool("playing") ?? false
            let position = call.getDouble("position") ?? 0
            let rate = call.getDouble("rate") ?? 1
            let duration = call.getDouble("duration") ?? 0
            let shuffle = call.getBool("shuffle") ?? false
            DispatchQueue.main.async {
                LyricsActivity.shared.setPlayback(playing: playing, position: position, rate: rate, duration: duration, shuffle: shuffle)
            }
        }
        #endif
        call.resolve()
    }

    @objc func stop(_ call: CAPPluginCall) {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) { DispatchQueue.main.async { LyricsActivity.shared.endAll() } }
        #endif
        call.resolve()
    }
}

#if canImport(ActivityKit)
// Everything below runs on the main thread.
@available(iOS 16.2, *)
final class LyricsActivity {
    static let shared = LyricsActivity()
    typealias State = MurielLyricsAttributes.ContentState

    private struct Line: Decodable { let t: Double; let x: String }

    private var activity: Activity<MurielLyricsAttributes>?
    private var trackId = ""
    private var title = ""
    private var artist = ""
    private var artworkURL = ""
    private var artwork: Data?
    private var lines: [Line] = []
    private var playing = false
    private var anchorPosition = 0.0
    private var anchorTime = Date()
    private var rate = 1.0
    private var duration = 0.0
    private var shuffle = false
    private var shown: State?
    private var nextLine: DispatchWorkItem?
    private var idleEnd: DispatchWorkItem?
    private let keepAwake = KeepAwake()

    func setTrack(id: String, title: String, artist: String, artworkURL: String) {
        trackId = id
        self.title = String(title.prefix(80))
        self.artist = String(artist.prefix(60))
        lines = []
        if artworkURL != self.artworkURL {
            self.artworkURL = artworkURL
            artwork = nil
            loadArtwork(artworkURL, for: id)
        }
        refresh()
    }

    func setLyrics(id: String, json: String) {
        guard id == trackId else { return }
        let parsed = (try? JSONDecoder().decode([Line].self, from: Data(json.utf8))) ?? []
        lines = parsed.filter { $0.t >= 0 && !$0.x.isEmpty }.sorted { $0.t < $1.t }
        refresh()
    }

    func setPlayback(playing: Bool, position: Double, rate: Double, duration: Double, shuffle: Bool) {
        self.playing = playing
        anchorPosition = max(0, position)
        anchorTime = Date()
        self.rate = rate > 0 ? rate : 1
        self.duration = duration.isFinite && duration > 0 ? duration : 0
        self.shuffle = shuffle
        // a long pause ends the activity, so it doesn't stay on the lock screen all night
        idleEnd?.cancel()
        if !playing {
            let work = DispatchWorkItem { [weak self] in self?.endAll() }
            idleEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 20 * 60, execute: work)
        }
        refresh()
        keepAwake.playing(playing && isLive)
    }

    private var isLive: Bool {
        guard let a = activity else { return false }
        return a.activityState == .active || a.activityState == .stale
    }

    func endAll() {
        nextLine?.cancel()
        idleEnd?.cancel()
        keepAwake.stop()
        activity = nil
        shown = nil
        for a in Activity<MurielLyricsAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    // the app is closing: end the activity before it goes (otherwise it stays on the lock screen, frozen)
    func endAllBeforeExit() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for a in Activity<MurielLyricsAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
    }

    private func position() -> Double {
        playing ? anchorPosition + Date().timeIntervalSince(anchorTime) * rate : anchorPosition
    }

    // shows the line being sung now and wakes up again for the next one
    private func refresh() {
        nextLine?.cancel()
        let pos = position()
        var index = -1
        for (i, l) in lines.enumerated() {
            if l.t <= pos + 0.15 { index = i } else { break }
        }
        let line = index >= 0 ? lines[index].x : ""
        let next = index + 1 < lines.count ? lines[index + 1].x : ""
        // while playing, the progress bar runs from when the song was at 0:00
        let start = playing && duration > 0 ? anchorTime.addingTimeInterval(-anchorPosition / rate) : nil
        push(State(title: title, artist: artist, line: String(line.prefix(120)), next: String(next.prefix(120)),
                   playing: playing, artwork: artwork, duration: duration, position: min(anchorPosition, duration > 0 ? duration : anchorPosition),
                   start: start, shuffle: shuffle))
        if playing, index + 1 < lines.count {
            let delay = max(0.05, (lines[index + 1].t - pos) / rate)
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            nextLine = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func push(_ state: State) {
        if state == shown { return }
        let content = ActivityContent(state: state, staleDate: nil)
        if let a = activity, a.activityState == .active || a.activityState == .stale {
            shown = state
            Task { await a.update(content) }
            return
        }
        activity = nil
        // only while something plays, and iOS only allows starting one while Muriel is open
        guard playing, !title.isEmpty, UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(attributes: MurielLyricsAttributes(), content: content, pushType: nil)
            shown = state
        } catch {
            activity = nil
        }
    }

    private func loadArtwork(_ url: String, for id: String) {
        guard let u = URL(string: url), u.scheme == "https" else { return }
        URLSession.shared.dataTask(with: URLRequest(url: u, timeoutInterval: 10)) { data, _, _ in
            guard let data = data, let image = UIImage(data: data), let thumb = Self.thumbnail(image) else { return }
            DispatchQueue.main.async {
                guard self.trackId == id else { return }
                self.artwork = thumb
                self.refresh()
            }
        }.resume()
    }

    // a small square JPEG: ActivityKit allows 4 KB for the whole activity, text included
    static func thumbnail(_ image: UIImage) -> Data? {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return nil }
        // YouTube's 4:3 thumbnails are a 16:9 picture with black bars above and below
        let contentHeight = abs(w / h - 4.0 / 3.0) < 0.05 ? w * 9 / 16 : h
        let side = min(w, contentHeight)
        let crop = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
        let target: CGFloat = 56
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            let k = target / side
            image.draw(in: CGRect(x: -crop.minX * k, y: -crop.minY * k, width: w * k, height: h * k))
        }
        for quality in [0.55, 0.4, 0.28, 0.18] {
            if let data = scaled.jpegData(compressionQuality: CGFloat(quality)), data.count <= 1700 { return data }
        }
        return nil
    }
}

// Keeps Muriel itself running while a song plays in the background, so the lines above keep coming.
// The song plays inside WebKit, which keeps the page going but not the app: iOS suspended the app,
// its timers stopped and the lyrics stayed on one line (on the lock screen and in CarPlay) until it
// was opened again. A muted loop of silence played by the app keeps it awake.
@available(iOS 16.2, *)
private final class KeepAwake {
    private var player: AVAudioPlayer?
    private var stopLater: DispatchWorkItem?

    func playing(_ on: Bool) {
        stopLater?.cancel()
        if on { start(); return }
        // between two songs it's paused for a moment; after a real pause the app may sleep again
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    func stop() {
        stopLater?.cancel()
        player?.stop()
    }

    private func start() {
        if player == nil {
            player = try? AVAudioPlayer(data: Self.silence())
            player?.numberOfLoops = -1
            player?.volume = 0
        }
        // only once a song plays, so WebKit has already taken the audio session (not stopping other apps)
        guard let p = player, !p.isPlaying else { return }
        p.play()
    }

    // one second of 16-bit mono silence as a WAV file
    private static func silence(rate: UInt32 = 8000) -> Data {
        let bytes = rate * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        d.append(Data(count: Int(bytes)))
        return d
    }
}
#endif
