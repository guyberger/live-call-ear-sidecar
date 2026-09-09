import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreAudio
import CoreGraphics
import Darwin

/// ScreenCaptureKit audio-only capture: raw PCM16 LE 16 kHz mono on stdout.
/// Logs go to stderr only. Never write PCM to stderr.

enum CaptureError: Error, CustomStringConvertible {
    case noDisplay
    case permission
    var description: String {
        switch self {
        case .noDisplay: return "no display available for ScreenCaptureKit"
        case .permission: return "Screen Recording permission is required"
        }
    }
}

func permissionMessage() {
    fputs("""
    ERROR: Screen Recording permission is required for system-audio loopback.
    Grant it: System Settings → Privacy & Security → Screen Recording
    Enable ear-capture, or the app that launched it (Terminal / iTerm / Cursor).
    If you just clicked Allow, quit and re-run ./start.sh
    Then: ./start.sh

    """, stderr)
}

func isPermissionError(_ error: Error) -> Bool {
    let ns = error as NSError
    let blob = "\(ns.domain) \(ns.code) \(ns.localizedDescription)".lowercased()
    if ns.code == -3801 { return true }
    return blob.contains("declin")
        || blob.contains("not author")
        || blob.contains("permission")
        || blob.contains("tcc")
        || blob.contains("screen capture")
        || ns.domain.lowercased().contains("screencapture")
}

final class CaptureRunner: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var lastInFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!
    private let audioQueue = DispatchQueue(label: "ear.capture.audio")
    private let writeLock = NSLock()
    private var signalSources: [DispatchSourceSignal] = []
    private var stopOnce: (() -> Void)?
    private var loggedConvertFail = false
    private var writtenFrames = 0
    private var lastRmsLog = 0.0
    private var peakRms = 0

    func run() async throws {
        try await start()
        fputs("ear-capture: ScreenCaptureKit loopback started (PCM16 LE 16kHz mono → stdout)\n", stderr)
        await waitForSignal()
        await stop()
    }

    private func requireScreenRecording() throws {
        if CGPreflightScreenCaptureAccess() { return }
        fputs("ear-capture: Screen Recording not granted; requesting…\n", stderr)
        _ = CGRequestScreenCaptureAccess()
        if !CGPreflightScreenCaptureAccess() {
            throw CaptureError.permission
        }
    }

    private func start() async throws {
        try requireScreenRecording()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if isPermissionError(error) { throw CaptureError.permission }
            throw error
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Dummy video so SCK is happy; we discard frames.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        if #available(macOS 15.0, *) {
            config.captureMicrophone = true
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)
        if #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
            fputs("ear-capture: mixing system audio + microphone\n", stderr)
        }
        do {
            try await stream.startCapture()
        } catch {
            if isPermissionError(error) { throw CaptureError.permission }
            throw error
        }
        self.stream = stream
    }

    private func stop() async {
        if let stream {
            do { try await stream.stopCapture() } catch {
                fputs("ear-capture: stopCapture: \(error.localizedDescription)\n", stderr)
            }
        }
        stream = nil
        fputs("ear-capture: stopped\n", stderr)
    }

    private func waitForSignal() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.stopOnce = { cont.resume() }
            let q = DispatchQueue(label: "ear.capture.signal")
            for sig in [SIGINT, SIGTERM] {
                Darwin.signal(sig, SIG_IGN)
                let src = DispatchSource.makeSignalSource(signal: sig, queue: q)
                src.setEventHandler { [weak self] in
                    self?.finishWait()
                }
                src.resume()
                self.signalSources.append(src)
            }
        }
    }

    private func finishWait() {
        let fn = stopOnce
        stopOnce = nil
        fn?()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("ear-capture: stream error: \(error.localizedDescription)\n", stderr)
        if isPermissionError(error) {
            permissionMessage()
        }
        finishWait()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        convertAndWrite(sampleBuffer)
    }

    private func convertAndWrite(_ sampleBuffer: CMSampleBuffer) {
        guard let inBuf = pcmBuffer(from: sampleBuffer) else { return }
        ensureConverter(from: inBuf.format)
        guard let converter else { return }

        let ratio = outFormat.sampleRate / inBuf.format.sampleRate
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 32
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }

        var err: NSError?
        var consumed = false
        let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if status == .error {
            if !loggedConvertFail {
                loggedConvertFail = true
                let msg = err?.localizedDescription ?? "unknown"
                fputs("ear-capture: AVAudioConverter failed: \(msg)\n", stderr)
            }
            return
        }
        writeInt16(outBuf)
    }

    private func ensureConverter(from format: AVAudioFormat) {
        if let last = lastInFormat,
           last.sampleRate == format.sampleRate,
           last.channelCount == format.channelCount,
           last.commonFormat == format.commonFormat,
           converter != nil {
            return
        }
        converter = AVAudioConverter(from: format, to: outFormat)
        lastInFormat = format
        if converter == nil {
            fputs("ear-capture: cannot convert \(format) → \(outFormat)\n", stderr)
        } else {
            fputs(
                "ear-capture: converting \(Int(format.sampleRate)) Hz \(format.channelCount)ch \(format.commonFormat.rawValue) → 16000 Hz mono PCM16\n",
                stderr
            )
        }
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee else { return nil }
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let n = CMSampleBufferGetNumSamples(sampleBuffer)
        guard n > 0 else { return nil }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(n),
            into: buf.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buf
    }

    private func writeInt16(_ buf: AVAudioPCMBuffer) {
        let frames = Int(buf.frameLength)
        guard frames > 0, let chans = buf.int16ChannelData else { return }
        let bytes = frames * Int(buf.format.channelCount) * MemoryLayout<Int16>.size
        writeLock.lock()
        defer { writeLock.unlock() }
        _ = fwrite(chans[0], 1, bytes, stdout)
        fflush(stdout)
        writtenFrames += frames
        var sum: Int64 = 0
        for i in 0..<frames { sum += Int64(chans[0][i]) * Int64(chans[0][i]) }
        let rms = (sum > 0) ? Int((Double(sum) / Double(frames)).squareRoot()) : 0
        if rms > peakRms { peakRms = rms }
        let now = Date().timeIntervalSince1970
        if now - lastRmsLog >= 2 {
            fputs("ear-capture: pcm frames=\(writtenFrames) peak_rms=\(peakRms)\n", stderr)
            lastRmsLog = now
            peakRms = 0
        }
    }
}

@main
struct EarCapture {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        do {
            try await CaptureRunner().run()
        } catch let err as CaptureError {
            if case .permission = err { permissionMessage() }
            else { fputs("ERROR: \(err.description)\n", stderr) }
            exit(1)
        } catch {
            if isPermissionError(error) {
                permissionMessage()
            } else {
                fputs("ERROR: \(error.localizedDescription)\n", stderr)
            }
            exit(1)
        }
    }
}
