import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@main
struct LyricPocketApp: App {
    var body: some Scene { WindowGroup { PlayerView() } }
}

final class SongPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var name = "No song selected"
    @Published var duration: Double = 0
    @Published var start: Double = 0
    @Published var end: Double = 15
    @Published var playing = false
    @Published var message = "Choose an audio file from Files."
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var localURL: URL?

    func load(_ url: URL) {
        stop()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            let next = try AVAudioPlayer(contentsOf: copy)
            next.delegate = self
            next.prepareToPlay()
            player = next
            if let old = localURL { try? FileManager.default.removeItem(at: old) }
            localURL = copy
            name = url.lastPathComponent
            duration = next.duration
            start = 0
            end = min(15, duration)
            message = "Audio stays on this iPhone."
        } catch {
            try? FileManager.default.removeItem(at: copy)
            message = "Could not open this file: \(error.localizedDescription)"
        }
    }

    func play() {
        guard let player, end > start, start >= 0, end <= duration else { return }
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            player.currentTime = start
            guard player.play() else { message = "Playback could not start."; return }
            playing = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                guard let self else { return }
                if player.currentTime >= self.end || !player.isPlaying { self.stop() }
            }
        } catch { message = "Playback failed: \(error.localizedDescription)" }
    }

    func stop() { player?.pause(); timer?.invalidate(); timer = nil; playing = false }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { stop() }
    deinit { timer?.invalidate(); if let localURL { try? FileManager.default.removeItem(at: localURL) } }
}

struct PlayerView: View {
    @StateObject private var song = SongPlayer()
    @State private var importing = false
    @Environment(\.scenePhase) private var scenePhase
    private let accent = Color(red: 0.85, green: 0.93, blue: 0.61)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("NATIVE IPHONE TEST · 01").font(.caption).foregroundStyle(accent)
                    Text("Every lyric starts\nwith a listen.").font(.system(size: 38, weight: .regular, design: .serif))
                    Text("Import your song and preview a short section.").foregroundStyle(.secondary)
                    Button { importing = true } label: { Label("Pick a song from Files", systemImage: "music.note") }
                        .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                    Text(song.name).font(.headline)
                    if song.duration > 0 {
                        Text("Song length: \(song.duration, specifier: "%.1f") seconds")
                        Text("Start: \(song.start, specifier: "%.1f") seconds")
                        Slider(value: $song.start, in: 0...max(0.1, song.duration - 0.1), step: 0.1)
                            .onChange(of: song.start) { _, value in
                                song.stop()
                                song.end = min(song.duration, max(song.end, value + 0.1))
                            }
                        Text("End: \(song.end, specifier: "%.1f") seconds")
                        Slider(value: $song.end, in: 0...song.duration, step: 0.1)
                            .onChange(of: song.end) { _, _ in song.stop() }
                        Button("Use 15 seconds from start") { song.stop(); song.end = min(song.duration, song.start + 15) }
                        if song.end <= song.start { Text("Move the end after the start.").foregroundStyle(.orange) }
                        HStack {
                            Button("Play section", systemImage: "play.fill") { song.play() }
                                .disabled(song.end <= song.start || song.playing)
                            Button("Pause", systemImage: "pause.fill") { song.stop() }.disabled(!song.playing)
                        }.buttonStyle(.bordered)
                    }
                    Text(song.message).font(.footnote).accessibilityIdentifier("status")
                    Divider()
                    Text("First we verify native installation and playback. The AI model will be added after this test works.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }.navigationTitle("Lyric Pocket").navigationBarTitleDisplayMode(.inline)
                .background(Color(red: 0.07, green: 0.11, blue: 0.10)).tint(accent)
        }.preferredColorScheme(.dark)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url): song.load(url)
                case .failure(let error): song.message = error.localizedDescription
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { song.stop() } }
    }
}
