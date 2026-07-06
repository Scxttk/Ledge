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

    let bandCount: Int

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false
    private var sampleRate: Double = 48_000

    // Rebuilds the tap when the user switches output device (e.g. AirPods
    // in/out): the aggregate can otherwise keep feeding silent samples forever.
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
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
    // dB window mapped to 0…1 (level-meter style). Tuned from measured output:
    // typical music sits ~0.4–0.6 with headroom for beats, so bars visibly move.
    private static let dbFloor: Float = 30
    private static let dbCeil: Float = 52
    // Higher bands carry ~20 dB less energy than the bass; lift them (curved so
    // the low bands stay put) to keep every bar in the same visible range.
    private static let highBandBoost: Float = 20

    private let queue = DispatchQueue(label: "com.scott.notchmate.spectrum", qos: .userInitiated)

    init(bandCount: Int = 5) {
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
        DispatchQueue.main.async { self.isLive = true }
    }

    func stop() {
        let wasRunning = aggregateID != 0 || tapID != 0
        teardown()
        unregisterDeviceChangeListener()
        guard wasRunning else { return }
        // Reset published state on the main thread — weak so a pending block can
        // never resurrect a deallocating instance.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isLive = false
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
    private func rebuildForDeviceChange() {
        guard running else { return }
        teardown()
        start()
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

        computeBands()
        publishIfDue()
    }

    private func computeBands() {
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
        let attack: Float = 0.6      // how fast bars rise toward a new peak
        let decay: Float = 0.82      // how fast they fall

        for b in 0..<bandCount {
            let lo = fMin * pow(fMax / fMin, Double(b) / Double(bandCount))
            let hi = fMin * pow(fMax / fMin, Double(b + 1) / Double(bandCount))
            let loBin = max(1, Int(lo / binHz))
            let hiBin = min(fftSize / 2 - 1, max(loBin, Int(hi / binHz)))
            var peak: Float = 0
            for bin in loBin...hiBin { peak = max(peak, magnitudes[bin]) }
            // Map magnitude to dB, then to 0…1 over a window — like a level meter,
            // so quiet passages sit low and beats reach the top: real dynamics.
            // Higher bands carry ~20 dB less energy, so lift them (measured) to
            // keep every bar in the same visible range instead of pinned low.
            let db = 20 * log10(peak + 1e-6)
            let boost = Self.highBandBoost * pow(Float(b) / Float(max(1, bandCount - 1)), 1.5)
            let norm = (db + boost - Self.dbFloor) / (Self.dbCeil - Self.dbFloor)
            let level = min(1, max(0, norm))
            smoothed[b] = level > smoothed[b]
                ? smoothed[b] + (level - smoothed[b]) * attack
                : smoothed[b] * decay
        }
    }

    /// Publish to SwiftUI at ~30 fps regardless of the (faster) audio callback.
    private func publishIfDue() {
        let now = CACurrentMediaTime()
        guard now - lastPublish >= 1.0 / 30 else { return }
        lastPublish = now
        let snapshot = smoothed.map { CGFloat($0) }
        DispatchQueue.main.async { [weak self] in self?.bands = snapshot }
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
}
