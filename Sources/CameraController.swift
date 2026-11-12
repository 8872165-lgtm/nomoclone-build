//
//  CameraController.swift
//  NomoClone
//
//  AVCaptureSession -> CVPixelBuffer -> MTLTexture, so the live preview runs
//  through the same LookEngine kernels as the still export.
//

import AVFoundation
import CoreImage
import Metal
import MetalKit
import UIKit

final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "nomoclone.capture")

    private var textureCache: CVMetalTextureCache?
    /// Called on a background queue for every frame, with a BGRA texture.
    var onFrame: ((MTLTexture) -> Void)?
    /// Called on the main queue when a full-resolution still is ready.
    var onPhoto: ((UIImage) -> Void)?

    @Published var isReady = false
    @Published var lastError: String?

    override init() {
        super.init()
        CVMetalTextureCacheCreate(nil, nil, LookEngine.shared.device, nil, &textureCache)
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.lastError = "Camera access denied" }
                return
            }
            self.queue.async { self.configure(); self.session.startRunning() }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure() {
        guard !isReady else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            try? device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        photoOutput.isHighResolutionCaptureEnabled = true

        session.commitConfiguration()
        DispatchQueue.main.async { self.isReady = true }
    }

    func capturePhoto() {
        let settings = AVCapturePhotoSettings(format: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        settings.isHighResolutionPhotoEnabled = true
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - AVCapturePhotoCaptureDelegate
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(),
              let raw = UIImage(data: data) else { return }
        let rendered = StillRenderer.shared.render(uiImage: raw)
        DispatchQueue.main.async { self.onPhoto?(rendered ?? raw) }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let cache = textureCache,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .bgra8Unorm, w, h, 0, &cvTexture)
        guard let cvTexture,
              let tex = CVMetalTextureGetTexture(cvTexture) else { return }
        onFrame?(tex)
    }
}

/// Full-resolution still path: UIImage -> MTLTexture -> LookEngine -> UIImage.
final class StillRenderer {
    static let shared = StillRenderer()
    private let context = CIContext(mtlDevice: LookEngine.shared.device)

    func render(uiImage: UIImage) -> UIImage? {
        let s = CurrentState.shared.snapshot()
        guard let cg = uiImage.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        var extent = ci.extent
        extent.origin = .zero

        // build a readable source texture through CoreImage
        var pixels = [UInt8](repeating: 0, count: Int(extent.width * extent.height * 4))
        pixels.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            context.render(ci,
                           toBitmap: base,
                           rowBytes: Int(extent.width) * 4,
                           bounds: extent,
                           format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }

        let sdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Int(extent.width),
            height: Int(extent.height),
            mipmapped: false)
        sdesc.usage = [.shaderRead]
        sdesc.storageMode = .shared
        guard let src = LookEngine.shared.device.makeTexture(descriptor: sdesc) else { return nil }
        pixels.withUnsafeBytes { p in
            src.replace(region: MTLRegionMake2D(0, 0, Int(extent.width), Int(extent.height)),
                        mipmapLevel: 0,
                        withBytes: p.baseAddress!,
                        bytesPerRow: Int(extent.width) * 4)
        }

        guard let result = try? LookEngine.shared.render(
            source: src,
            preset: s.preset,
            exposureOffset: s.exposureOffset,
            vignetteOffset: s.vignetteOffset,
            grainOffset: s.grainOffset,
            lutStrength: s.lutStrength,
            grainPhase: s.grainPhase) else { return nil }

        let ciOut = CIImage(mtlTexture: result, options: [
            .colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        ])
        guard let ciOut, let cgOut = context.createCGImage(ciOut, from: ciOut.extent) else {
            return nil
        }
        return UIImage(cgImage: cgOut)
    }
}

/// Bridges AppState into non-SwiftUI code paths (photo delegate, renderer).
final class CurrentState {
    static let shared = CurrentState()
    private var presets: AppState?

    struct Snapshot {
        var preset: Preset
        var exposureOffset: Float
        var vignetteOffset: Float
        var grainOffset: Float
        var lutStrength: Float
        var grainPhase: SIMD2<Float>
    }

    func bind(_ s: AppState) { presets = s }

    func snapshot() -> Snapshot {
        guard let s = presets else {
            return Snapshot(preset: Presets.all[0], exposureOffset: 0, vignetteOffset: 0,
                            grainOffset: 0, lutStrength: 1, grainPhase: SIMD2(1, 1))
        }
        return Snapshot(preset: s.preset, exposureOffset: s.exposureOffset,
                        vignetteOffset: s.vignetteOffset, grainOffset: s.grainOffset,
                        lutStrength: s.lutStrength, grainPhase: s.grainPhase)
    }
}
