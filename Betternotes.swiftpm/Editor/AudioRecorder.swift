import AVFoundation
import SwiftUI

/// Audio notes for a notebook: record to attachments/, list and play back.
@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var playing: UUID?
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var currentFile: String?
    private var started = Date()

    /// Starts recording into the notebook; returns false if the microphone is not allowed.
    func start(in doc: NoteDocument, store: DocumentStore) async -> Bool {
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard allowed else { return false }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
        let name = "rec-\(UUID().uuidString).m4a"
        let url = store.attachmentURL(name, in: doc)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                                       AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        guard let r = try? AVAudioRecorder(url: url, settings: settings), r.record() else { return false }
        recorder = r
        currentFile = name
        started = Date()
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.started)
            }
        }
        return true
    }

    /// Stops and returns the finished recording entry.
    func stop() -> Recording? {
        guard let r = recorder, let file = currentFile else { return nil }
        r.stop()
        timer?.invalidate()
        isRecording = false
        recorder = nil
        currentFile = nil
        return Recording(file: file, date: started, duration: Date().timeIntervalSince(started))
    }

    func togglePlay(_ rec: Recording, in doc: NoteDocument, store: DocumentStore) {
        if playing == rec.id {
            player?.stop()
            playing = nil
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player = try? AVAudioPlayer(contentsOf: store.attachmentURL(rec.file, in: doc))
        player?.delegate = self
        player?.play()
        playing = player == nil ? nil : rec.id
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = nil }
    }
}

struct RecordingsView: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var recorder: AudioRecorder
    let doc: NoteDocument

    var body: some View {
        List {
            if doc.recordings.isEmpty {
                Text("Noch keine Aufnahmen. Mit dem Mikrofon-Knopf starten.").foregroundStyle(.secondary)
            }
            ForEach(doc.recordings) { rec in
                Button { recorder.togglePlay(rec, in: doc, store: store) } label: {
                    HStack {
                        Image(systemName: recorder.playing == rec.id ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title2)
                        VStack(alignment: .leading) {
                            Text(rec.date.formatted(date: .abbreviated, time: .shortened))
                            Text(Duration.seconds(rec.duration).formatted(.time(pattern: .minuteSecond)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("Löschen", role: .destructive) {
                        try? FileManager.default.removeItem(at: store.attachmentURL(rec.file, in: doc))
                        store.update(doc.id) { $0.recordings.removeAll { $0.id == rec.id } }
                    }
                }
            }
        }
        .frame(minWidth: 320, minHeight: 280)
    }
}
