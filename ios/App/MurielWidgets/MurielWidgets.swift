import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// The Live Activity: the song, its progress and the line being sung, on the lock screen and in the
// Dynamic Island, where long-pressing opens a small player (buttons need iOS 17).
// The app keeps it up to date (App/LyricsLiveActivity.swift); this only draws it.
// It also has a small layout, which CarPlay (iOS 26) and the Apple Watch Smart Stack use: without it
// CarPlay would only show the Dynamic Island's compact views (cover and waveform, no lyrics).
// That layout needs iOS 18, so this extension targets iOS 18 (the app itself still runs on 16.2).
@main
struct MurielWidgets: WidgetBundle {
    var body: some Widget {
        MurielLyricsLiveActivity()
    }
}

private let pink = Color(red: 1.0, green: 0.31, blue: 0.64)
private let violet = Color(red: 0.55, green: 0.36, blue: 0.96)

struct MurielLyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MurielLyricsAttributes.self) { context in
            FamilyAwareLyrics(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.5))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Artwork(data: state.artwork, size: 50, radius: 12)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PlayingMark(playing: state.playing, size: 17)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text(state.artist)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if !state.line.isEmpty {
                            Text(state.line)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentTransition(.opacity)
                        }
                        SongProgress(state: state)
                        if #available(iOS 17.0, *) {
                            PlayerButtons(state: state)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                }
            } compactLeading: {
                Artwork(data: state.artwork, size: 24, radius: 7)
            } compactTrailing: {
                PlayingMark(playing: state.playing, size: 14)
            } minimal: {
                Artwork(data: state.artwork, size: 24, radius: 12)
            }
            .keylineTint(pink)
        }
        .supplementalActivityFamilies([.small])
    }
}

// .small is CarPlay or the watch; anything else is the normal lock screen view
struct FamilyAwareLyrics: View {
    @Environment(\.activityFamily) private var family
    let state: MurielLyricsAttributes.ContentState

    var body: some View {
        switch family {
        case .small:
            SmallLyrics(state: state)
        default:
            LockScreenLyrics(state: state)
        }
    }
}

// CarPlay: read at a glance, so just the line being sung, big, under the song's name.
// CarPlay activities can't be tapped, so no buttons and no progress bar.
struct SmallLyrics: View {
    let state: MurielLyricsAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Artwork(data: state.artwork, size: 20, radius: 5)
                Text(header)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(1)
                Spacer(minLength: 2)
                PlayingMark(playing: state.playing, size: 11)
            }
            Text(mainLine)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
    }

    private var hasLyrics: Bool { !state.line.isEmpty || !state.next.isEmpty }

    // with lyrics: the song on top and the line below; without: the artist on top and the song below
    private var header: String {
        hasLyrics ? [state.title, state.artist].filter { !$0.isEmpty }.joined(separator: " · ")
                  : (state.artist.isEmpty ? "Muriel" : state.artist)
    }

    private var mainLine: String {
        if hasLyrics { return state.line.isEmpty ? "♪" : state.line }
        return state.title.isEmpty ? "Muriel" : state.title
    }
}

struct LockScreenLyrics: View {
    let state: MurielLyricsAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Artwork(data: state.artwork, size: 58, radius: 14)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(header)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    PlayingMark(playing: state.playing, size: 13)
                }
                LyricLines(state: state, big: 20, small: 15)
                SongProgress(state: state)
                    .padding(.top, 4)
            }
        }
        .padding(16)
    }

    private var header: String {
        hasLyrics ? [state.title, state.artist].filter { !$0.isEmpty }.joined(separator: " · ") : "Muriel"
    }

    private var hasLyrics: Bool { !state.line.isEmpty || !state.next.isEmpty }
}

// the line being sung, big, and the one after it, dimmed. Without synced lyrics: the song itself.
struct LyricLines: View {
    let state: MurielLyricsAttributes.ContentState
    let big: CGFloat
    let small: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.line.isEmpty && state.next.isEmpty {
                Text(state.title.isEmpty ? "Muriel" : state.title)
                    .font(.system(size: big, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(2)
                if !state.artist.isEmpty {
                    Text(state.artist)
                        .font(.system(size: small, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
            } else {
                Text(state.line.isEmpty ? "♪" : state.line)
                    .font(.system(size: big, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.opacity)
                if !state.next.isEmpty {
                    Text(state.next)
                        .font(.system(size: small, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.42))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// the bar and the times; while playing it moves by itself (no update needed every second)
struct SongProgress: View {
    let state: MurielLyricsAttributes.ContentState

    var body: some View {
        if state.duration > 0 {
            VStack(spacing: 3) {
                if state.playing, let start = state.start {
                    let range = start...start.addingTimeInterval(state.duration)
                    ProgressView(timerInterval: range, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() })
                        .tint(pink)
                    HStack {
                        Text(timerInterval: range, countsDown: false)
                        Spacer()
                        Text(clock(state.duration))
                    }
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(.white.opacity(0.55))
                } else {
                    ProgressView(value: min(state.position, state.duration), total: state.duration)
                        .tint(pink)
                    HStack {
                        Text(clock(state.position))
                        Spacer()
                        Text(clock(state.duration))
                    }
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(.white.opacity(0.55))
                }
            }
        }
    }

    private func clock(_ s: Double) -> String {
        let t = Int(max(0, s).rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// shuffle · previous · play/pause · next, run in the app by MurielPlayerIntent
@available(iOS 17.0, *)
struct PlayerButtons: View {
    let state: MurielLyricsAttributes.ContentState

    var body: some View {
        HStack {
            button("shuffle", "shuffle", 17, on: state.shuffle)
            Spacer()
            button("prev", "backward.fill", 21)
            Spacer()
            button("toggle", state.playing ? "pause.fill" : "play.fill", 28)
            Spacer()
            button("next", "forward.fill", 21)
            Spacer()
            // keeps play/pause in the middle
            Color.clear.frame(width: 34, height: 34)
        }
        .padding(.horizontal, 8)
    }

    private func button(_ action: String, _ symbol: String, _ size: CGFloat, on: Bool = true) -> some View {
        Button(intent: MurielPlayerIntent(action: action)) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(on ? .white : .white.opacity(0.4))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
    }
}

struct PlayingMark: View {
    let playing: Bool
    let size: CGFloat

    var body: some View {
        Image(systemName: playing ? "waveform" : "pause.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(playing ? pink : .white.opacity(0.6))
    }
}

struct Artwork: View {
    let data: Data?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let data = data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [pink, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "sparkles")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
