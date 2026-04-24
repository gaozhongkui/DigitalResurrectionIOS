import SwiftUI
import CoreML
import Vision
import PhotosUI
import ImageIO

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
    case modelNotFound, noOutput, colorFailed
    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "找不到模型文件"
        case .noOutput:      return "模型未返回深度数据"
        case .colorFailed:   return "深度图着色失败"
        }
    }
}

// MARK: - ContentView
struct ContentView: View {
    @State private var pickerItem:    PhotosPickerItem? = nil
    @State private var originalImage: CGImage?          = nil
    @State private var depthColored:  CGImage?          = nil
    // 深度浮点数组（用于 3D Mesh）
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
            Task { await handleImageSelection(item) }
        }
        .sheet(isPresented: $show3D) {
            depth3DSheet
        }
        // 错误弹窗：任何失败都显示原因
        .alert("处理失败", isPresented: Binding(
            get: { errorMsg != nil },
            set: { if !$0 { errorMsg = nil } }
        )) {
            Button("好") { errorMsg = nil }
        } message: {
            Text(errorMsg ?? "")
        }
    }

    // MARK: - 3D Sheet（独立属性，避免 SourceKit 联动编译问题）
    @ViewBuilder
    private var depth3DSheet: some View {
        if let orig = originalImage, !depthFloats.isEmpty {
            DepthMeshView(
                originalImage: orig,
                depthFloats:   depthFloats,
                depthW:        depthW,
                depthH:        depthH
            )
            .ignoresSafeArea()
        } else {
            Text("深度数据未就绪").foregroundStyle(.secondary)
        }
    }

    // MARK: - Header
    private var headerView: some View {
        VStack(spacing: 3) {
            Text("深度估计").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
            Text("Depth Anything V2 · 3D Mesh").font(.system(size: 11))
                .foregroundStyle(.red.opacity(0.7)).tracking(1.5)
        }
    }

    // MARK: - Display Area
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
                    if let ms = processMs, mode != .compare {
                        performanceTag(ms)
                    }
                }
            }
        } else {
            emptyStateView
        }
    }

    private func fitImage(_ img: CGImage) -> some View {
        Image(img, scale: 1, orientation: .up, label: Text(""))
            .resizable().scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func splitCompareView(size: CGSize) -> some View {
        ZStack {
            if let d = depthColored { fitImageFull(d, size: size) }
            if let orig = originalImage {
                fitImageFull(orig, size: size)
                    .mask(HStack(spacing: 0) {
                        Color.clear.frame(width: size.width * splitRatio)
                        Color.black
                    })
            }
            Rectangle().fill(.white).frame(width: 2)
                .overlay(
                    Circle().fill(.white).frame(width: 36, height: 36).shadow(radius: 4)
                        .overlay(Image(systemName: "arrow.left.and.right")
                            .font(.caption2).bold().foregroundStyle(.black))
                )
                .position(x: size.width * splitRatio, y: size.height / 2)
        }
        .gesture(DragGesture().onChanged {
            splitRatio = max(0, min(1, $0.location.x / size.width))
        })
    }

    private func fitImageFull(_ img: CGImage, size: CGSize) -> some View {
        Image(img, scale: 1, orientation: .up, label: Text(""))
            .resizable().scaledToFill()
            .frame(width: size.width, height: size.height).clipped()
    }

    private func performanceTag(_ ms: Double) -> some View {
        VStack { Spacer(); HStack { Spacer()
            Text(String(format: "%.0f ms", ms))
                .font(.system(size: 10, design: .monospaced))
                .padding(6).background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white).padding(12)
        }}
    }

    // MARK: - Mode Bar
    private var modeSelectionBar: some View {
        HStack(spacing: 8) {
            ForEach(DepthMode.allCases, id: \.self) { m in
                Button { withAnimation { mode = m } } label: {
                    VStack(spacing: 4) {
                        Image(systemName: m.icon).font(.system(size: 16))
                        Text(m.rawValue).font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(mode == m ? .white : .white.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(mode == m ? .black : .white)
                }
            }
        }.padding(.horizontal, 16)
    }

    // MARK: - Action Buttons
    private var actionButtonArea: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("更换照片", systemImage: "photo.fill")
                    .font(.headline).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding()
                    .background(.white, in: Capsule())
            }
            if !depthFloats.isEmpty {
                Button { show3D = true } label: {
                    Label("3D预览", systemImage: "cube.transparent")
                        .font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding()
                        .background(.indigo, in: Capsule())
                }
            }
        }.padding(.horizontal, 16)
    }

    private var emptyStateView: some View {
        PhotosPicker(selection: $pickerItem, matching: .images) {
            VStack(spacing: 20) {
                Image(systemName: "plus.viewfinder")
                    .font(.system(size: 50)).foregroundStyle(.white.opacity(0.2))
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

    // MARK: - Image Selection
    private func handleImageSelection(_ item: PhotosPickerItem) async {
        // 步骤1：加载原始数据（支持 HEIC/JPEG/PNG 等）
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            await MainActor.run { errorMsg = "无法读取照片数据，请检查照片权限或重新选择" }
            return
        }

        // 步骤2：解码为 CGImage（ImageIO 支持所有系统格式）
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            await MainActor.run { errorMsg = "照片解码失败，格式可能不支持" }
            return
        }

        await MainActor.run {
            self.originalImage = cgImage
            self.depthColored  = nil
            self.depthFloats   = []
            self.isProcessing  = true
            self.processMs     = nil
        }

        // 步骤3：深度推理
        let start = Date()
        do {
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
            await MainActor.run {
                self.errorMsg     = error.localizedDescription
                self.isProcessing = false
                self.mode         = .original   // 回退到原图模式
            }
        }
    }
}

// MARK: - Inference Result
struct InferenceResult {
    let colored: CGImage
    let floats:  [Float]
    let w:       Int
    let h:       Int
}

// MARK: - Inference (nonisolated, runs on Task.detached)
nonisolated func performInference(_ cgImage: CGImage) async throws -> InferenceResult {
    try await Task.detached(priority: .userInitiated) {
        // 优先找编译产物 .mlmodelc，备用直接加载 .mlpackage
        let modelURL = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc")
                    ?? Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlpackage")
        guard let modelURL else { throw DepthError.modelNotFound }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try VNCoreMLModel(for: MLModel(contentsOf: modelURL, configuration: config))

        var depthBuffer: CVPixelBuffer?
        let request = VNCoreMLRequest(model: model) { req, _ in
            if let obs = req.results?.first as? VNPixelBufferObservation {
                depthBuffer = obs.pixelBuffer
            } else if let obs = req.results?.first as? VNCoreMLFeatureValueObservation {
                depthBuffer = obs.featureValue.imageBufferValue
            }
        }
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: cgImage).perform([request])

        guard let buf = depthBuffer else { throw DepthError.noOutput }
        guard let (floats, w, h) = extractNormalizedDepth(from: buf) else {
            throw DepthError.noOutput
        }
        guard let colored = colorizeDepth(floats: floats, w: w, h: h) else {
            throw DepthError.colorFailed
        }
        return InferenceResult(colored: colored, floats: floats, w: w, h: h)
    }.value
}

// MARK: - Shared depth helpers (also used by DepthMeshView)

/// 从 CVPixelBuffer 提取归一化深度浮点 [0, 1]
nonisolated func extractNormalizedDepth(
    from buffer: CVPixelBuffer
) -> (floats: [Float], w: Int, h: Int)? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

    let w   = CVPixelBufferGetWidth(buffer)
    let h   = CVPixelBufferGetHeight(buffer)
    let bpr = CVPixelBufferGetBytesPerRow(buffer)
    let fmt = CVPixelBufferGetPixelFormatType(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

    var raw = [Float](repeating: 0, count: w * h)
    switch fmt {
    case kCVPixelFormatType_OneComponent16Half:
        let stride = bpr / 2
        let ptr = base.bindMemory(to: Float16.self, capacity: stride * h)
        for y in 0..<h { for x in 0..<w { raw[y*w+x] = Float(ptr[y*stride+x]) } }
    case kCVPixelFormatType_OneComponent32Float:
        let stride = bpr / 4
        let ptr = base.bindMemory(to: Float32.self, capacity: stride * h)
        for y in 0..<h { for x in 0..<w { raw[y*w+x] = ptr[y*stride+x] } }
    case kCVPixelFormatType_OneComponent8:
        let stride = bpr
        let ptr = base.bindMemory(to: UInt8.self, capacity: stride * h)
        for y in 0..<h { for x in 0..<w { raw[y*w+x] = Float(ptr[y*stride+x]) / 255.0 } }
    default:
        return nil
    }

    // 鲁棒归一化：剔除头尾 3% 极值
    let finite = raw.filter { $0.isFinite }.sorted()
    guard !finite.isEmpty else { return nil }
    let vMin  = finite[max(0, Int(Double(finite.count) * 0.03))]
    let vMax  = finite[min(finite.count - 1, Int(Double(finite.count) * 0.97))]
    let range = max(vMax - vMin, 1e-6)
    let normalized = raw.map { max(0, min(1, ($0 - vMin) / range)) }
    return (normalized, w, h)
}

/// Turbo 伪彩色着色
nonisolated func colorizeDepth(floats: [Float], w: Int, h: Int) -> CGImage? {
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    for i in 0..<(w * h) {
        let (r, g, b) = getTurboColor(floats[i])
        rgba[i*4] = r; rgba[i*4+1] = g; rgba[i*4+2] = b; rgba[i*4+3] = 255
    }
    let cfData = Data(rgba) as CFData
    guard let provider = CGDataProvider(data: cfData) else { return nil }
    return CGImage(
        width: w, height: h,
        bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil,
        shouldInterpolate: true, intent: .defaultIntent
    )
}

nonisolated func getTurboColor(_ t: Float) -> (UInt8, UInt8, UInt8) {
    let colormap: [(Float, Float, Float)] = [
        (0.19, 0.07, 0.23), (0.12, 0.25, 0.75), (0.07, 0.55, 0.95),
        (0.15, 0.82, 0.70), (0.55, 0.95, 0.30), (0.95, 0.85, 0.10),
        (0.98, 0.45, 0.05), (0.75, 0.05, 0.10)
    ]
    let scaled   = t * Float(colormap.count - 1)
    let index    = min(Int(scaled), colormap.count - 2)
    let fraction = scaled - Float(index)
    let c1 = colormap[index], c2 = colormap[index + 1]
    let u8 = { (f: Float) in UInt8(max(0, min(255, f * 255))) }
    return (u8(c1.0 + (c2.0 - c1.0) * fraction),
            u8(c1.1 + (c2.1 - c1.1) * fraction),
            u8(c1.2 + (c2.2 - c1.2) * fraction))
}

// MARK: ─────────────────────────────────────────────────────────────
// MARK: - DepthMeshView
// 使用 RealityKit CustomMaterial + Metal Shader 将照片变为真正的 3D 网格
// ─────────────────────────────────────────────────────────────────
import RealityKit
import Metal

struct DepthMeshView: View {

    let originalImage: CGImage
    let depthFloats:   [Float]
    let depthW:        Int
    let depthH:        Int

    @GestureState private var dragDelta:  CGSize       = .zero
    @State        private var rotation:   SIMD2<Float> = .zero
    @GestureState private var pinchScale: CGFloat      = 1.0
    @State        private var zoom:       Float        = 1.0

    private let cols = 120
    private let rows = 90

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RealityView { content in
                guard let entity = buildMeshEntity() else { return }
                entity.position = [0, 0, -1.5]
                content.add(entity)
            } update: { content in
                guard let entity = content.entities.first else { return }
                let yaw   = rotation.x + Float(dragDelta.width)  * 0.005
                let pitch = rotation.y + Float(dragDelta.height) * 0.005
                entity.orientation = simd_quatf(angle: pitch, axis: [1, 0, 0])
                                   * simd_quatf(angle: yaw,   axis: [0, 1, 0])
                let s = zoom * Float(pinchScale)
                entity.scale = [s, s, s]
            }
            .gesture(
                DragGesture()
                    .updating($dragDelta) { v, state, _ in state = v.translation }
                    .onEnded { v in
                        rotation.x += Float(v.translation.width)  * 0.005
                        rotation.y += Float(v.translation.height) * 0.005
                    }
            )
            .gesture(
                MagnificationGesture()
                    .updating($pinchScale) { v, state, _ in state = v }
                    .onEnded { v in zoom *= Float(v) }
            )
            .ignoresSafeArea()

            VStack {
                Spacer()
                Text("拖动旋转 · 捏合缩放")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 36)
            }
        }
    }

    // MARK: Build Entity
    private func buildMeshEntity() -> ModelEntity? {
        guard
            let depthTex = makeDepthTexture(),
            let photoTex = makePhotoTexture(),
            let mesh     = makeSubdividedPlane(),
            let material = makeCustomMaterial(depthTex: depthTex, photoTex: photoTex)
        else { return nil }
        return ModelEntity(mesh: mesh, materials: [material])
    }

    // MARK: 细分平面网格
    private func makeSubdividedPlane() -> MeshResource? {
        let aspect  = Float(originalImage.width) / max(Float(originalImage.height), 1)
        let planeW: Float = 1.0
        let planeH: Float = planeW / aspect
        let vCols = cols + 1
        let vRows = rows + 1

        var positions = [SIMD3<Float>]()
        var normals   = [SIMD3<Float>]()
        var uvs       = [SIMD2<Float>]()
        var indices   = [UInt32]()
        positions.reserveCapacity(vCols * vRows)

        for row in 0..<vRows {
            for col in 0..<vCols {
                let u = Float(col) / Float(cols)
                let v = Float(row) / Float(rows)
                positions.append([(u - 0.5) * planeW, (0.5 - v) * planeH, 0])
                normals.append([0, 0, 1])
                uvs.append([u, v])
            }
        }
        for row in 0..<rows {
            for col in 0..<cols {
                let tl = UInt32(row * vCols + col)
                let tr = tl + 1
                let bl = tl + UInt32(vCols)
                let br = bl + 1
                indices += [tl, bl, tr, tr, bl, br]
            }
        }

        var desc = MeshDescriptor(name: "DepthPlane")
        desc.positions  = MeshBuffer(positions)
        desc.normals    = MeshBuffer(normals)
        desc.textureCoordinates = MeshBuffer(uvs)
        desc.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [desc])
    }

    // MARK: 深度灰度纹理
    private func makeDepthTexture() -> TextureResource? {
        let w = depthW, h = depthH
        guard !depthFloats.isEmpty, w > 0, h > 0 else { return nil }
        let pixels = depthFloats.map { UInt8(max(0, min(255, $0 * 255))) }
        let cfData = Data(pixels) as CFData
        guard
            let provider = CGDataProvider(data: cfData),
            let gray = CGImage(
                width: w, height: h,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return try? TextureResource(image: gray, options: .init(semantic: .raw))
    }

    // MARK: 原图纹理
    private func makePhotoTexture() -> TextureResource? {
        try? TextureResource(image: originalImage, options: .init(semantic: .color))
    }

    // MARK: CustomMaterial
    private func makeCustomMaterial(
        depthTex: TextureResource,
        photoTex: TextureResource
    ) -> CustomMaterial? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary() else { return nil }
        let geomFn = CustomMaterial.GeometryModifier(named: "depthGeometry", in: library)
        let surfFn = CustomMaterial.SurfaceShader(named: "depthSurface",     in: library)
        guard var mat = try? CustomMaterial(
            surfaceShader: surfFn, geometryModifier: geomFn, lightingModel: .unlit
        ) else { return nil }
        mat.custom.texture    = .init(depthTex)
        mat.baseColor.texture = .init(photoTex)
        return mat
    }
}
