//
//  ContentView.swift
//  NomoClone
//

import SwiftUI
import MetalKit
import PhotosUI
import CoreImage

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var camera = CameraController()

    @State private var showLibrary = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var captured: UIImage?
    @State private var toast: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalPreview(camera: camera, state: state)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                presetStrip
                controlBar
            }
            .padding(.horizontal, 12)

            if let toast {
                VStack {
                    Text(toast)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .padding(.top, 64)
                .transition(.opacity)
            }
        }
        .onAppear {
            CurrentState.shared.bind(state)
            camera.start()
        }
        .onDisappear { camera.stop() }
        .onChange(of: state.preset) { _ in state.rerollGrain() }
        .sheet(isPresented: $showLibrary) {
            PhotosPicker(selection: $libraryItem, matching: .images) {
                Text("Choose a photo")
            }
            .onChange(of: libraryItem) { item in
                Task { await loadLibraryItem(item) }
            }
            .padding()
            .presentationDetents([.height(160)])
        }
        .fullScreenCover(item: Binding(
            get: { captured.map(IdentifiedImage.init) },
            set: { if $0 == nil { captured = nil } })) { wrapper in
                EditorView(image: wrapper.image)
                    .environmentObject(state)
            }
    }

    // MARK: - chrome
    private var topBar: some View {
        HStack {
            Text("NomoClone")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Button {
                showLibrary = true
            } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 18, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.top, 8)
    }

    private var presetStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Presets.all) { p in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { state.preset = p }
                    } label: {
                        VStack(spacing: 3) {
                            Text(p.id)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                            Text(p.name)
                                .font(.system(size: 9))
                                .lineLimit(1)
                                .frame(width: 74)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .foregroundStyle(state.preset == p ? .black : .white.opacity(0.8))
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(state.preset == p ? Color(hex: p.group == .analog
                                                                ? "#c8a24a" : "#8fb8d8")
                                                        : Color.white.opacity(0.10))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var controlBar: some View {
        HStack(alignment: .center, spacing: 20) {
            parameterButton

            Button {
                camera.capturePhoto()
                camera.onPhoto = { image in
                    captured = image
                    flash("saved look preview")
                }
            } label: {
                ZStack {
                    Circle().stroke(.white.opacity(0.9), lineWidth: 3).frame(width: 72, height: 72)
                    Circle().fill(.white).frame(width: 58, height: 58)
                }
            }
            .buttonStyle(.plain)

            Button {
                state.lutStrength = state.lutStrength >= 0.999 ? 0.0 : 1.0
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: state.lutStrength >= 0.999
                          ? "circle.lefthalf.filled" : "circle")
                    Text("LUT").font(.system(size: 9))
                }
                .frame(width: 46)
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.bottom, 18)
    }

    private var parameterButton: some View {
        Menu {
            Section("exposure \(String(format: "%+.2f", state.exposureOffset)) EV") {
                Button("+0.33") { state.exposureOffset += 0.33 }
                Button("-0.33") { state.exposureOffset -= 0.33 }
                Button("reset") { state.exposureOffset = 0 }
            }
            Section("darkCorner \(String(format: "%+.2f", state.vignetteOffset))") {
                Button("+0.1") { state.vignetteOffset += 0.1 }
                Button("-0.1") { state.vignetteOffset -= 0.1 }
                Button("reset") { state.vignetteOffset = 0 }
            }
            Section("grains \(String(format: "%+.2f", state.grainOffset))") {
                Button("+0.25") { state.grainOffset += 0.25 }
                Button("-0.25") { state.grainOffset -= 0.25 }
                Button("reset") { state.grainOffset = 0 }
            }
            Button("reset all") { state.resetOffsets() }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "slider.horizontal.3")
                Text("ADJ").font(.system(size: 9))
            }
            .frame(width: 46)
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    private func flash(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation { toast = nil }
        }
    }

    private func loadLibraryItem(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let ui = UIImage(data: data) else { return }
        await MainActor.run {
            captured = StillRenderer.shared.render(uiImage: ui) ?? ui
        }
    }
}

struct IdentifiedImage: Identifiable {
    let id = UUID()
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
}

// MARK: - live preview through the same kernels

struct MetalPreview: UIViewRepresentable {
    let camera: CameraController
    let state: AppState

    func makeCoordinator() -> Coordinator { Coordinator(camera: camera, state: state) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: LookEngine.shared.device)
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 30
        view.colorPixelFormat = .bgra8Unorm
        view.delegate = context.coordinator
        camera.onFrame = { [weak coord = context.coordinator] tex in
            coord?.latest = tex
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.state = state
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let camera: CameraController
        var state: AppState
        var latest: MTLTexture?
        private let ciContext = CIContext(mtlDevice: LookEngine.shared.device)

        init(camera: CameraController, state: AppState) {
            self.camera = camera
            self.state = state
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let src = latest,
                  let drawable = view.currentDrawable else { return }
            let st = CurrentState.shared.snapshot()
            guard let out = try? LookEngine.shared.render(
                source: src,
                preset: st.preset,
                exposureOffset: st.exposureOffset,
                vignetteOffset: st.vignetteOffset,
                grainOffset: st.grainOffset,
                lutStrength: st.lutStrength,
                grainPhase: st.grainPhase) else { return }

            var img = CIImage(mtlTexture: out, options: [
                .colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
            ])
            if let ci = img {
                let sx = CGFloat(drawable.width) / ci.extent.width
                let sy = CGFloat(drawable.height) / ci.extent.height
                img = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }
            guard let final = img else { return }
            ciContext.render(final, to: drawable.texture,
                             commandBuffer: nil,
                             bounds: CGRect(x: 0, y: 0,
                                            width: drawable.width,
                                            height: drawable.height),
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            drawable.present()
        }
    }
}

// MARK: - editor for a captured / imported still

struct EditorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    @State private var preview: UIImage?
    @State private var working = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                }
                VStack {
                    HStack {
                        Button("Close") { dismiss() }
                        Spacer()
                        Button("Save") { save() }.bold()
                    }
                    .foregroundStyle(.white)
                    .padding()
                    Spacer()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Presets.all) { p in
                                Button {
                                    state.preset = p
                                    refresh(geo.size)
                                } label: {
                                    Text(p.id)
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .padding(.vertical, 6).padding(.horizontal, 9)
                                        .foregroundStyle(state.preset == p ? .black : .white)
                                        .background(Capsule().fill(state.preset == p
                                                                  ? Color(hex: "#c8a24a")
                                                                  : Color.white.opacity(0.12)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear { refresh(nil) }
    }

    private func refresh(_ size: CGSize?) {
        guard !working else { return }
        working = true
        let src = downsample(image, maxEdge: 1600) ?? image
        DispatchQueue.global(qos: .userInitiated).async {
            let out = StillRenderer.shared.render(uiImage: src)
            DispatchQueue.main.async {
                preview = out ?? src
                working = false
            }
        }
    }

    private func save() {
        let full = StillRenderer.shared.render(uiImage: image) ?? image
        PhotoLibrary.save(full) { _ in dismiss() }
    }

    private func downsample(_ img: UIImage, maxEdge: CGFloat) -> UIImage? {
        let longest = max(img.size.width, img.size.height)
        guard longest > maxEdge else { return img }
        let s = maxEdge / longest
        let size = CGSize(width: img.size.width * s, height: img.size.height * s)
        return UIGraphicsImageRenderer(size: size).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
