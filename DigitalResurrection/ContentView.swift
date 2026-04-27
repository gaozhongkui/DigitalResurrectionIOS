import SwiftUI
import CoreML
import Vision
import PhotosUI
import ImageIO
import RealityKit
import Metal
import UIKit

// MARK: - Types
enum DepthMode: String, CaseIterable {
    case colorized = "伪彩色"
    case overlay   = "叠加"
    case compare   = "对比"
    case original  = "原图"

    var icon: String {
        switch self {
        case .colorized: return "paintbrush.fill"
        case .overlay:   return "square.2.layers.3d"
        case .compare:   return "rectangle.split.2x1"
        case .original:  return "photo"
        }
    }
}

enum DepthError: LocalizedError {
    case modelNotFound, noOutput, colorFailed, modelInitFailed(String), dataTransferFailed
    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "找不到模型文件"
        case .noOutput:      return "模型未返回深度数据"
        case .colorFailed:   return "深度图着色失败"
        case .modelInitFailed(let msg): return "模型加载失败: \(msg)"
        case .dataTransferFailed: return "无法从相册提取图片：请检查隐私设置"
        }
    }
}

struct InferenceResult {
    let colored: CGImage
    let floats:  [Float]
    let w:       Int
    let h:       Int
}

// MARK: - ContentView
struct ContentView: View {
    @State private var pickerItem:    PhotosPickerItem? = nil
    @State private var originalImage: CGImage?          = nil
    @State private var depthColored:  CGImage?          = nil
    @State private var depthFloats:   [Float]           = []
    @State private var depthW:        Int               = 0
    @State private var depthH:        Int               = 0
    @State private var isProcessing   = false
    @State private var processMs:     Double?           = nil
    @State private var mode:          DepthMode         = .original
    @State private var splitRatio:    CGFloat           = 0.5
    @State private var errorMsg:      String?           = nil
    @State private var show3D:        Bool              = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                headerView.padding(.top, 54)
                Spacer(minLength: 16)
                displayArea.frame(maxWidth: .infinity, maxHeight: .infinity)
                if originalImage != nil { modeSelectionBar.padding(.top, 14) }
                actionButtonArea.padding(.top, 12).padding(.bottom, 30)
            }
            if isProcessing { loadingIndicator }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item = item else { return }
            print("DEBUG: [UI] 用户选择了新图片")
            Task { await handleImageSelection(item) }
        }
        .sheet(isPresented: $show3D) {
            depth3DSheet
        }
        .alert("处理失败", isPresented: Binding(
            get: { errorMsg != nil },
            set: { if !$0 { errorMsg = nil } }
        )) {
            Button("好") { errorMsg = nil }
        } message: {
            Text(errorMsg ?? "")
        }
    }

    @ViewBuilder
    private var depth3DSheet: some View {
        if let orig = originalImage, !depthFloats.isEmpty {
            DepthMeshView(originalImage: orig, depthFloats: depthFloats, depthW: depthW, depthH: depthH)
                .ignoresSafeArea()
        } else {
            VStack {
                Text("深度数据未就绪").foregroundStyle(.secondary)
                Button("返回") { show3D = false }.padding()
            }
        }
    }

    private var headerView: some View {
        VStack(spacing: 3) {
            Text("深度估计").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
            Text("Depth Anything V2 · 3D Mesh").font(.system(size: 11))
                .foregroundStyle(.red.opacity(0.7)).tracking(1.5)
        }
    }

    @ViewBuilder
    private var displayArea: some View {
        if let orig = originalImage {
            GeometryReader { geo in
                ZStack {
                    switch mode {
                    case .original:  fitImage(orig)
                    case .colorized: fitImage(depthColored ?? orig)
                    case .overlay:
                        fitImage(orig)
                        if let d = depthColored { fitImage(d).blendMode(.screen).opacity(0.8) }
                    case .compare:   splitCompareView(size: geo.size)
                    }
                    if let ms = processMs, mode != .compare { performanceTag(ms) }
                }
            }
        } else {
            emptyStateView
        }
    }

    private func fitImage(_ img: CGImage) -> some View {
        Image(img, scale: 1, orientation: .up, label: Text(""))
            .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func splitCompareView(size: CGSize) -> some View {
        ZStack {
            if let d = depthColored { fitImageFull(d, size: size) }
            if let orig = originalImage {
                fitImageFull(orig, size: size)
                    .mask(HStack(spacing: 0) {
                        Color.clear.frame(width: size.width * (1.0 - splitRatio))
                        Color.black
                    })
            }
            Rectangle().fill(.white).frame(width: 2)
                .overlay(Circle().fill(.white).frame(width: 36, height: 36).shadow(radius: 4)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.caption2).bold().foregroundStyle(.black)))
                .position(x: size.width * (1.0 - splitRatio), y: size.height / 2)
        }
        .gesture(DragGesture().onChanged { splitRatio = max(0, min(1, 1.0 - ($0.location.x / size.width))) })
    }

    private func fitImageFull(_ img: CGImage, size: CGSize) -> some View {
        Image(img, scale: 1, orientation: .up, label: Text("")).resizable().scaledToFill()
            .frame(width: size.width, height: size.height).clipped()
    }

    private func performanceTag(_ ms: Double) -> some View {
        VStack { Spacer(); HStack { Spacer()
            Text(String(format: "%.0f ms", ms)).font(.system(size: 10, design: .monospaced))
                .padding(6).background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(12)
        }}
    }

    private var modeSelectionBar: some View {
        HStack(spacing: 8) {
            ForEach(DepthMode.allCases, id: \.self) { m in
                Button { withAnimation { mode = m } } label: {
                    VStack(spacing: 4) {
                        Image(systemName: m.icon).font(.system(size: 16))
                        Text(m.rawValue).font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(mode == m ? .white : .white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(mode == m ? .black : .white)
                }
            }
        }.padding(.horizontal, 16)
    }

    private var actionButtonArea: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("更换照片", systemImage: "photo.fill").font(.headline).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding().background(.white, in: Capsule())
            }
            if !depthFloats.isEmpty {
                Button { show3D = true } label: {
                    Label("3D预览", systemImage: "cube.transparent").font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding().background(.indigo, in: Capsule())
                }
            }
        }.padding(.horizontal, 16)
    }

    private var emptyStateView: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            VStack(spacing: 20) {
                Image(systemName: "plus.viewfinder").font(.system(size: 50)).foregroundStyle(.white.opacity(0.2))
                Text("点击选择照片开始深度分析").foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var loadingIndicator: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            ProgressView("分析中...").tint(.white).foregroundStyle(.white)
        }
    }

    private func handleImageSelection(_ item: PhotosPickerItem) async {
        print("DEBUG: [Loader] 开始加载数据...")
        await MainActor.run { self.isProcessing = true }

        var finalCGImage: CGImage? = nil

        // 策略1：Data
        if let data = try? await item.loadTransferable(type: Data.self),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            print("DEBUG: [Loader] 策略1 (Data) 成功")
            finalCGImage = cgImage
        }
        // 注意：`loadTransferable(type: UIImage.self)` 在部分 SDK/配置下 UIImage 不满足 Transferable，会导致编译失败。
        // 这里保留 Data 路径（覆盖绝大多数场景）；如需更多兼容性可再加 URL/PhotosPickerItem 的其他取数策略。

        guard let cgImage = finalCGImage else {
            print("DEBUG: [Loader] 加载失败")
            await MainActor.run {
                self.errorMsg = "无法读取照片，请检查相册权限。"
                self.isProcessing = false
            }
            return
        }

        print("DEBUG: [Loader] 图片就绪，启动推理...")
        await MainActor.run {
            self.originalImage = cgImage
            self.depthColored  = nil
            self.depthFloats   = []
        }

        do {
            let start = Date()
            let result = try await performInference(cgImage)
            await MainActor.run {
                self.depthColored  = result.colored
                self.depthFloats   = result.floats
                self.depthW        = result.w
                self.depthH        = result.h
                self.processMs     = Date().timeIntervalSince(start) * 1000
                self.mode          = .compare
                self.isProcessing  = false
            }
        } catch {
            print("DEBUG: [Main] 推理报错: \(error)")
            await MainActor.run {
                self.errorMsg     = error.localizedDescription
                self.isProcessing = false
            }
        }
    }
}

// MARK: - Inference
nonisolated func performInference(_ cgImage: CGImage) async throws -> InferenceResult {
    try await Task.detached(priority: .userInitiated) {
        let modelURL = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") ??
                       Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlpackage")

        guard let url = modelURL else { throw DepthError.modelNotFound }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try VNCoreMLModel(for: try MLModel(contentsOf: url, configuration: config))

        var depthBuffer: CVPixelBuffer?
        var depthMultiArray: MLMultiArray?

        let request = VNCoreMLRequest(model: model) { req, _ in
            if let obs = req.results?.first as? VNPixelBufferObservation {
                depthBuffer = obs.pixelBuffer
            } else if let obs = req.results?.first as? VNCoreMLFeatureValueObservation {
                if let buf = obs.featureValue.imageBufferValue { depthBuffer = buf }
                else if let arr = obs.featureValue.multiArrayValue { depthMultiArray = arr }
            }
        }
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

        var finalFloats: [Float] = []
        var finalW = 0, finalH = 0
        if let buf = depthBuffer {
            if let (f, w, h) = extractNormalizedDepth(from: buf) { (finalFloats, finalW, finalH) = (f, w, h) }
        } else if let arr = depthMultiArray {
            if let (f, w, h) = extractNormalizedDepthFromMultiArray(arr) { (finalFloats, finalW, finalH) = (f, w, h) }
        }

        guard !finalFloats.isEmpty else { throw DepthError.noOutput }
        guard let colored = colorizeDepth(floats: finalFloats, w: finalW, h: finalH) else { throw DepthError.colorFailed }
        return InferenceResult(colored: colored, floats: finalFloats, w: finalW, h: finalH)
    }.value
}

// MARK: - Helpers
nonisolated func extractNormalizedDepthFromMultiArray(_ array: MLMultiArray) -> (floats: [Float], w: Int, h: Int)? {
    let shape = array.shape.map { $0.intValue }
    guard shape.count >= 2 else { return nil }
    let h = shape[shape.count - 2], w = shape[shape.count - 1], count = w * h
    var raw = [Float](repeating: 0, count: count)
    for i in 0..<count { raw[i] = array[i].floatValue }
    let vMin = raw.min() ?? 0, vMax = raw.max() ?? 1, range = max(vMax - vMin, 1e-6)
    return (raw.map { ($0 - vMin) / range }, w, h)
}

nonisolated func extractNormalizedDepth(from buffer: CVPixelBuffer) -> (floats: [Float], w: Int, h: Int)? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), bpr = CVPixelBufferGetBytesPerRow(buffer), type = CVPixelBufferGetPixelFormatType(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    var raw = [Float](repeating: 0, count: w * h)
    if type == kCVPixelFormatType_OneComponent16Half {
        let ptr = base.bindMemory(to: Float16.self, capacity: (bpr/2)*h)
        for y in 0..<h { for x in 0..<w { raw[y*w+x] = Float(ptr[y*(bpr/2)+x]) } }
    } else if type == kCVPixelFormatType_OneComponent32Float {
        let ptr = base.bindMemory(to: Float32.self, capacity: (bpr/4)*h)
        for y in 0..<h { for x in 0..<w { raw[y*w+x] = ptr[y*(bpr/4)+x] } }
    } else if type == kCVPixelFormatType_OneComponent8 {
        let ptr = base.bindMemory(to: UInt8.self, capacity: bpr*h)
        for y in 0..<h { for x in 0..<w { raw[y*w+x] = Float(ptr[y*bpr+x])/255.0 } }
    } else { return nil }
    let finite = raw.filter{$0.isFinite}.sorted()
    guard !finite.isEmpty else { return nil }
    let vMin = finite[max(0, Int(Double(finite.count)*0.03))], vMax = finite[min(finite.count-1, Int(Double(finite.count)*0.97))], range = max(vMax - vMin, 1e-6)
    return (raw.map{max(0, min(1, ($0 - vMin)/range))}, w, h)
}

nonisolated func colorizeDepth(floats: [Float], w: Int, h: Int) -> CGImage? {
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    for i in 0..<(w * h) {
        let (r, g, b) = getTurboColor(floats[i]); rgba[i*4] = r; rgba[i*4+1] = g; rgba[i*4+2] = b; rgba[i*4+3] = 255
    }
    let cfData = Data(rgba) as CFData
    guard let provider = CGDataProvider(data: cfData) else { return nil }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

nonisolated func getTurboColor(_ t: Float) -> (UInt8, UInt8, UInt8) {
    let colormap: [(Float, Float, Float)] = [(0.19, 0.07, 0.23), (0.12, 0.25, 0.75), (0.07, 0.55, 0.95), (0.15, 0.82, 0.70), (0.55, 0.95, 0.30), (0.95, 0.85, 0.10), (0.98, 0.45, 0.05), (0.75, 0.05, 0.10)]
    let scaled = t * Float(colormap.count - 1), index = min(Int(scaled), colormap.count - 2), fraction = scaled - Float(index)
    let c1 = colormap[index], c2 = colormap[index+1], u8 = { (f: Float) in UInt8(max(0, min(255, f * 255))) }
    return (u8(c1.0 + (c2.0 - c1.0) * fraction), u8(c1.1 + (c2.1 - c1.1) * fraction), u8(c1.2 + (c2.2 - c1.2) * fraction))
}

// MARK: - DepthMeshView
struct DepthMeshView: View {
    let originalImage: CGImage; let depthFloats: [Float]; let depthW: Int; let depthH: Int
    @GestureState private var dragDelta: CGSize = .zero; @State private var rotation: SIMD2<Float> = .zero; @GestureState private var pinchScale: CGFloat = 1.0; @State private var zoom: Float = 1.0
    private let cols = 120, rows = 90
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RealityView { content in
                guard let entity = buildMeshEntity() else { return }
                entity.position = [0, 0, -1.5]; content.add(entity)
            } update: { content in
                guard let entity = content.entities.first else { return }
                let yaw = rotation.x + Float(dragDelta.width) * 0.005, pitch = rotation.y + Float(dragDelta.height) * 0.005
                entity.orientation = simd_quatf(angle: pitch, axis: [1, 0, 0]) * simd_quatf(angle: yaw, axis: [0, 1, 0])
                let s = zoom * Float(pinchScale); entity.scale = [s, s, s]
            }
            .gesture(DragGesture().updating($dragDelta) { v, state, _ in state = v.translation }.onEnded { v in rotation.x += Float(v.translation.width) * 0.005; rotation.y += Float(v.translation.height) * 0.005 })
            .gesture(MagnificationGesture().updating($pinchScale) { v, state, _ in state = v }.onEnded { v in zoom *= Float(v) })
        }
    }
    private func buildMeshEntity() -> ModelEntity? {
        guard let depthTex = makeDepthTexture(), let photoTex = makePhotoTexture(), let mesh = makeSubdividedPlane(), let material = makeCustomMaterial(depthTex: depthTex, photoTex: photoTex) else { return nil }
        return ModelEntity(mesh: mesh, materials: [material])
    }
    private func makeSubdividedPlane() -> MeshResource? {
        let aspect = Float(originalImage.width) / max(Float(originalImage.height), 1), planeW: Float = 1.0, planeH: Float = planeW / aspect, vCols = cols + 1, vRows = rows + 1
        var positions = [SIMD3<Float>](), normals = [SIMD3<Float>](), uvs = [SIMD2<Float>](), indices = [UInt32]()
        for row in 0..<vRows { for col in 0..<vCols {
            let u = Float(col) / Float(cols), v = Float(row) / Float(rows); positions.append([(u - 0.5) * planeW, (0.5 - v) * planeH, 0]); normals.append([0, 0, 1]); uvs.append([u, v])
        }}
        for row in 0..<rows { for col in 0..<cols {
            let tl = UInt32(row * vCols + col), tr = tl + 1, bl = tl + UInt32(vCols), br = bl + 1; indices += [tl, bl, tr, tr, bl, br]
        }}
        var desc = MeshDescriptor(name: "DepthPlane"); desc.positions = MeshBuffer(positions); desc.normals = MeshBuffer(normals); desc.textureCoordinates = MeshBuffer(uvs); desc.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [desc])
    }
    private func makeDepthTexture() -> TextureResource? {
        let pixels = depthFloats.map { UInt8(max(0, min(255, $0 * 255))) }
        let cfData = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: cfData), let gray = CGImage(width: depthW, height: depthH, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: depthW, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return try? TextureResource(image: gray, options: .init(semantic: .raw))
    }
    private func makePhotoTexture() -> TextureResource? { try? TextureResource(image: originalImage, options: .init(semantic: .color)) }
    private func makeCustomMaterial(depthTex: TextureResource, photoTex: TextureResource) -> CustomMaterial? {
        guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary() else { return nil }
        let geomFn = CustomMaterial.GeometryModifier(named: "depthGeometry", in: library), surfFn = CustomMaterial.SurfaceShader(named: "depthSurface", in: library)
        guard var mat = try? CustomMaterial(surfaceShader: surfFn, geometryModifier: geomFn, lightingModel: .unlit) else { return nil }
        mat.custom.texture = .init(depthTex); mat.baseColor.texture = .init(photoTex); return mat
    }
}
