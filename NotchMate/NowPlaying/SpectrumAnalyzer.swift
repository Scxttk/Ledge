import Accelerate
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import QuartzCore

/// Real-time frequency visualizer data. Taps the system audio output with a
/// CoreAudio process tap (macOS 14.4+, needs the audio-recording permission),
/// runs an FFT over it and exposes a handful of log-spaced frequency bands so
/// the now-playing wave reacts to the actual song. On older systems, or if the
/// permission is denied / the tap fails, `bands` stays flat and the visualizer
/// falls back to its procedural animation.
final class SpectrumAnalyzer: ObservableObject {
    /// Normalised per-band magnitudes (0…1), published on the main thread.
    @Published private(set) var bands: [CGFloat]
    /// True once a tap is actually running and feeding real data.
    @Published private(set) var isLive = false
    /// True while the tapped signal actually carries audible content — not just
    /// whether the tap is running. This is what drives "is something playing"
    /// for sources with no scriptable now-playing state (browser video, calls,
    /// system sounds, …): CoreAudio's own per-process "is running output" API
    /// turned out to be unreliable in practice (some helper processes report it
    /// permanently true; short-lived ones can flip true and false again before
    /// a listener callback ever fires), so this reads the real signal the tap
    /// already has instead of trusting that heuristic. Held true for a couple
    /// of seconds after the signal drops so brief gaps (between songs, a pause
    /// in speech) don't flicker the hero pill.
    @Published private(set) var hasSignal = false
    private var lastSignalTime: CFTimeInterval = 0
    private static let signalHoldSeconds: CFTimeInterval = 2.0
    private static let signalThreshold: Float = 0.08

    /// Bundle ID of whichever app currently has an active output stream, so the
    /// collapsed pill can show its icon instead of a generic glyph when there's
    /// no scriptable track. Refreshed on a plain 1s poll (not a CoreAudio
    /// property listener) while the tap is running — a poll is simpler and, for
    /// this cosmetic purpose, more than fast enough; see `hasSignal`'s doc for
    /// why the listener-based equivalent proved unreliable for the on/off signal.
    @Published private(set) var sourceBundleID: String?
    private var sourceCheckTimer: DispatchSourceTimer?

    let bandCount: Int

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false
    private var sampleRate: Double = 48_000

    // Rebuilds the tap when the user switches output device (e.g. AirPods
    // in/out): the aggregate can otherwise keep feeding silent samples forever.
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var pendingRebuild: DispatchWorkItem?
    private var deviceChangeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // FFT scratch (all preallocated — nothing is allocated on the audio thread).
    private let fftSize = 1_024
    private let log2n: vDSP_Length
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var sampleBuffer: [Float]      // sliding window of the last fftSize mono samples
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]
    private var smoothed: [Float]          // per-band, with attack/decay
    private var lastPublish = 0.0
    // The dB window used to be a fixed absolute range (30…52, then 47, then
    // 40 dB), retuned three times and still wrong: measuring real playback
    // showed two ordinary tracks can differ in absolute loudness by ~20 dB
    // (mastering level, not "quiet vs busy" within a song). A fixed window
    // can't serve both — either it clips a loud track to the ceiling almost
    // immediately, or a quiet track never clears the floor. So the window
    // now floats: `loudnessCeilDb` tracks the loudest thing currently
    // playing (fast attack, slow release — like a VU meter's peak hold) and
    // the dB→0…1 mapping always uses a fixed-width slice directly below it,
    // so each track's own dynamic range gets used regardless of its overall
    // loudness.
    private var loudnessCeilDb: Float = 40   // seeded at the old static ceiling so the first second isn't blank
    private static let loudnessAttack: Float = 0.5        // fraction of the way to a new peak, per callback
    private static let loudnessReleasePerSecond: Float = 6 // dB/s the ceiling falls once the signal quiets down
    private static let loudnessCeilMin: Float = 10          // never let a silent stretch collapse the window
    private static let windowWidthDb: Float = 26
    // Higher bands carry ~20 dB less energy than the bass; lift them (curved so
    // the low bands stay put) to keep every bar in the same visible range.
    private static let highBandBoost: Float = 20

    // Beat emphasis. The absolute window above answers "how loud is this band
    // right now" — which for heavily compressed, loudness-normalized music
    // (Spotify pins everything near -14 LUFS and modern masters have a few dB
    // of short-term movement at best) means the bars find their static
    // positions and just stand there, while dynamic material (a YouTube video,
    // speech) dances. So each band also tracks its own recent average, and the
    // published level leans mostly on the *deviation* from that average: a
    // kick 6 dB over its band's norm hits the top no matter how compressed
    // the master is, and the absolute term underneath keeps bass reading
    // taller than treble.
    private var averageDb: [Float]
    private var averageSeeded = false
    /// Seconds for a band's running average to absorb a level change.
    private static let averageTau: Float = 1.6
    /// Where "exactly average" sits (offset/range ≈ 0.39) and how many dB a
    /// beat needs above its band's norm to reach the top. Voice gets its
    /// drama for free — pauses swing every band from zero to full — while
    /// music holds energy continuously, so between beats a band sits exactly
    /// at its average: this resting point *is* the trough depth. Kept low and
    /// the window narrow so sustained music still breathes visibly.
    private static let beatOffsetDb: Float = 3.5
    private static let beatRangeDb: Float = 9
    /// Mix of deviation-from-average vs absolute level in the published bar.
    private static let beatWeight: Float = 0.72

    private let queue = DispatchQueue(label: "com.scott.notchmate.spectrum", qos: .userInitiated)

    init(bandCount: Int = 6) {
        self.bandCount = bandCount
        self.bands = Array(repeating: 0, count: bandCount)
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.window = [Float](repeating: 0, count: fftSize)
        self.sampleBuffer = [Float](repeating: 0, count: fftSize)
        self.windowed = [Float](repeating: 0, count: fftSize)
        self.realp = [Float](repeating: 0, count: fftSize / 2)
        self.imagp = [Float](repeating: 0, count: fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: fftSize / 2)
        self.smoothed = [Float](repeating: 0, count: bandCount)
        self.averageDb = [Float](repeating: 0, count: bandCount)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    }

    deinit {
        // Tear down CoreAudio synchronously only — no DispatchQueue.main.async
        // here: capturing `self` from deinit resurrects a deallocating object
        // and traps (that was the SIGABRT).
        teardown()
        unregisterDeviceChangeListener()
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        guard #available(macOS 14.4, *) else { return }   // process taps are 14.4+

        // 1. A private global tap of the system output — observes what's playing
        //    without muting it or changing the user's output device.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr, tap != 0 else { return }
        tapID = tap

        guard let tapUID = stringProperty(tapID, kAudioTapPropertyUID) else { stop(); return }
        sampleRate = tapFormat(tapID)?.mSampleRate ?? 48_000

        // 2. A private aggregate device that contains the tap, so we can install
        //    an IOProc and receive the tapped audio.
        let aggUID = UUID().uuidString
        let sub: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true,
        ]
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchMate Spectrum",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [sub],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var agg: AudioObjectID = 0
        guard AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &agg) == noErr, agg != 0 else {
            stop(); return
        }
        aggregateID = agg

        // 3. Receive audio on our own queue and analyse it.
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, inInputData, _, _, _ in
            self?.process(inInputData)
        }
        guard status == noErr, let proc else { stop(); return }
        ioProcID = proc
        guard AudioDeviceStart(aggregateID, proc) == noErr else { stop(); return }

        running = true
        registerDeviceChangeListener()
        startSourceCheckTimer()
        DispatchQueue.main.async { self.isLive = true }
    }

    func stop() {
        let wasRunning = aggregateID != 0 || tapID != 0
        pendingRebuild?.cancel()
        pendingRebuild = nil
        teardown()
        unregisterDeviceChangeListener()
        stopSourceCheckTimer()
        guard wasRunning else { return }
        // Reset published state on the main thread — weak so a pending block can
        // never resurrect a deallocating instance.
        lastSignalTime = 0
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isLive = false
            self.hasSignal = false
            self.sourceBundleID = nil
            self.bands = Array(repeating: 0, count: self.bandCount)
        }
    }

    /// Synchronous CoreAudio teardown, safe to call from `deinit`.
    private func teardown() {
        running = false
        if aggregateID != 0, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        // The tap only ever gets created on 14.4+ (see start), so this is only
        // reachable there; the guard is just for the compiler.
        if tapID != 0, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = 0
        for i in smoothed.indices { smoothed[i] = 0 }
    }

    // MARK: - Device change handling

    private func registerDeviceChangeListener() {
        guard deviceChangeListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuildForDeviceChange()
        }
        deviceChangeListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceChangeAddress, queue, block)
    }

    private func unregisterDeviceChangeListener() {
        guard let block = deviceChangeListener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceChangeAddress, queue, block)
        deviceChangeListener = nil
    }

    /// The default output device changed (e.g. AirPods connected/disconnected).
    /// The existing aggregate can silently keep feeding zero samples, so this
    /// does a full teardown + rebuild of the tap and aggregate rather than just
    /// restarting the IOProc.
    ///
    /// The listener fires on `queue` — the same queue the IOProc dispatches to.
    /// Tearing the IOProc down from its own queue deadlocks the HAL
    /// (`AudioDeviceDestroyIOProcID` waits synchronously for in-flight IO
    /// blocks), so hop to the main thread, where `start`/`stop` already run.
    /// A device switch also fires the notification several times in a burst
    /// while routing settles, so debounce before rebuilding.
    private func rebuildForDeviceChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRebuild?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.running else { return }
                self.teardown()
                self.start()
            }
            self.pendingRebuild = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    // MARK: - Audio thread

    /// Runs on `queue`. Pulls channel 0, slides it into the analysis window, and
    /// recomputes the bands.
    private func process(_ bufferList: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = abl.first, let raw = first.mData else { return }
        let channels = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
        guard frames > 0 else { return }
        let ptr = raw.bindMemory(to: Float.self, capacity: frames * channels)

        // Slide the window and append the newest frames (channel 0).
        if frames >= fftSize {
            for i in 0..<fftSize { sampleBuffer[i] = ptr[(frames - fftSize + i) * channels] }
        } else {
            let keep = fftSize - frames
            for i in 0..<keep { sampleBuffer[i] = sampleBuffer[i + frames] }
            for i in 0..<frames { sampleBuffer[keep + i] = ptr[i * channels] }
        }

        computeBands(audioDt: Float(Double(frames) / sampleRate))
        publishIfDue()
    }

    #if DEBUG
    /// Test entry: slides mono `samples` into the analysis window and runs the
    /// same band computation the tap drives, returning the smoothed levels.
    /// Exists because the dB→bar mapping is exactly the part that regressed
    /// silently once before (bars standing still on compressed masters) — a
    /// test can feed synthetic "music" through the real FFT path and measure
    /// whether the bars actually move.
    func ingestForTesting(_ samples: [Float]) -> [Float] {
        if samples.count >= fftSize {
            for i in 0..<fftSize { sampleBuffer[i] = samples[samples.count - fftSize + i] }
        } else {
            let keep = fftSize - samples.count
            for i in 0..<keep { sampleBuffer[i] = sampleBuffer[i + samples.count] }
            for i in 0..<samples.count { sampleBuffer[keep + i] = samples[i] }
        }
        computeBands(audioDt: Float(Double(samples.count) / 48_000))
        return smoothed
    }
    #endif

    /// `audioDt`: duration of the audio this callback delivered. The window
    /// release and the running averages tick on *audio* time, not the wall
    /// clock — in production the two coincide (the tap delivers in real time),
    /// but audio time is deterministic under callback jitter and lets tests
    /// feed audio faster than real time without freezing the time constants.
    private func computeBands(audioDt: Float) {
        guard let fftSetup else { return }
        vDSP_vmul(sampleBuffer, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    raw.bindMemory(to: DSPComplex.self).baseAddress.map {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Log-spaced bands from 40 Hz to ~16 kHz (or Nyquist).
        let fMin = 40.0
        let fMax = min(16_000.0, sampleRate / 2)
        let binHz = sampleRate / Double(fftSize)
        // Snappier than before (was 0.6/0.82) — quicker to jump on a transient
        // and quicker to fall back between beats, so the bars visibly punch
        // instead of gliding: more the iPhone's twitchy read, less a slow wave.
        let attack: Float = 0.78     // how fast bars rise toward a new peak
        let decay: Float = 0.7       // how fast they fall

        var rawDb = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let lo = fMin * pow(fMax / fMin, Double(b) / Double(bandCount))
            let hi = fMin * pow(fMax / fMin, Double(b + 1) / Double(bandCount))
            let loBin = max(1, Int(lo / binHz))
            let hiBin = min(fftSize / 2 - 1, max(loBin, Int(hi / binHz)))
            var peak: Float = 0
            for bin in loBin...hiBin { peak = max(peak, magnitudes[bin]) }
            rawDb[b] = 20 * log10(peak + 1e-6)
        }

        // Slide the window to follow the loudest band this callback: fast
        // attack so a track coming in loud doesn't take seconds to stop
        // clipping, slow release so it doesn't chase every quiet beat within
        // a song — only settles down once the track itself has been quieter
        // for a couple of seconds.
        let dt = audioDt
        let framePeakDb = rawDb.max() ?? loudnessCeilDb
        if framePeakDb > loudnessCeilDb {
            loudnessCeilDb += (framePeakDb - loudnessCeilDb) * Self.loudnessAttack
        } else {
            loudnessCeilDb -= Self.loudnessReleasePerSecond * dt
        }
        loudnessCeilDb = max(Self.loudnessCeilMin, loudnessCeilDb)
        let floorDb = loudnessCeilDb - Self.windowWidthDb

        // Fraction of the way each band's running average moves toward the
        // current frame — time-based so the tau holds at any callback rate.
        let averageAlpha = dt > 0 ? min(1, dt / Self.averageTau) : 1

        for b in 0..<bandCount {
            // Higher bands carry ~20 dB less energy, so lift them (measured)
            // to keep every bar in the same visible range instead of pinned low.
            let boost = Self.highBandBoost * pow(Float(b) / Float(max(1, bandCount - 1)), 1.5)
            let boosted = rawDb[b] + boost

            if !averageSeeded { averageDb[b] = boosted }
            averageDb[b] += (boosted - averageDb[b]) * averageAlpha

            // Two readings blended: the absolute level inside the floating
            // window (keeps bass taller than treble, quiet passages low), and
            // the deviation from this band's own recent average (makes every
            // beat punch, however compressed the master — see `beatWeight`).
            let absolute = min(1, max(0, (boosted - floorDb) / Self.windowWidthDb))
            let beat = min(1, max(0, (boosted - averageDb[b] + Self.beatOffsetDb) / Self.beatRangeDb))
            // In silence a band sits exactly at its own average, which the
            // beat term would read as a healthy mid-level bar (and hold
            // `hasSignal` open forever). Gate it on audibility: inaudible in
            // absolute terms → no beat contribution either.
            let gate = min(1, absolute * 12)
            let level = gate * (Self.beatWeight * beat + (1 - Self.beatWeight) * absolute)
            smoothed[b] = level > smoothed[b]
                ? smoothed[b] + (level - smoothed[b]) * attack
                : smoothed[b] * decay
        }
        averageSeeded = true
        if smoothed.contains(where: { $0 > Self.signalThreshold }) {
            lastSignalTime = CACurrentMediaTime()
        }
    }

    /// Blend each band a little with its neighbours (simple 3-tap kernel, edges
    /// replicated) so the published shape reads as one continuous curve instead
    /// of `bandCount` independent, jumpy bars — with only 6 bands, one loud
    /// isolated bin next to two quiet ones looked noisy rather than musical.
    /// (A lighter 15/70/15 variant was tried briefly to bring back more
    /// between-bar contrast, but that was diagnosed against a tap that had
    /// Safari/Twitch audio mixed in with Spotify at the same time — revert to
    /// even 25/50/25 until re-checked against a clean single source.)
    /// Applied only at publish time, on a copy: `smoothed` itself keeps its
    /// unblended per-band values for the attack/decay recursion above, so this
    /// can't compound blur into itself frame over frame.
    private func spatiallySmoothed(_ source: [Float]) -> [Float] {
        guard source.count > 2 else { return source }
        return source.indices.map { i in
            let prev = source[max(0, i - 1)]
            let next = source[min(source.count - 1, i + 1)]
            return (prev + 2 * source[i] + next) / 4
        }
    }

    /// Publish to SwiftUI at ~30 fps regardless of the (faster) audio callback.
    private func publishIfDue() {
        let now = CACurrentMediaTime()
        guard now - lastPublish >= 1.0 / 30 else { return }
        lastPublish = now
        let snapshot = spatiallySmoothed(smoothed).map { CGFloat($0) }
        let signalNow = now - lastSignalTime < Self.signalHoldSeconds
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bands = snapshot
            if self.hasSignal != signalNow { self.hasSignal = signalNow }
        }
    }

    // MARK: - CoreAudio property helpers

    private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value as String?
    }

    private func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr else { return nil }
        return asbd
    }

    // MARK: - Source app identification

    private func startSourceCheckTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.refreshSourceBundleID() }
        timer.resume()
        sourceCheckTimer = timer
    }

    private func stopSourceCheckTimer() {
        sourceCheckTimer?.cancel()
        sourceCheckTimer = nil
    }

    /// Scans every process with an active output stream and picks the first
    /// one that isn't us, so the collapsed pill can show its icon. Runs on
    /// `queue`, once a second — see `sourceBundleID`'s doc for why a plain poll
    /// beats a CoreAudio property listener here.
    private func refreshSourceBundleID() {
        let ownBundleID = Bundle.main.bundleIdentifier
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else {
            publish(sourceBundleID: nil)
            return
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processes = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes) == noErr else {
            publish(sourceBundleID: nil)
            return
        }

        var isRunningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for process in processes {
            var isRunning: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(process, &isRunningAddress, 0, nil, &runningSize, &isRunning) == noErr,
                  isRunning != 0 else { continue }
            guard let bundleID = stringProperty(process, kAudioProcessPropertyBundleID), bundleID != ownBundleID else { continue }
            publish(sourceBundleID: Self.attributedBundleID(for: bundleID))
            return
        }
        publish(sourceBundleID: nil)
    }

    /// WebKit's audio/GPU XPC helpers (e.g. `com.apple.WebKit.GPU`) are what
    /// CoreAudio actually reports as the running process for any WebKit-based
    /// browser tab — they're spawned on demand and re-parented to `launchd`,
    /// so there's no reliable way back to the tab's own app. Safari is by far
    /// the common case, so attribute these to Safari rather than showing no
    /// icon at all.
    private static func attributedBundleID(for bundleID: String) -> String {
        bundleID.hasPrefix("com.apple.WebKit") ? "com.apple.Safari" : bundleID
    }

    private func publish(sourceBundleID id: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sourceBundleID != id else { return }
            self.sourceBundleID = id
        }
    }
}
