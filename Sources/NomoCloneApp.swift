//
//  NomoCloneApp.swift
//  NomoClone
//

import SwiftUI
import Photos

@main
struct NomoCloneApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .onAppear { PhotoLibrary.requestAccess() }
        }
    }
}

/// Observable knobs shared by the camera and the editor.
final class AppState: ObservableObject {
    @Published var preset: Preset = Presets.preset(id: "k4") ?? Presets.all[0]
    @Published var exposureOffset: Float = 0
    @Published var vignetteOffset: Float = 0
    @Published var grainOffset: Float = 0
    @Published var lutStrength: Float = 1.0
    @Published var grainPhase: SIMD2<Float> = SIMD2(1, 1)

    func resetOffsets() {
        exposureOffset = 0
        vignetteOffset = 0
        grainOffset = 0
        lutStrength = 1.0
    }

    func rerollGrain() {
        grainPhase = SIMD2(Float.random(in: 0..<1), Float.random(in: 0..<1))
    }
}

enum PhotoLibrary {
    static func requestAccess() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    static func save(_ image: UIImage, completion: @escaping (Error?) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }, completionHandler: completion)
    }
}
