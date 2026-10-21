//
// ShowcaseSpikes.swift
// EmoDrink Glasses
//
// The four hardware questions behind the showcase, as one developer-only
// view model (Settings › Glasses › Developer › Showcase spikes):
//   video    does the lens play an MP4 from a file:// URI, from local http?
//   latency  how long does a 600 x 600 image card take to send?
//   speech   do the glasses transcribe, and does the call screen appear?
//   inputs   do swipes and taps arrive as events?
// Every result is a timestamped line. Everything goes through GlassesLink.
//
// `LocalClipServer` is also what a later task reuses to serve clips over
// local http. This file imports no SwiftUI so the Display DSL names (Text,
// Image, FlexBox) are unambiguous.
//

import AVFoundation
import Foundation
import MWDATDisplay
import Network
import Observation
import UIKit

// MARK: - Local clip server

/// Serves ONE file as video/mp4 on 127.0.0.1 and an ephemeral port, with
/// Content-Length and single-range support (players ask for ranges).
final class LocalClipServer: @unchecked Sendable {
    enum ServerError: Error { case notReady, failed(String) }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "LocalClipServer")
    private var listener: NWListener?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Start listening and return `http://127.0.0.1:<port>/clip.mp4`.
    func start() async throws -> URL {
        stop()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            func finish(_ result: Result<URL, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/clip.mp4") {
                        finish(.success(url))
                    } else {
                        finish(.failure(ServerError.notReady))
                    }
                case .failed(let error):
                    finish(.failure(ServerError.failed(error.localizedDescription)))
                case .cancelled:
                    finish(.failure(ServerError.notReady))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            self.respond(to: request, on: connection)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        guard let body = try? Data(contentsOf: fileURL) else {
            send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", body: nil, on: connection)
            return
        }
        let total = body.count
        var range: ClosedRange<Int>?
        for line in request.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("range: bytes=") {
            let spec = line.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            if spec.count == 2, let start = Int(spec[0]), start < total {
                let end = Int(spec[1]).map { min($0, total - 1) } ?? total - 1
                if end >= start { range = start...end }
            }
        }
        if let range {
            let slice = body.subdata(in: range.lowerBound..<(range.upperBound + 1))
            let head = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: \(slice.count)\r\n"
                + "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(total)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            send(head, body: slice, on: connection)
        } else {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: \(total)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
            send(head, body: body, on: connection)
        }
    }

    private func send(_ head: String, body: Data?, on connection: NWConnection) {
        var payload = Data(head.utf8)
        if let body { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - Test clip

/// A 5 s, 600 x 600, 30 fps H.264 MP4 written at runtime: a solid colour
/// that changes each second with a bar sweeping across. Cached in Caches.
enum SpikeClip {
    static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("showcase-spike-clip.mp4")
    }

    static func ensure() async throws -> URL {
        let url = Self.url
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try await write(to: url)
        return url
    }

    private static func write(to url: URL) async throws {
        let size = 600, fps = 30, seconds = 5
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size,
            AVVideoHeightKey: size
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size,
                kCVPixelBufferHeightKey as String: size
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let colors: [UIColor] = [.systemBlue, .systemOrange, .systemTeal, .systemPurple, .systemGreen]
        for frame in 0..<(fps * seconds) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                ctx.setFillColor(colors[frame / fps % colors.count].cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
                let x = CGFloat(frame % (fps * 2)) / CGFloat(fps * 2) * CGFloat(size - 80)
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fill(CGRect(x: x, y: 0, width: 80, height: CGFloat(size)))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
}

// MARK: - View model

@Observable
@MainActor
final class ShowcaseSpikesViewModel {
    let link: GlassesLink

    /// Newest first.
    private(set) var results: [String] = []
    /// Name of the spike in flight, nil when idle.
    private(set) var running: String?
    private(set) var speechActive = false
    /// Speech is up and the owner has not yet said whether the call screen showed.
    private(set) var awaitingCallScreenAnswer = false

    @ObservationIgnored private var server: LocalClipServer?
    @ObservationIgnored private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init(link: GlassesLink) {
        self.link = link
    }

    private func note(_ message: String) {
        results.insert("\(clock.string(from: Date())) \(message)", at: 0)
        link.add("spike: \(message)")
    }

    private func begin(_ name: String) -> Bool {
        guard running == nil else { return false }
        running = name
        note("\(name): start")
        return true
    }

    private func end() { running = nil }

    func clearResults() { results.removeAll() }

    // MARK: Video

    func runVideoFile() {
        guard begin("Video file") else { return }
        Task {
            defer { end() }
            do {
                let file = try await SpikeClip.ensure()
                let started = ContinuousClock.now
                let ok = await link.sendVideo(uri: file.absoluteString, label: "video file")
                note("Video file: send \(ok ? "OK" : "FAILED") in \(Self.ms(ContinuousClock.now - started)) ms (\(file.absoluteString)); does it play?")
            } catch {
                note("Video file: clip generation failed: \(error.localizedDescription)")
            }
        }
    }

    func runVideoHTTP() {
        guard begin("Video http") else { return }
        Task {
            defer { end() }
            do {
                let file = try await SpikeClip.ensure()
                server?.stop()
                let newServer = LocalClipServer(fileURL: file)
                server = newServer
                let url = try await newServer.start()
                let started = ContinuousClock.now
                let ok = await link.sendVideo(uri: url.absoluteString, label: "video http")
                note("Video http: send \(ok ? "OK" : "FAILED") in \(Self.ms(ContinuousClock.now - started)) ms (\(url.absoluteString)); does it play?")
            } catch {
                note("Video http: failed: \(error.localizedDescription)")
            }
        }
    }

    func stopVideo() {
        Task {
            await link.stopVideo()
            server?.stop()
            server = nil
            note("Video stopped")
        }
    }

    // MARK: Card latency

    func runCardLatency() {
        guard begin("Card latency") else { return }
        Task {
            defer { end() }
            var times: [Double] = []
            for index in 1...10 {
                let image = Self.card(index: index)
                let started = ContinuousClock.now
                let ok = await link.send(label: "card \(index)") {
                    FlexBox(direction: .column) {
                        Image(image: image, sizePreset: .fill)
                    }
                }
                let elapsed = Self.ms(ContinuousClock.now - started)
                note("Card latency: #\(index) \(ok ? "OK" : "FAILED") \(Int(elapsed)) ms")
                if ok { times.append(elapsed) }
            }
            guard !times.isEmpty else {
                note("Card latency: no send succeeded")
                return
            }
            let sorted = times.sorted()
            note("Card latency: \(sorted.count)/10 OK, min \(Int(sorted[0])) ms, median \(Int(sorted[sorted.count / 2])) ms, max \(Int(sorted[sorted.count - 1])) ms")
        }
    }

    /// A 600 x 600 gradient with the send number in large text.
    private static func card(index: Int) -> UIImage {
        let size = CGSize(width: 600, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let hue = CGFloat(index) / 10
            let colors = [UIColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).cgColor,
                          UIColor(hue: hue + 0.15, saturation: 0.8, brightness: 0.5, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 600, y: 600), options: [])
            }
            let text = "CARD \(index)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 96, weight: .heavy),
                .foregroundColor: UIColor.white
            ]
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (600 - textSize.width) / 2, y: (600 - textSize.height) / 2), withAttributes: attrs)
        }
    }

    // MARK: Glasses speech

    func toggleSpeech() {
        if speechActive {
            link.stopGlassesSpeech()
            speechActive = false
            if awaitingCallScreenAnswer {
                awaitingCallScreenAnswer = false
                note("Glasses speech: stopped without a call screen answer")
            }
            end()
            return
        }
        guard begin("Glasses speech") else { return }
        Task {
            guard await link.ensureSession() else {
                note("Glasses speech: no session (\(link.sessionStateText))")
                end()
                return
            }
            let started = link.startGlassesSpeech { [weak self] text, isFinal in
                guard let self else { return }
                self.note("Glasses speech: \(isFinal ? "final" : "partial") \"\(text)\" (display \(self.link.displayStateText))")
            }
            guard started else {
                note("Glasses speech: could not start (see the Glasses basics log)")
                end()
                return
            }
            speechActive = true
            awaitingCallScreenAnswer = true
            let sent = await link.send(label: "speech spike") {
                FlexBox(direction: .column, spacing: 12) {
                    Text("Speech spike", style: .heading, color: .primary)
                    Text("Say something. Is this card still visible?", style: .body, color: .primary)
                }
                .padding(24)
            }
            note("Glasses speech: listening; lens card \(sent ? "sent" : "FAILED"), display \(link.displayStateText)")
        }
    }

    /// The owner's answer: did the glasses call screen cover the card?
    func answerCallScreen(appeared: Bool) {
        guard awaitingCallScreenAnswer else { return }
        awaitingCallScreenAnswer = false
        note("Glasses speech: call screen \(appeared ? "APPEARED" : "did NOT appear") (display \(link.displayStateText))")
    }

    // MARK: Inputs

    func runInputs() {
        guard begin("Inputs") else { return }
        Task {
            defer { end() }
            guard await link.ensureSession() else {
                note("Inputs: no session (\(link.sessionStateText))")
                return
            }
            var count = 0
            link.observeGlassesInputs { [weak self] text in
                count += 1
                self?.note("Inputs: \(text)")
            }
            note("Inputs: listening for 20 s; swipe, tap and press the buttons")
            try? await Task.sleep(for: .seconds(20))
            link.stopObservingGlassesInputs()
            note("Inputs: done, \(count) event(s)")
        }
    }

    private static func ms(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
