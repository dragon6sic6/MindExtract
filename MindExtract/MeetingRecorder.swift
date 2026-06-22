import Foundation
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import CoreAudio

// MARK: - Meeting recorder (fully on-device, no bot)
//
// Captures system audio (what other participants say) via ScreenCaptureKit plus
// the local microphone, fully on-device, and hands the result to the normal
// transcription pipeline. Requires macOS 15 (SCK microphone capture). v1 records
// to disk and transcribes after stopping; live text is a later addition.

@MainActor
final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()

    enum ErrorKind: Equatable { case screenPermission, micPermission, capture }

    enum State: Equatable {
        case idle
        case starting
        case recording
        case finishing
        case error(String, ErrorKind)
    }

    struct PendingRecording: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var title: String
        let duration: TimeInterval
        let dir: URL
        var notes: String = ""
    }

    @Published private(set) var state: State = .idle
    /// A finished recording awaiting the user's confirm/name/discard decision.
    @Published var pendingRecording: PendingRecording?
    @Published private(set) var elapsed: TimeInterval = 0
    /// 0…1 peak level for the meter (max of system + mic).
    @Published private(set) var level: Double = 0
    @Published private(set) var systemActive = false
    @Published private(set) var micActive = false
    // Reactive permission state so the UI updates when the user returns from
    // System Settings (the values are otherwise just point-in-time TCC checks).
    @Published private(set) var screenGranted = false
    @Published private(set) var micGranted = false

    /// Live transcript preview built during recording (when a model is available).
    let live = LiveTranscriber()
    private var liveLanguage = "auto"
    private var liveModel: WhisperModel?
    private var sessionTitle: String?   // from a calendar event, if started that way
    private var sessionAttendees: [String] = []   // calendar attendees → speaker-name suggestions
    /// Notes the user jots during the meeting — merged with the transcript by AI.
    @Published var liveNotes = ""

    var isRecording: Bool { if case .recording = state { return true }; return false }
    var isBusy: Bool {
        switch state { case .starting, .recording, .finishing: return true; default: return false }
    }

    /// True only where SCK can capture both system audio and the mic.
    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private var stream: SCStream?
    private var output: CaptureOutput?
    private var timer: Timer?
    private var startDate: Date?
    private var sessionDir: URL?
    private var lastDuration: TimeInterval = 0
    // Live config + a Core Audio listener so the mic follows the default device
    // when it changes mid-recording (AirPods connecting, etc.).
    private var streamConfig: SCStreamConfiguration?
    private var defaultInputBlock: AudioObjectPropertyListenerBlock?
    private let deviceListenerQueue = DispatchQueue(label: "com.mindact.recorder.devicelistener")
    private var deviceChangeWork: DispatchWorkItem?

    private init() {
        refreshPermissions()
        // Re-check when the user comes back from System Settings.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        // Sleep stops audio capture — finalize cleanly so a recording is never
        // left half-written across a sleep/wake cycle (observer runs on main;
        // stop() is synchronous). If sleep cuts finalization short, the movie
        // fragments + recoverInterruptedSessions() are the backstop.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
        }
    }

    /// Holds a process activity assertion for the duration of a recording so the
    /// app isn't suddenly terminated mid-write.
    private var recordingActivity: NSObjectProtocol?

    private func beginRecordingActivity() {
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Recording a meeting")
    }
    private func endRecordingActivity() {
        if let a = recordingActivity { ProcessInfo.processInfo.endActivity(a); recordingActivity = nil }
    }

    /// Bytes free on the record volume, or nil if the system won't report it
    /// (in which case we proceed rather than falsely block recording).
    private func freeDiskBytes() -> Int64? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Int64($0) }
    }

    // MARK: Mic device-change handling

    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func installDefaultInputListener() {
        guard defaultInputBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleMicReconfigure() }
        }
        defaultInputBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &Self.defaultInputAddress, deviceListenerQueue, block)
    }

    private func removeDefaultInputListener() {
        guard let block = defaultInputBlock else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &Self.defaultInputAddress, deviceListenerQueue, block)
        defaultInputBlock = nil
        deviceChangeWork?.cancel()
        deviceChangeWork = nil
    }

    /// Debounce — a single AirPods connect can fire several times and the HAL
    /// needs a moment to settle on the new default.
    private func scheduleMicReconfigure() {
        guard isRecording else { return }
        deviceChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.applyNewDefaultMic() }
        }
        deviceChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func applyNewDefaultMic() async {
        guard isRecording, let stream, let config = streamConfig else { return }
        guard #available(macOS 15.0, *) else { return }
        // resolvedMicUID() honors a user-pinned mic (and ignores system-default
        // changes while it's connected), else follows the system default.
        let newUID = resolvedMicUID()
        guard config.microphoneCaptureDeviceID != newUID else { return }   // no real change
        config.microphoneCaptureDeviceID = newUID
        do {
            try await stream.updateConfiguration(config)
        } catch {
            appLog("[MeetingRecorder] mic reconfigure failed: \(error)")
        }
    }

    /// The mic uniqueID to record with: the user's pinned device if set and still
    /// connected, otherwise the current macOS system default.
    private func resolvedMicUID() -> String? {
        let pref = AppSettings.shared.preferredMicrophoneID
        if !pref.isEmpty,
           Self.availableMicrophones().contains(where: { $0.uniqueID == pref }) {
            return pref
        }
        return AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    /// All input microphones, for the Settings picker. On macOS the built-in mic
    /// is `.microphone` and USB/Bluetooth/aggregate inputs are `.external` — both
    /// are needed or the list collapses to just the built-in device.
    static func availableMicrophones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio,
                                         position: .unspecified).devices
    }

    // MARK: Permissions

    func refreshPermissions() {
        screenGranted = CGPreflightScreenCaptureAccess()
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Screen Recording is required even for audio-only SCK capture.
    func hasScreenPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    func requestScreenPermission() { _ = CGRequestScreenCaptureAccess(); refreshPermissions() }

    func micAuthorization() -> AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    func requestMicPermission() async -> Bool {
        let ok = await AVCaptureDevice.requestAccess(for: .audio)
        refreshPermissions()
        return ok
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Lifecycle

    /// `language`/`liveModel` drive the live preview. If liveModel is nil or not
    /// downloaded, recording still works — there's just no live transcript.
    func start(language: String = "auto", liveModel: WhisperModel? = nil, meetingTitle: String? = nil, notesPrefill: String = "", attendees: [String] = []) {
        guard !isBusy else { return }
        guard #available(macOS 15.0, *) else {
            state = .error("Meeting recording requires macOS 15 or later.", .capture)
            return
        }
        self.liveLanguage = language
        self.liveModel = liveModel
        self.sessionTitle = meetingTitle
        self.sessionAttendees = attendees
        liveNotes = notesPrefill
        state = .starting
        level = 0
        Task { await startCapture() }
    }

    @available(macOS 15.0, *)
    private func startCapture() async {
        // Permissions first — fail clearly rather than silently recording silence.
        if !hasScreenPermission() {
            requestScreenPermission()
            state = .error("Screen Recording permission is needed to hear meeting audio. Grant it in System Settings, then try again.", .screenPermission)
            return
        }
        let micOK = await requestMicPermission()
        if !micOK {
            state = .error("Microphone permission is needed to record your voice. Grant it in System Settings, then try again.", .micPermission)
            return
        }

        // Don't start a recording we can't safely write — warn before, not after.
        // (If the volume won't report free space, proceed rather than block.)
        if let free = freeDiskBytes(), free < 500_000_000 {   // ~500 MB headroom
            state = .error("Not enough free disk space to record safely. Free up some space and try again.", .capture)
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                state = .error("No display available to capture audio from.", .capture)
                return
            }

            let dir = Self.makeSessionDir()
            sessionDir = dir
            let systemURL = dir.appendingPathComponent("system.m4a")
            let micURL = dir.appendingPathComponent("mic.m4a")

            let handler = CaptureOutput(systemURL: systemURL, micURL: micURL)
            handler.onError = { [weak self] message in
                Task { @MainActor in self?.failActiveRecording(message) }
            }
            handler.onLevel = { [weak self] lvl in
                Task { @MainActor in self?.level = lvl }
            }
            handler.onActive = { [weak self] isMic in
                Task { @MainActor in if isMic { self?.micActive = true } else { self?.systemActive = true } }
            }
            handler.live = live   // feed the live transcriber from the capture queues
            output = handler

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true   // don't record our own playback
            config.sampleRate = 48_000
            config.channelCount = 2
            config.captureMicrophone = true
            // Pin the mic to the user's chosen device, or the resolved current
            // default (nil resolves once and won't follow changes); the listener
            // updates it live when following the system default.
            config.microphoneCaptureDeviceID = resolvedMicUID()
            self.streamConfig = config
            // Audio-only: we still need a filter + minimal video we simply ignore.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: handler)
            // Register a .screen consumer too — an audio-only stream can stall on
            // some macOS builds without one; we just ignore the video frames.
            try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: handler.screenQueue)
            try stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: handler.systemQueue)
            try stream.addStreamOutput(handler, type: .microphone, sampleHandlerQueue: handler.micQueue)
            self.stream = stream

            try await stream.startCapture()

            beginRecordingActivity()
            installDefaultInputListener()
            // Live transcript preview, if we have a model for the chosen language.
            if let m = liveModel, let folder = TranscriptionManager.shared.resolvedModelFolder(for: m) {
                live.start(modelFolder: folder, language: liveLanguage)
            }
            startDate = Date()
            startTimer()
            state = .recording
        } catch {
            state = .error("Couldn't start recording: \(error.localizedDescription)", .capture)
            cleanupAfterFailure()
        }
    }

    func stop() {
        guard isRecording else { return }
        lastDuration = elapsed
        state = .finishing
        stopTimer()
        Task { await finishCapture() }
    }

    private func finishCapture() async {
        endRecordingActivity()
        removeDefaultInputListener()
        live.stop()
        // Stop delivery first so no late buffer hits a finishing writer.
        if let stream, let handler = output {
            try? stream.removeStreamOutput(handler, type: .screen)
            try? stream.removeStreamOutput(handler, type: .audio)
            if #available(macOS 15.0, *) { try? stream.removeStreamOutput(handler, type: .microphone) }
        }
        do {
            try await stream?.stopCapture()
        } catch {
            // Even if stopCapture errors, still finalize what we have.
            appLog("[MeetingRecorder] stopCapture error: \(error)")
        }
        stream = nil

        guard let handler = output, let dir = sessionDir else {
            state = .idle
            return
        }
        let title = sessionTitle ?? Self.recordingTitle(startDate ?? Date())
        await handler.finalize()
        output = nil

        // Combine system + mic into one file for transcription + archive.
        let mixed = dir.appendingPathComponent("\(Self.safeFileName(title)).m4a")
        let combined = await Self.combine(handler.writtenURLs(), offsets: handler.startOffsets(), into: mixed)

        state = .idle
        level = 0
        systemActive = false
        micActive = false

        guard let finalURL = combined else {
            state = .error("Recording saved, but couldn't be prepared for transcription.", .capture)
            return
        }
        // Don't auto-commit — let the user name it, transcribe, or discard. Their
        // meeting audio is theirs; nothing irreversible happens without a tap.
        pendingRecording = PendingRecording(url: finalURL, title: title, duration: lastDuration, dir: dir, notes: liveNotes)
    }

    /// Transcribe the pending recording with the chosen title, spoken language,
    /// and model. Language is explicit (Apple "auto" defaults to English); the
    /// model is passed through (e.g. KB-Whisper for Swedish) rather than read from
    /// the global default, which must not become a Swedish-only model.
    func confirmPending(title: String, language: String, model: WhisperModel) {
        guard let pending = pendingRecording else { return }
        pendingRecording = nil
        let name = title.trimmingCharacters(in: .whitespaces).isEmpty ? pending.title : title
        // Hand the user's live notes to the transcript so AI can merge them.
        let trimmedNotes = pending.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        TranscriptionManager.shared.pendingMeetingNotes = trimmedNotes.isEmpty ? nil : trimmedNotes
        // Hand the separate mic/system tracks for channel-aware "you vs them".
        let fm = FileManager.default
        let mic = pending.dir.appendingPathComponent("mic.m4a")
        let sys = pending.dir.appendingPathComponent("system.m4a")
        if fm.fileExists(atPath: mic.path), fm.fileExists(atPath: sys.path) {
            TranscriptionManager.shared.pendingChannelSources = (mic: mic.path, system: sys.path)
        }
        // Hand calendar attendees as speaker-name suggestions when renaming speakers.
        let suggestions = (["You"] + sessionAttendees)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        TranscriptionManager.shared.pendingSpeakerSuggestions = Array(NSOrderedSet(array: suggestions)) as? [String] ?? suggestions
        TranscriptionManager.shared.markPendingMeeting()
        TranscriptionManager.shared.startNewTranscription(title: name, source: .meeting)
        TranscriptionManager.shared.transcribe(
            videoPath: pending.url.path,
            model: model,
            outputFormat: AppSettings.shared.transcriptionOutputFormat,
            language: language
        )
    }

    /// Abandon an in-progress recording and delete its audio (used on "Discard &
    /// Quit" so nothing is left behind to prompt recovery next launch).
    func discardActiveRecording() {
        endRecordingActivity()
        removeDefaultInputListener()
        live.stop()
        stopTimer()
        let dir = sessionDir
        Task { try? await stream?.stopCapture() }
        stream = nil
        output = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
        sessionDir = nil
        state = .idle
    }

    /// Throw away the pending recording and its audio.
    func discardPending() {
        if let pending = pendingRecording {
            try? FileManager.default.removeItem(at: pending.dir)
        }
        pendingRecording = nil
    }

    private func failActiveRecording(_ message: String) {
        guard isRecording || state == .starting else { return }
        state = .finishing   // set synchronously so stop()/re-entry can't double-finalize
        endRecordingActivity()
        removeDefaultInputListener()
        live.stop()
        stopTimer()
        Task {
            if let stream, let handler = output {
                try? stream.removeStreamOutput(handler, type: .screen)
                try? stream.removeStreamOutput(handler, type: .audio)
                if #available(macOS 15.0, *) { try? stream.removeStreamOutput(handler, type: .microphone) }
            }
            try? await stream?.stopCapture()
            stream = nil
            await output?.finalize()
            output = nil
            state = .error(message, .capture)
            level = 0
            systemActive = false
            micActive = false
        }
    }

    private func cleanupAfterFailure() {
        endRecordingActivity()
        removeDefaultInputListener()
        stopTimer()
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
        output = nil
    }

    func dismissError() { if case .error = state { state = .idle } }

    // MARK: Timer / level

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil; elapsed = 0; startDate = nil }

    // MARK: Helpers

    private static var recordingsBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mindact.mindextract/Recordings", isDirectory: true)
    }

    private static func makeSessionDir() -> URL {
        let dir = recordingsBase.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Find a recording interrupted by a crash/force-quit (source files present
    /// but never combined) and offer to recover it — combine + present the confirm
    /// sheet, reusing the normal name/transcribe/discard flow.
    func recoverInterruptedSessions() {
        guard !isBusy, pendingRecording == nil else { return }
        Task { @MainActor in
            // Re-check after the async hop — a recording may have just started.
            guard !self.isBusy, self.pendingRecording == nil else { return }
            let activeDir = self.sessionDir
            let fm = FileManager.default
            guard let dirs = try? fm.contentsOfDirectory(at: Self.recordingsBase, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            for dir in dirs {
                if let active = activeDir, dir.path == active.path { continue }   // never touch the live session
                let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                if files.contains(".recovery-failed") { continue }               // already known-bad
                let sources = ["system.m4a", "mic.m4a"].map { dir.appendingPathComponent($0) }
                    .filter { fm.fileExists(atPath: $0.path) }
                // A non-empty combined file means this session is already done.
                let hasCombined = files.contains {
                    $0.hasSuffix(".m4a") && $0 != "system.m4a" && $0 != "mic.m4a" &&
                    ((try? dir.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 100_000
                }
                guard !sources.isEmpty, !hasCombined else { continue }

                let mixed = dir.appendingPathComponent("Recovered.m4a")
                let combined = await Self.combineWithTimeout(sources, into: mixed)
                guard let combined else {
                    // Truly corrupt — mark so we don't re-attempt every launch.
                    try? "".write(to: dir.appendingPathComponent(".recovery-failed"), atomically: true, encoding: .utf8)
                    continue
                }
                let rawDur = (try? await AVURLAsset(url: combined).load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
                let dur = rawDur.isFinite ? rawDur : 0
                let modDate = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                guard !self.isBusy, self.pendingRecording == nil else { return }
                pendingRecording = PendingRecording(url: combined,
                                                    title: "Recovered " + Self.recordingTitle(modDate),
                                                    duration: dur, dir: dir)
                return   // one at a time
            }
        }
    }

    /// combine() with a 30s ceiling so a corrupt input can't hang recovery forever.
    private static func combineWithTimeout(_ urls: [URL], into output: URL) async -> URL? {
        await withTaskGroup(of: URL?.self) { group in
            group.addTask { await combine(urls, offsets: [:], into: output) }
            group.addTask { try? await Task.sleep(nanoseconds: 30_000_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func recordingTitle(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm"
        return "Meeting \(df.string(from: date))"
    }

    private static func safeFileName(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
    }

    /// Mix the captured tracks (system + mic) into a single m4a via AVFoundation,
    /// aligning each track to its real start offset so "me" and "them" stay in
    /// sync. Deletes the intermediate source files on success. Returns nil on
    /// failure.
    private static func combine(_ urls: [URL], offsets: [URL: CMTime], into output: URL) async -> URL? {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }
        // A single source needs no mixing.
        if existing.count == 1 {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.moveItem(at: existing[0], to: output)
            return FileManager.default.fileExists(atPath: output.path) ? output : existing[0]
        }
        // Earliest start becomes t=0; each track is placed at its relative offset.
        let minPTS = offsets.values.min { $0 < $1 } ?? .zero
        let composition = AVMutableComposition()
        for url in existing {
            let asset = AVURLAsset(url: url)
            guard let src = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration),
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let at = (offsets[url].map { CMTimeSubtract($0, minPTS) } ?? .zero)
            let safeAt = (at >= .zero) ? at : .zero
            try? track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: src, at: safeAt)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            return existing.first
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else { return existing.first }
        // Keep the per-source files (mic/system) — the transcription step uses
        // them for channel-aware "you vs them" attribution, then deletes them.
        return output
    }
}

// MARK: - Capture output (runs on SCK delivery queues)

/// Receives audio buffers from ScreenCaptureKit on background queues and writes
/// system + mic to separate files. Kept off the main actor; the audio queues do
/// only lightweight work (append + cheap level calc).
private final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let systemQueue = DispatchQueue(label: "com.mindact.recorder.system")
    let micQueue = DispatchQueue(label: "com.mindact.recorder.mic")
    let screenQueue = DispatchQueue(label: "com.mindact.recorder.screen")

    var onError: (@Sendable (String) -> Void)?
    var onLevel: (@Sendable (Double) -> Void)?
    var onActive: (@Sendable (Bool) -> Void)?   // true = mic became active
    var live: LiveTranscriber?                  // fed live for the in-meeting preview (strong: no cycle; owned by MeetingRecorder)

    private let systemURL: URL
    private let micURL: URL

    // All writer state below is touched ONLY on its own serial queue
    // (systemQueue / micQueue), never from the main actor — no shared races.
    private var systemWriter: AVAssetWriter?
    private var systemInput: AVAssetWriterInput?
    private var micWriter: AVAssetWriter?
    private var micInput: AVAssetWriterInput?
    private var systemStopped = false   // systemQueue only
    private var micStopped = false      // micQueue only
    // First presentation timestamps, to align the two tracks when mixing.
    private(set) var firstSystemPTS: CMTime?
    private(set) var firstMicPTS: CMTime?

    init(systemURL: URL, micURL: URL) {
        self.systemURL = systemURL
        self.micURL = micURL
    }

    /// Files that actually got data — checked by existence on disk (race-free).
    func writtenURLs() -> [URL] {
        [systemURL, micURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Each written file's first presentation timestamp, for mix alignment.
    func startOffsets() -> [URL: CMTime] {
        var map: [URL: CMTime] = [:]
        if let p = firstSystemPTS { map[systemURL] = p }
        if let p = firstMicPTS { map[micURL] = p }
        return map
    }

    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if type == .audio {
            appendSystem(sampleBuffer)
        } else if #available(macOS 15.0, *), type == .microphone {
            appendMic(sampleBuffer)
        }
        // .screen (video) is intentionally ignored in audio-only capture.
    }

    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("Recording stopped: \(error.localizedDescription)")
    }

    private func appendSystem(_ sb: CMSampleBuffer) {
        if systemStopped { return }
        if systemWriter == nil {
            guard let (w, i) = Self.makeWriter(url: systemURL, formatHint: CMSampleBufferGetFormatDescription(sb)) else {
                onError?("Couldn't create the system-audio file."); return
            }
            systemWriter = w; systemInput = i
            w.startWriting()
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            w.startSession(atSourceTime: pts)
            firstSystemPTS = pts
            onActive?(false)
        }
        guard let input = systemInput, let w = systemWriter else { return }
        if w.status == .failed {
            systemStopped = true
            onError?("Audio write error: \(w.error?.localizedDescription ?? "unknown")")
            return
        }
        if input.isReadyForMoreMediaData, w.status == .writing {
            input.append(sb)
            reportLevel(sb)
        }
        live?.appendSystemBuffer(sb)
    }

    private func appendMic(_ sb: CMSampleBuffer) {
        if micStopped { return }
        if micWriter == nil {
            guard let (w, i) = Self.makeWriter(url: micURL, formatHint: CMSampleBufferGetFormatDescription(sb)) else {
                onError?("Couldn't create the microphone file."); return
            }
            micWriter = w; micInput = i
            w.startWriting()
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            w.startSession(atSourceTime: pts)
            firstMicPTS = pts
            onActive?(true)
        }
        guard let input = micInput, let w = micWriter else { return }
        if w.status == .failed { micStopped = true; return }
        if input.isReadyForMoreMediaData, w.status == .writing {
            input.append(sb)
        }
        live?.appendMicBuffer(sb)
    }

    private static func makeWriter(url: URL, formatHint: CMFormatDescription?) -> (AVAssetWriter, AVAssetWriterInput)? {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .m4a) else { return nil }
        var channels = 2
        if let fmt = formatHint, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
            channels = max(1, Int(asbd.pointee.mChannelsPerFrame))
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        // Movie fragments → a crash leaves a file playable up to the last flush.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        return (writer, input)
    }

    /// Cheap peak level for the UI meter — only when the buffer really is
    /// interleaved Float32 LPCM (otherwise skip rather than misread memory).
    private func reportLevel(_ sb: CMSampleBuffer) {
        guard onLevel != nil else { return }
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              asbd.mBitsPerChannel == 32 else { return }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var lengthAtOffset = 0, totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let ptr = dataPointer, totalLength >= MemoryLayout<Float>.size else { return }
        let count = totalLength / MemoryLayout<Float>.size
        // Compute the peak INSIDE the scoped rebind — the pointer must not escape.
        let peak = ptr.withMemoryRebound(to: Float.self, capacity: count) { floats -> Float in
            var p: Float = 0
            let step = max(1, count / 256)
            var i = 0
            while i < count { p = max(p, abs(floats[i])); i += step }
            return p
        }
        onLevel?(Double(min(1, peak)))
    }

    func finalize() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            systemQueue.async { [self] in
                systemStopped = true
                if let w = systemWriter, let i = systemInput, w.status == .writing {
                    i.markAsFinished(); w.finishWriting { group.leave() }
                } else { group.leave() }
            }
            group.enter()
            micQueue.async { [self] in
                micStopped = true
                if let w = micWriter, let i = micInput, w.status == .writing {
                    i.markAsFinished(); w.finishWriting { group.leave() }
                } else { group.leave() }
            }
            group.notify(queue: .main) { cont.resume() }
        }
    }
}
