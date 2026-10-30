import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import WhisperKit
import UIKit

@main
struct LyricPocketApp: App {
    var body: some Scene { WindowGroup { PlayerView() } }
}

struct ReviewWord: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let start: Double
    let end: Double
}

@MainActor
final class SongPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var name = "No song selected"
    @Published var duration: Double = 0
    @Published var start: Double = 0
    @Published var end: Double = 15
    @Published var playing = false
    @Published var language = "ta"
    @Published var generationMode = "song"
    @Published var suppliedLyrics = ""
    @Published var embeddedLyrics = ""
    @Published var isGenerating = false
    @Published var transcript = ""
    @Published var srtURL: URL?
    @Published var baminiSRTURL: URL?
    @Published var message = "Choose an audio file from Files."
    @Published var processingStage = ""
    @Published var currentTime: Double = 0
    @Published var reviewWords: [ReviewWord] = []
    @Published var showReview = false
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
            currentTime = 0
            reviewWords = []
            showReview = false
            message = "Audio stays on this iPhone."
            suppliedLyrics = ""
            embeddedLyrics = ""
            Task { await readEmbeddedLyrics(from: copy) }
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
            currentTime = start
            guard player.play() else { message = "Playback could not start."; return }
            playing = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.currentTime = player.currentTime
                if player.currentTime >= self.end || !player.isPlaying { self.stop() }
            }
        } catch { message = "Playback failed: \(error.localizedDescription)" }
    }

    func stop() { player?.pause(); timer?.invalidate(); timer = nil; playing = false }

    func seek(to time: Double) {
        let value = min(duration, max(0, time))
        player?.currentTime = value
        currentTime = value
    }

    func setStart(_ value: Double) {
        stop()
        start = min(max(0, value), max(0, end - 0.1))
        seek(to: start)
    }

    func setEnd(_ value: Double) {
        stop()
        end = max(min(duration, value), min(duration, start + 0.1))
    }

    func generateLyrics() {
        guard let localURL, end > start else { return }
        stop()
        isGenerating = true
        transcript = ""
        srtURL = nil
        baminiSRTURL = nil
        reviewWords = []
        showReview = false
        processingStage = "Preparing audio"
        message = "Preparing the selected section…"
        let clipStart = start
        let clipEnd = end
        let chosenLanguage = language
        let chosenMode = generationMode
        let referenceLyrics = suppliedLyrics

        if chosenMode == "guided" && lyricLines(from: referenceLyrics).isEmpty {
            isGenerating = false
            message = "Paste the correct lyrics or use lyrics found in the audio file first."
            return
        }

        Task {
            do {
                let clip = try await exportClip(from: localURL, start: clipStart, end: clipEnd)
                defer { try? FileManager.default.removeItem(at: clip) }
                let focusedAudio: URL?
                if chosenLanguage == "ta" {
                    processingStage = "1/2 · Vocal Focus: reducing music and boosting vocals"
                    message = "Layer 1 of 2: reducing music and strengthening centered vocals…"
                    await Task.yield()
                    focusedAudio = try makeVocalFocusedCopy(from: clip)
                } else {
                    focusedAudio = nil
                }
                defer { if let focusedAudio { try? FileManager.default.removeItem(at: focusedAudio) } }
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
                    wordTimestamps: true,
                    firstTokenLogProbThreshold: nil,
                    noSpeechThreshold: nil
                )
                let candidates = chosenLanguage == "ta" ? [clip, focusedAudio].compactMap { $0 } : [clip]
                var segments: [TranscriptionSegment] = []
                for (index, candidate) in candidates.enumerated() {
                    processingStage = index == 0
                        ? "2/2 · AI: listening to the original song"
                        : "2/2 · AI retry: listening to Vocal Focus audio"
                    message = index == 0
                        ? "Listening for sung \(chosenLanguage == "ta" ? "Tamil" : chosenLanguage == "en" ? "English" : "Tamil and English") lyrics without the speech-only cutoff…"
                        : "Retrying with music reduction and stronger vocals…"
                    let results = try await kit.transcribe(audioPath: candidate.path, decodeOptions: options)
                    let candidateSegments = results.flatMap(\.segments)
                    let candidateText = candidateSegments.map { cleanText($0.text) }.filter { !$0.isEmpty }.joined(separator: " ")
                    if !candidateText.isEmpty {
                        segments = candidateSegments
                        break
                    }
                }
                if chosenMode == "guided" {
                    processingStage = "Matching exact lyrics to detected word times"
                    let words = segments.compactMap { $0.words }.flatMap { $0 }
                    let aligned = try alignLyrics(referenceLyrics, to: words, offset: clipStart)
                    transcript = aligned.map(\.text).joined(separator: "\n")
                    reviewWords = makeGuidedReview(from: aligned)
                    srtURL = try writeAlignedSRT(aligned, bamini: false)
                    baminiSRTURL = try writeAlignedSRT(aligned, bamini: true)
                } else {
                    transcript = segments.map { cleanText($0.text) }.filter { !$0.isEmpty }.joined(separator: " ")
                    reviewWords = makeSongReview(from: segments, offset: clipStart)
                    srtURL = try writeSRT(segments: segments, offset: clipStart)
                }
                message = transcript.isEmpty ? "No clear lyrics were detected. Try a section with louder vocals." : "Draft complete. Edit the words if needed, then export the SRT."
                if !reviewWords.isEmpty {
                    seek(to: clipStart)
                    showReview = true
                }
            } catch {
                message = "Lyrics generation failed: \(error.localizedDescription)"
            }
            isGenerating = false
            processingStage = ""
        }
    }

    private func readEmbeddedLyrics(from url: URL) async {
        do {
            let asset = AVURLAsset(url: url)
            let metadata = try await asset.load(.commonMetadata)
            for item in metadata {
                let key = item.commonKey?.rawValue.lowercased() ?? ""
                let identifier = item.identifier?.rawValue.lowercased() ?? ""
                if key.contains("lyrics") || identifier.contains("lyrics"),
                   let value = try await item.load(.stringValue), !value.isEmpty {
                    embeddedLyrics = value
                    message = "Lyrics were found inside this audio file."
                    return
                }
            }
        } catch { }
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

    private struct AlignedLyric {
        let text: String
        let start: Double
        let end: Double
    }

    private func lyricLines(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !($0.hasPrefix("[") && $0.hasSuffix("]")) }
    }

    private func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).compactMap { part in
            let cleaned = String(part.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) })
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    private func wordScore(_ left: String, _ right: String) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        if min(left.count, right.count) >= 3 && (left.contains(right) || right.contains(left)) { return 0.7 }
        let a = Array(left), b = Array(right)
        var row = Array(0...b.count)
        for i in 1...a.count {
            var next = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                next[j] = min(next[j - 1] + 1, row[j] + 1, row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            row = next
        }
        return max(0, 1 - Double(row[b.count]) / Double(max(a.count, b.count, 1)))
    }

    private func alignLyrics(_ lyrics: String, to timings: [WordTiming], offset: Double) throws -> [AlignedLyric] {
        let lines = lyricLines(from: lyrics)
        let recognized = timings.map { normalizedWords($0.word).joined() }
        guard !lines.isEmpty, !timings.isEmpty, recognized.contains(where: { !$0.isEmpty }) else {
            throw NSError(domain: "LyricPocket", code: 5, userInfo: [NSLocalizedDescriptionKey: "Word timing anchors were not detected. Try a longer section with clear vocals."])
        }

        var bestLine = 0
        var bestScore = -1.0
        for (index, line) in lines.enumerated() {
            let candidates = normalizedWords(line)
            guard !candidates.isEmpty else { continue }
            let count = min(candidates.count, recognized.count)
            let score = (0..<count).map { wordScore(candidates[$0], recognized[$0]) }.reduce(0, +) / Double(count)
            if score > bestScore { bestScore = score; bestLine = index }
        }

        let available = Array(lines[bestLine...])
        var selected: [String] = []
        var lyricWordCount = 0
        for line in available {
            selected.append(line)
            lyricWordCount += max(1, normalizedWords(line).count)
            if lyricWordCount >= recognized.count { break }
        }
        guard !selected.isEmpty else { return [] }

        let totalWeights = selected.reduce(0) { $0 + max(1, normalizedWords($1).count) }
        var consumedWeight = 0
        var output: [AlignedLyric] = []
        for (index, line) in selected.enumerated() {
            let weight = max(1, normalizedWords(line).count)
            let startIndex = min(timings.count - 1, Int((Double(consumedWeight) / Double(totalWeights) * Double(timings.count)).rounded(.down)))
            consumedWeight += weight
            let nextIndex = min(timings.count, Int((Double(consumedWeight) / Double(totalWeights) * Double(timings.count)).rounded(.up)))
            let endIndex = max(startIndex, min(timings.count - 1, nextIndex - 1))
            let startTime = Double(timings[startIndex].start) + offset
            var endTime = Double(timings[endIndex].end) + offset
            if index + 1 < selected.count { endTime = max(endTime, startTime + 0.5) }
            output.append(AlignedLyric(text: line, start: startTime, end: endTime))
        }
        return output
    }

    private func writeAlignedSRT(_ lyrics: [AlignedLyric], bamini: Bool) throws -> URL {
        let body = lyrics.enumerated().map { index, lyric in
            let text = bamini ? unicodeToBamini(lyric.text) : lyric.text
            return "\(index + 1)\n\(srtTime(lyric.start)) --> \(srtTime(lyric.end))\n\(text)"
        }.joined(separator: "\n\n")
        let name = bamini ? "LyricPocket-Bamini.srt" : "LyricPocket-Unicode-Tamil.srt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeSongReview(from segments: [TranscriptionSegment], offset: Double) -> [ReviewWord] {
        segments.flatMap { segment -> [ReviewWord] in
            if let words = segment.words, !words.isEmpty {
                return words.compactMap { timing in
                    let text = cleanText(timing.word)
                    return text.isEmpty ? nil : ReviewWord(text: text, start: Double(timing.start) + offset, end: Double(timing.end) + offset)
                }
            }
            let words = cleanText(segment.text).split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !words.isEmpty else { return [] }
            let beginning = Double(segment.start) + offset
            let finish = Double(segment.end) + offset
            let step = max(0.05, (finish - beginning) / Double(words.count))
            return words.enumerated().map { index, word in
                ReviewWord(text: word, start: beginning + Double(index) * step, end: min(finish, beginning + Double(index + 1) * step))
            }
        }
    }

    private func makeGuidedReview(from lines: [AlignedLyric]) -> [ReviewWord] {
        lines.flatMap { line -> [ReviewWord] in
            let words = line.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !words.isEmpty else { return [] }
            let step = max(0.05, (line.end - line.start) / Double(words.count))
            return words.enumerated().map { index, word in
                ReviewWord(text: word, start: line.start + Double(index) * step, end: min(line.end, line.start + Double(index + 1) * step))
            }
        }
    }

    private func unicodeToBamini(_ input: String) -> String {
        var text = input.replacingOccurrences(of: "ஸ்ரீ", with: "=").replacingOccurrences(of: ",", with: ">")
        let bases: [(String, String, String, String)] = [
            ("ஜ","[","[{","[_"),("க","f","F","$"),("ங","q","*","*"),("ச","r","R","R+"),
            ("ஞ","Q","*","*"),("ட","l","L","^"),("ண","z","Z","Z}"),("த","j","J","J}"),
            ("ந","e","E","E}"),("ன","d","D","D}"),("ப","g","G","G+"),("ம","k","K","%"),
            ("ய","a","A","A+"),("ர","u","U","&"),("ல","y","Y","Y}"),("ள","s","S","Sh"),
            ("வ","t","T","T+"),("ழ","o","O","*"),("ற","w","W","W}"),("ஹ","`","{`","`_"),
            ("ஷ","\\","{","\\_"),("ஸ","]","]{","]_")
        ]
        for (letter, base, shortU, longU) in bases {
            let replacements: [(String, String)] = [
                (letter + "ௌ", "n" + base + "s"), (letter + "ோ", "N" + base + "h"),
                (letter + "ொ", "n" + base + "h"), (letter + "ா", base + "h"),
                (letter + "ி", letter == "ட" ? "b" : base + "p"),
                (letter + "ீ", letter == "ட" ? "B" : base + "P"),
                (letter + "ு", shortU), (letter + "ூ", longU),
                (letter + "ெ", "n" + base), (letter + "ே", "N" + base),
                (letter + "ை", "i" + base), (letter + "்", base + ";"), (letter, base)
            ]
            for (source, target) in replacements { text = text.replacingOccurrences(of: source, with: target) }
        }
        let vowels = [("அ","m"),("ஆ","M"),("இ",","),("ஈ","<"),("உ","c"),("ஊ","C"),("எ","v"),("ஏ","V"),("ஐ","I"),("ஒ","x"),("ஓ","X"),("ஔ","xs"),("ஃ","/")]
        for (source, target) in vowels { text = text.replacingOccurrences(of: source, with: target) }
        return text
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
                        AdvancedSelectionView(song: song, accent: accent)
                        Divider().padding(.vertical, 8)
                        Text("Generate lyrics").font(.title2.bold())
                        Picker("Song language", selection: $song.language) {
                            Text("Tamil").tag("ta")
                            Text("English").tag("en")
                            Text("Tamil + English").tag("auto")
                        }.pickerStyle(.segmented)
                        Picker("Generation mode", selection: $song.generationMode) {
                            Text("Song only").tag("song")
                            Text("Song + Lyrics").tag("guided")
                        }.pickerStyle(.segmented)
                        if song.generationMode == "guided" {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Correct lyrics").font(.headline)
                                if !song.embeddedLyrics.isEmpty {
                                    Button("Use lyrics found in this audio file", systemImage: "text.badge.checkmark") {
                                        song.suppliedLyrics = song.embeddedLyrics
                                    }.buttonStyle(.bordered)
                                }
                                TextEditor(text: $song.suppliedLyrics)
                                    .frame(minHeight: 180).padding(8)
                                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                Text("Paste the full lyrics or the lines for your selected section. Section labels such as [Chorus] are ignored.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if song.language == "ta" {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Vocal Focus active", systemImage: "waveform.badge.magnifyingglass")
                                    .font(.headline).foregroundStyle(accent)
                                Text("Music reduction → vocal boost → Tamil lyrics AI")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                        }
                        Text("The first run downloads about 626 MB over Wi-Fi. The model and your audio stay on this iPhone.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(song.isGenerating ? "Working…" : "Generate lyrics on iPhone", systemImage: "waveform.and.magnifyingglass") {
                            song.generateLyrics()
                        }
                        .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                        .disabled(song.isGenerating || song.end <= song.start)
                        if song.isGenerating {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView().tint(accent)
                                Text(song.processingStage).font(.footnote).foregroundStyle(accent)
                            }
                        }
                        if !song.transcript.isEmpty {
                            Button("Open timing review", systemImage: "text.word.spacing") {
                                song.seek(to: song.start)
                                song.showReview = true
                            }
                            .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                            Text("Editable lyric draft").font(.headline)
                            TextEditor(text: $song.transcript)
                                .frame(minHeight: 150).padding(8)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if let srtURL = song.srtURL {
                            ShareLink(item: srtURL) {
                                Label(song.generationMode == "guided" ? "Export Unicode Tamil SRT" : "Export SRT", systemImage: "square.and.arrow.up")
                            }.buttonStyle(.bordered)
                        }
                        if let baminiSRTURL = song.baminiSRTURL {
                            ShareLink(item: baminiSRTURL) {
                                Label("Export Bamini SRT", systemImage: "square.and.arrow.up")
                            }.buttonStyle(.bordered)
                            Text("The Bamini export requires the Bamini font in your video editor. Keep the Unicode SRT as your master copy.")
                                .font(.footnote).foregroundStyle(.secondary)
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
            .navigationDestination(isPresented: $song.showReview) {
                TimingReviewView(song: song, accent: accent)
            }
    }
}

struct AdvancedSelectionView: View {
    @ObservedObject var song: SongPlayer
    let accent: Color

    private func clock(_ value: Double) -> String {
        String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Select song section").font(.title3.bold())
                Spacer()
                Text("\(clock(song.end - song.start)) selected").font(.caption).foregroundStyle(accent)
            }
            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                let left = width * song.start / max(song.duration, 0.1)
                let right = width * song.end / max(song.duration, 0.1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12)).frame(height: 14)
                    Rectangle().fill(accent.opacity(0.8)).frame(width: max(2, right - left), height: 14).offset(x: left)
                    Rectangle().fill(.white).frame(width: 2, height: 22).offset(x: width * song.currentTime / max(song.duration, 0.1))
                }
            }.frame(height: 22)
            HStack {
                Text("00:00"); Spacer(); Text(clock(song.duration))
            }.font(.caption2).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("IN").font(.caption.bold()).foregroundStyle(accent); Spacer(); Text(clock(song.start)).monospacedDigit() }
                Slider(value: Binding(get: { song.start }, set: { song.setStart($0) }), in: 0...max(0.1, song.duration - 0.1), step: 0.05)
                HStack {
                    Button("−0.1") { song.setStart(song.start - 0.1) }
                    Button("+0.1") { song.setStart(song.start + 0.1) }
                    Spacer()
                    Button("Set IN here") { song.setStart(song.currentTime) }
                }.buttonStyle(.bordered).font(.caption)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("OUT").font(.caption.bold()).foregroundStyle(accent); Spacer(); Text(clock(song.end)).monospacedDigit() }
                Slider(value: Binding(get: { song.end }, set: { song.setEnd($0) }), in: 0...max(0.1, song.duration), step: 0.05)
                HStack {
                    Button("−0.1") { song.setEnd(song.end - 0.1) }
                    Button("+0.1") { song.setEnd(song.end + 0.1) }
                    Spacer()
                    Button("Set OUT here") { song.setEnd(song.currentTime) }
                }.buttonStyle(.bordered).font(.caption)
            }
            HStack {
                ForEach([15.0, 30.0, 60.0], id: \.self) { length in
                    Button("\(Int(length))s") { song.setEnd(min(song.duration, song.start + length)) }
                }
            }.buttonStyle(.bordered)
            HStack {
                Button(song.playing ? "Playing…" : "Play selection", systemImage: "play.fill") { song.play() }
                    .disabled(song.playing)
                Button("Pause", systemImage: "pause.fill") { song.stop() }.disabled(!song.playing)
                Button("Restart", systemImage: "backward.end.fill") { song.stop(); song.seek(to: song.start) }
            }.buttonStyle(.bordered)
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct TimingReviewView: View {
    @ObservedObject var song: SongPlayer
    let accent: Color

    private var activeIndex: Int? {
        song.reviewWords.firstIndex { song.currentTime >= $0.start && song.currentTime < $0.end }
    }

    private func clock(_ value: Double) -> String {
        String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(song.generationMode == "guided" ? "Aligned word timing review" : "Detected word timing review")
                        .font(.title2.bold())
                    Text(song.generationMode == "guided"
                         ? "The exact supplied lyrics are fitted inside the detected line times. Tap any word to check that point."
                         : "Each highlight follows the timestamp detected by the on-device model. Tap any word to seek to it.")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Text(clock(song.currentTime)).font(.title3.monospacedDigit())
                        Spacer()
                        Text("\(clock(song.start)) – \(clock(song.end))").font(.caption).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { song.currentTime }, set: { song.seek(to: $0) }), in: song.start...max(song.start + 0.1, song.end), step: 0.02)
                    HStack {
                        Button(song.playing ? "Playing…" : "Play", systemImage: "play.fill") { song.play() }.disabled(song.playing)
                        Button("Pause", systemImage: "pause.fill") { song.stop() }.disabled(!song.playing)
                        Button("Restart", systemImage: "backward.end.fill") { song.stop(); song.seek(to: song.start) }
                    }.buttonStyle(.bordered)
                    FlowLayout(spacing: 8) {
                        ForEach(Array(song.reviewWords.enumerated()), id: \.element.id) { index, word in
                            Button {
                                song.stop()
                                song.seek(to: word.start)
                            } label: {
                                VStack(spacing: 3) {
                                    Text(word.text).font(.title3.weight(index == activeIndex ? .bold : .regular))
                                    Text(clock(word.start)).font(.system(size: 9, design: .monospaced))
                                }
                                .padding(.horizontal, 9).padding(.vertical, 7)
                                .foregroundStyle(index == activeIndex ? Color.black : Color.white)
                                .background(index == activeIndex ? accent : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain).id(index)
                        }
                    }
                }.padding(24)
            }
            .onChange(of: activeIndex) { _, index in
                if let index { withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }
        .navigationTitle("Timing Review")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(red: 0.07, green: 0.11, blue: 0.10))
        .onDisappear { song.stop() }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}
