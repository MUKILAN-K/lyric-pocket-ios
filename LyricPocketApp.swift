import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import WhisperKit
import UIKit

@main
struct LyricPocketApp: App {
    var body: some Scene { WindowGroup { PlayerView() } }
}

@MainActor
final class SongPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var name = "No song selected"
    @Published var duration: Double = 0
    @Published var start: Double = 0
    @Published var end: Double = 15
    @Published var playing = false
    @Published var language = "ta"
    @Published var isGenerating = false
    @Published var transcript = ""
    @Published var srtURL: URL?
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

    func generateLyrics() {
        guard let localURL, end > start else { return }
        stop()
        isGenerating = true
        transcript = ""
        srtURL = nil
        message = "Preparing the selected section…"
        let clipStart = start
        let clipEnd = end
        let chosenLanguage = language

        Task {
            do {
                let clip = try await exportClip(from: localURL, start: clipStart, end: clipEnd)
                defer { try? FileManager.default.removeItem(at: clip) }
                let transcriptionAudio: URL
                if chosenLanguage == "ta" {
                    message = "Layer 1 of 2: reducing music and strengthening centered vocals…"
                    transcriptionAudio = try makeVocalFocusedCopy(from: clip)
                } else {
                    transcriptionAudio = clip
                }
                defer { if transcriptionAudio != clip { try? FileManager.default.removeItem(at: transcriptionAudio) } }
                message = "Downloading and preparing the AI model. Keep the app open…"
                let kit = try await WhisperKit(
                    model: "large-v3-v20240930_626MB",
                    verbose: false,
                    prewarm: true,
                    load: true,
                    useBackgroundDownloadSession: true
                )
                message = "Listening for \(chosenLanguage == "ta" ? "Tamil" : chosenLanguage == "en" ? "English" : "Tamil and English") lyrics…"
                let options = DecodingOptions(
                    task: .transcribe,
                    language: chosenLanguage == "auto" ? nil : chosenLanguage,
                    skipSpecialTokens: true,
                    wordTimestamps: true
                )
                message = "Layer 2 of 2: listening for \(chosenLanguage == "ta" ? "Tamil" : chosenLanguage == "en" ? "English" : "Tamil and English") lyrics…"
                let results = try await kit.transcribe(audioPath: transcriptionAudio.path, decodeOptions: options)
                let segments = results.flatMap(\.segments)
                transcript = segments.map { cleanText($0.text) }.filter { !$0.isEmpty }.joined(separator: " ")
                srtURL = try writeSRT(segments: segments, offset: clipStart)
                message = transcript.isEmpty ? "No clear lyrics were detected. Try a section with louder vocals." : "Draft complete. Edit the words if needed, then export the SRT."
            } catch {
                message = "Lyrics generation failed: \(error.localizedDescription)"
            }
            isGenerating = false
        }
    }

    private func exportClip(from source: URL, start: Double, end: Double) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("lyric-pocket-\(UUID().uuidString).m4a")
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "LyricPocket", code: 1, userInfo: [NSLocalizedDescriptionKey: "This audio format cannot be prepared."])
        }
        exporter.outputURL = output
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        await exporter.export()
        guard exporter.status == .completed else { throw exporter.error ?? NSError(domain: "LyricPocket", code: 2) }
        return output
    }

    private func writeSRT(segments: [TranscriptionSegment], offset: Double) throws -> URL {
        let usable = segments.compactMap { segment -> (TranscriptionSegment, String)? in
            let text = cleanText(segment.text)
            return text.isEmpty ? nil : (segment, text)
        }
        let body = usable.enumerated().map { index, entry in
            "\(index + 1)\n\(srtTime(Double(entry.0.start) + offset)) --> \(srtTime(Double(entry.0.end) + offset))\n\(entry.1)"
        }.joined(separator: "\n\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LyricPocket-Lyrics.srt")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeVocalFocusedCopy(from source: URL) throws -> URL {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length)) else {
            throw NSError(domain: "LyricPocket", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not prepare vocal processing."])
        }
        try input.read(into: buffer)
        guard let sourceChannels = buffer.floatChannelData,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let output = mono.floatChannelData?[0] else {
            throw NSError(domain: "LyricPocket", code: 4, userInfo: [NSLocalizedDescriptionKey: "This audio format cannot be vocal-focused."])
        }
        mono.frameLength = buffer.frameLength
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        let rate = Float(format.sampleRate)
        let highPassAlpha = (1 / (2 * Float.pi * 110)) / ((1 / (2 * Float.pi * 110)) + (1 / rate))
        let lowPassAlpha = (1 / rate) / ((1 / (2 * Float.pi * 8_000)) + (1 / rate))
        var previousInput: Float = 0
        var previousHigh: Float = 0
        var previousLow: Float = 0
        var peak: Float = 0
        for index in 0..<count {
            var centered = sourceChannels[0][index]
            if channelCount > 1 { centered = (centered + sourceChannels[1][index]) * 0.5 }
            let high = highPassAlpha * (previousHigh + centered - previousInput)
            let low = previousLow + lowPassAlpha * (high - previousLow)
            let compressed = tanhf(low * 2.4)
            output[index] = compressed
            peak = max(peak, abs(compressed))
            previousInput = centered
            previousHigh = high
            previousLow = low
        }
        if peak > 0.0001 {
            let gain = min(8, 0.95 / peak)
            for index in 0..<count { output[index] *= gain }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyric-pocket-vocals-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: monoFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: mono)
        return url
    }

    private func cleanText(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^>]+\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func srtTime(_ seconds: Double) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
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
                        Divider().padding(.vertical, 8)
                        Text("Generate lyrics").font(.title2.bold())
                        Picker("Song language", selection: $song.language) {
                            Text("Tamil").tag("ta")
                            Text("English").tag("en")
                            Text("Tamil + English").tag("auto")
                        }.pickerStyle(.segmented)
                        Text("The first run downloads about 626 MB over Wi-Fi. The model and your audio stay on this iPhone.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(song.isGenerating ? "Working…" : "Generate lyrics on iPhone", systemImage: "waveform.and.magnifyingglass") {
                            song.generateLyrics()
                        }
                        .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                        .disabled(song.isGenerating || song.end <= song.start)
                        if song.isGenerating { ProgressView().tint(accent) }
                        if !song.transcript.isEmpty {
                            Text("Editable lyric draft").font(.headline)
                            TextEditor(text: $song.transcript)
                                .frame(minHeight: 150).padding(8)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if let srtURL = song.srtURL {
                            ShareLink(item: srtURL) {
                                Label("Export SRT", systemImage: "square.and.arrow.up")
                            }.buttonStyle(.bordered)
                        }
                    }
                    Text(song.message).font(.footnote).accessibilityIdentifier("status")
                    Divider()
                    Text("Lyrics are generated on this iPhone. Singing is harder than speech, so the result remains an editable draft.")
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
