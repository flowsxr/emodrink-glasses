//
// ClipRenderer.swift
//
// Renders a SwiftUI animation (ClipArt: a view of progress t in 0...1) into
// a 600 x 600 H.264 MP4 for the lens: one LensRenderer frame per tick,
// copied into a pixel buffer and appended through AVAssetWriter. Frames go
// to a temp file beside the target, moved into place only on success; a
// failed or cancelled render leaves nothing behind. AVFoundation, CoreVideo
// and SwiftUI only (no UIKit), so tests/showcase-clips runs on macOS.
//

import AVFoundation
import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import SwiftUI

enum ClipRenderer {
    enum RenderError: Error, Equatable {
        case cannotStart(String)
        case noPixelBuffer
        case frameFailed(Int)
        case writerFailed(String)
    }

    /// Renders `duration` seconds at `fps` to `url` (replacing any file
    /// there). Frame i shows `frame(i / (n - 1))`, so the clip starts at
    /// t = 0 and its last frame is t = 1.
    @MainActor
    static func render<V: View>(duration: TimeInterval, fps: Int = 30, to url: URL,
                                frame: (Double) -> V) async throws {
        let width = Int(LensRenderer.size.width), height = Int(LensRenderer.size.height)
        let count = max(1, Int((duration * Double(fps)).rounded()))
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).mp4")

        var writer: AVAssetWriter?
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let w = try AVAssetWriter(outputURL: temp, fileType: .mp4)
            writer = w
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 4_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: fps,
                ] as [String: Any],
            ])
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
            guard w.canAdd(input) else { throw RenderError.cannotStart("cannot add the video input") }
            w.add(input)
            guard w.startWriting() else {
                throw RenderError.cannotStart(w.error?.localizedDescription ?? "startWriting failed")
            }
            w.startSession(atSourceTime: .zero)

            for i in 0..<count {
                try Task.checkCancellation()
                let t = count > 1 ? Double(i) / Double(count - 1) : 1
                guard let pool = adaptor.pixelBufferPool else { throw RenderError.noPixelBuffer }
                // Each frame's image and bitmap context are released before the next.
                let buffer: CVPixelBuffer = try autoreleasepool {
                    guard let image = LensRenderer.cgImage(frame(t)) else { throw RenderError.frameFailed(i) }
                    return try pixelBuffer(from: image, pool: pool)
                }
                while !input.isReadyForMoreMediaData {
                    if w.status == .failed { break }
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                let time = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw RenderError.writerFailed(w.error?.localizedDescription ?? "append failed at frame \(i)")
                }
                // Let the main actor breathe between frames.
                await Task.yield()
            }

            input.markAsFinished()
            w.endSession(atSourceTime: CMTime(value: CMTimeValue(count), timescale: CMTimeScale(fps)))
            await w.finishWriting()
            guard w.status == .completed else {
                throw RenderError.writerFailed(w.error?.localizedDescription ?? "finishWriting ended \(w.status.rawValue)")
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            if let writer, writer.status == .writing { writer.cancelWriting() }
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Where a clip of `kind` for `key` lives: Caches/showcase-clips, named
    /// by the SHA-256 of the key, so the same run reuses its files.
    static func cacheURL(kind: String, key: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return caches.appendingPathComponent("showcase-clips", isDirectory: true)
            .appendingPathComponent("\(kind)-\(digest).mp4")
    }

    /// A pool buffer holding `image`, drawn upright (BGRA, top row first).
    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let buffer = out else {
            throw RenderError.noPixelBuffer
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw RenderError.noPixelBuffer }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }
}
