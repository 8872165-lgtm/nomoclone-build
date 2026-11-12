//
//  LookEngine.swift
//  NomoClone
//
//  Runs the recovered NomoRaw stage chain on Metal:
//
//      exposure -> vignette (multiply) -> grain (soft light) -> LUT
//
//  which is the order of the ten `make*:` calls inside -[NOMOFilter outputBuffer:].
//  Only these four stages are driven by a preset; the remaining six (shadow,
//  white balance, sharpness, contrast, saturation, highlight) default to 0 and
//  short-circuit to a pass-through in the original code, so they are omitted.
//

import Foundation
import Metal
import MetalKit
import CoreImage
import CoreGraphics
import Compression
import UIKit

enum LookError: Error {
    case noDevice
    case noFunction(String)
    case noAsset(String)
    case badCube(String)
}

/// Everything the engine needs, loaded once.
final class LookEngine {
    static let shared = LookEngine()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private let pExposure: MTLComputePipelineState
    private let pMultiply: MTLComputePipelineState
    private let pSoftLight: MTLComputePipelineState
    private let pLut: MTLComputePipelineState
    private let pCopy: MTLComputePipelineState

    private var cubes: [String: MTLTexture] = [:]
    private var grainTexture: MTLTexture?
    private var vignetteTexture: MTLTexture?
    private let cicontext = CIContext(options: [.workingColorSpace: NSNull()])

    /// Exact constant from -[NOMOFilter makeExposure:] (double at __TEXT,__const).
    static let exposureGain: Float = 0.65
    static let cubeSize = 64

    /// Compile one compute function out of the bundled default.metallib.
    private static func makePipe(_ dev: MTLDevice,
                                 _ lib: MTLLibrary,
                                 _ name: String) -> MTLComputePipelineState {
        guard let fn = lib.makeFunction(name: name) else {
            fatalError("default.metallib has no function '\(name)'")
        }
        do {
            return try dev.makeComputePipelineState(function: fn)
        } catch {
            fatalError("pipeline '\(name)' failed: \(error)")
        }
    }

    init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            fatalError("Metal is required")
        }
        guard let lib = dev.makeDefaultLibrary() else {
            fatalError("default.metallib missing from the app bundle")
        }
        pExposure  = LookEngine.makePipe(dev, lib, "exposure_kernel")
        pMultiply  = LookEngine.makePipe(dev, lib, "multiply_blend_kernel")
        pSoftLight = LookEngine.makePipe(dev, lib, "soft_light_blend_kernel")
        pLut       = LookEngine.makePipe(dev, lib, "lut_kernel")
        pCopy      = LookEngine.makePipe(dev, lib, "copy_kernel")
        device = dev
        commandQueue = q
    }

    // ------------------------------------------------------------------ assets
    /// Inflate a .dat: 2-byte zlib header, DEFLATE body, 4-byte adler32.
    private static func inflateDat(_ url: URL) throws -> Data {
        let raw = try Data(contentsOf: url)
        guard raw.count > 6 else { throw LookError.badCube(url.lastPathComponent) }
        let body = raw.subdata(in: 2..<(raw.count - 4))
        var out = Data(count: cubeSize * cubeSize * cubeSize * 4)
        let produced: Int = out.withUnsafeMutableBytes { dst in
            body.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!,
                                          dst.count,
                                          src.bindMemory(to: UInt8.self).baseAddress!,
                                          src.count,
                                          nil,
                                          COMPRESSION_ZLIB)
            }
        }
        guard produced == cubeSize * cubeSize * cubeSize * 4 else {
            throw LookError.badCube(url.lastPathComponent)
        }
        return out
    }

    /// Build a 64^3 RGBA8 3D texture whose axis order matches the raw payload
    /// (x = B, y = R, z = G) so the bytes can be copied straight in.
    func cube(named stem: String) throws -> MTLTexture {
        if let t = cubes[stem] { return t }
        guard let url = Bundle.main.url(forResource: stem, withExtension: "dat",
                                        subdirectory: "luts")
                ?? Bundle.main.url(forResource: stem, withExtension: "dat") else {
            throw LookError.noAsset(stem)
        }
        let data = try LookEngine.inflateDat(url)
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba8Unorm
        desc.width = LookEngine.cubeSize
        desc.height = LookEngine.cubeSize
        desc.depth = LookEngine.cubeSize
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw LookError.badCube(stem)
        }
        let rowBytes = LookEngine.cubeSize * 4
        let planed = rowBytes * LookEngine.cubeSize
        data.withUnsafeBytes { p in
            tex.replace(region: MTLRegionMake3D(0, 0, 0,
                                               LookEngine.cubeSize,
                                               LookEngine.cubeSize,
                                               LookEngine.cubeSize),
                        mipmapLevel: 0,
                        slice: 0,
                        withBytes: p.baseAddress!,
                        bytesPerRow: rowBytes,
                        bytesPerImage: planed)
        }
        cubes[stem] = tex
        return tex
    }

    private func plate(named name: String) throws -> MTLTexture {
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let img = UIImage(contentsOfFile: url.path),
              let cg = img.cgImage else { throw LookError.noAsset(name) }
        let loader = MTKTextureLoader(device: device)
        return try loader.newTexture(cgImage: cg, options: [
            .SRGB: NSNumber(value: false),
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue),
        ])
    }

    // ------------------------------------------------------------------ textures
    private func targetTexture(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder,
                          _ pipe: MTLComputePipelineState,
                          width: Int, height: Int) {
        enc.setComputePipelineState(pipe)
        let w = pipe.threadExecutionWidth
        let h = max(1, pipe.maxTotalThreadsPerThreadgroup / w)
        let tg = MTLSize(width: w, height: h, depth: 1)
        let grid = MTLSize(width: width, height: height, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
    }

    // ------------------------------------------------------------------ pipeline
    /// Renders `source` (an sRGB-encoded BGRA/RGBA texture) through the look.
    /// All maths runs on un-premultiplied float values in 0..1 code space,
    /// exactly like the app's half-float render targets.
    func render(source: MTLTexture,
                preset: Preset,
                exposureOffset: Float = 0,
                vignetteOffset: Float = 0,
                grainOffset: Float = 0,
                lutStrength: Float = 1.0,
                grainPhase: SIMD2<Float> = .init(1, 1),
                commandBuffer: MTLCommandBuffer? = nil) throws -> MTLTexture {

        let w = source.width, h = source.height
        var current = source
        let cb = commandBuffer ?? commandQueue.makeCommandBuffer()!

        func pingPong() -> (MTLTexture, MTLTexture) {
            guard let a = targetTexture(width: w, height: h),
                  let b = targetTexture(width: w, height: h) else {
                fatalError("texture allocation failed")
            }
            return (a, b)
        }
        var (bufA, bufB) = pingPong()
        var flip = false
        func next() -> MTLTexture {
            flip.toggle()
            return flip ? bufB : bufA
        }

        // 1. exposure  (value * 0.65 fed to pow(2, t))
        let stops = (preset.exposure + exposureOffset) * LookEngine.exposureGain
        if stops != 0 {
            let dst = next()
            let enc = cb.makeComputeCommandEncoder()!
            enc.setTexture(current, index: 0)
            enc.setTexture(dst, index: 1)
            var s = stops
            enc.setBytes(&s, length: MemoryLayout<Float>.size, index: 0)
            dispatch(enc, pExposure, width: w, height: h)
            enc.endEncoding()
            current = dst
        }

        // 2. vignette  (multiplyBlendFragment, strength = darkCorner)
        let vig = max(0, preset.vignette + vignetteOffset)
        if vig > 0 {
            let tex = try vignetteTexture ?? plate(named: "vignette")
            vignetteTexture = tex
            let dst = next()
            let enc = cb.makeComputeCommandEncoder()!
            enc.setTexture(current, index: 0)
            enc.setTexture(tex, index: 1)
            enc.setTexture(dst, index: 2)
            var s = vig
            enc.setBytes(&s, length: MemoryLayout<Float>.size, index: 0)
            dispatch(enc, pMultiply, width: w, height: h)
            enc.endEncoding()
            current = dst
        }

        // 3. grain  (softLightBlendFragment, strength = grains)
        let gr = max(0, preset.grain + grainOffset)
        if gr > 0 {
            let tex = try grainTexture ?? plate(named: "Grain-800")
            grainTexture = tex
            let dst = next()
            let enc = cb.makeComputeCommandEncoder()!
            enc.setTexture(current, index: 0)
            enc.setTexture(tex, index: 1)
            enc.setTexture(dst, index: 2)
            var s = gr
            var ph = grainPhase
            enc.setBytes(&s, length: MemoryLayout<Float>.size, index: 0)
            enc.setBytes(&ph, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            dispatch(enc, pSoftLight, width: w, height: h)
            enc.endEncoding()
            current = dst
        }

        // 4. LUT  (LUTFragment) — last, so grain and vignette get graded too
        if !preset.lut.isEmpty {
            let cubeTex = try cube(named: preset.lut)
            let dst = next()
            let enc = cb.makeComputeCommandEncoder()!
            enc.setTexture(current, index: 0)
            enc.setTexture(cubeTex, index: 1)
            enc.setTexture(dst, index: 2)
            var inten = lutStrength
            var bw: Int32 = preset.isBW ? 1 : 0
            enc.setBytes(&inten, length: MemoryLayout<Float>.size, index: 0)
            enc.setBytes(&bw, length: MemoryLayout<Int32>.size, index: 1)
            dispatch(enc, pLut, width: w, height: h)
            enc.endEncoding()
            current = dst
        }

        // always end on bufA so the caller can convert deterministically
        if current !== bufA {
            let enc = cb.makeComputeCommandEncoder()!
            enc.setTexture(current, index: 0)
            enc.setTexture(bufA, index: 1)
            dispatch(enc, pCopy, width: w, height: h)
            enc.endEncoding()
            current = bufA
        }

        if commandBuffer == nil {
            cb.commit()
            // The caller converts the result with CoreImage straight away, so the
            // GPU work has to be finished before we hand the texture back.
            cb.waitUntilCompleted()
        }
        return current
    }

    /// Render and hand back a CGImage (for preview / saving).
    func image(from texture: MTLTexture) -> CGImage? {
        let ci = CIImage(mtlTexture: texture, options: [
            .colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        ])
        return ci.flatMap { cicontext.createCGImage($0, from: $0.extent) }
    }
}
