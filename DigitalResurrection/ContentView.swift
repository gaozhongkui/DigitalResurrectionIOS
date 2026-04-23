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
    case modelNotFound, pixelBufferFailed, noOutput, colorFailed
    var errorDescription: String? {
        switch self {
        case .modelNotFound:    return "找不到模型文件"
        case .pixelBufferFailed: return "图像预处理失败"
        case .noOutput:         return "模型未返回深度图"
        case .colorFailed:      return "深度图转换失败"
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @State private var pickerItem:    PhotosPickerItem? = nil
    @State private var originalImage: CGImage?          = nil
    @State private var depthColored:  CGImage?          = nil
    @State private var isProcessing   = false
    @State private var processMs:     Double?           = nil
    @State private var mode:          DepthMode         = .original
    @State private var splitRatio:    CGFloat           = 0.5
    @State private var errorMsg:      String?           = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.top, 54)
                Spacer(minLength: 16)
                imageArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if originalImage != nil { modeBar.padding(.top, 14) }
                actionBar.padding(.top, 12).padding(.bottom, 30)
            }
            if isProcessing { loadingOverlay }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadAndRun(item) }
        }
    }

    // MARK: Header

    var header: some View {
        VStack(spacing: 3) {
            Text("深度估计")
                .font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
            Text("Depth Anything V2 · Small F16")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.3)).tracking(1.5)
        }
    }

    // MARK: Image Area

    @ViewBuilder
    var imageArea: some View {
        if let orig = originalImage {
            GeometryReader { geo in
                ZStack {
                    switch mode {
                    case .original:
                        fit(orig)
                    case .colorized:
                        fit(depthColored ?? orig).opacity(depthColored == nil ? 0.3 : 1)
                    case .overlay:
                        fit(orig)
                        if let d = depthColored { fit(d).blendMode(.screen).opacity(0.82) }
                    case .compare:
                        compareView(size: geo.size)
                    }

                    // Time badge
                    if let ms = processMs, mode != .compare {
                        VStack { Spacer()
                            HStack { Spacer()
                                Text(String(format: "%.0f ms", ms))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(.black.opacity(0.5), in: Capsule())
                                    .padding(12)
                            }
                        }
                    }
                    // Error
                    if let err = errorMsg {
                        Text(err).font(.system(size: 13)).foregroundStyle(.red)
                            .padding(10).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            emptyState
        }
    }

    func fit(_ img: CGImage) -> some View {
        Image(img, scale: 1, orientation: .up, label: Text(""))
            .resizable().scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Compare Slider

    func compareView(size: CGSize) -> some View {
        let w = size.width, h = size.height
        return ZStack {
            // Depth behind
            if let d = depthColored {
                Image(d, scale: 1, orientation: .up, label: Text(""))
                    .resizable().scaledToFill()
                    .frame(width: w, height: h).clipped()
            }
            // Original masked to right side
            if let orig = originalImage {
                Image(orig, scale: 1, orientation: .up, label: Text(""))
                    .resizable().scaledToFill()
                    .frame(width: w, height: h).clipped()
                    .mask {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: w * splitRatio)
                            Color.black
                        }
                    }
            }
            // Divider + thumb
            ZStack {
                Rectangle().fill(.white.opacity(0.9)).frame(width: 2, height: h)
                Circle().fill(.white).frame(width: 38, height: 38).shadow(radius: 6)
                    .overlay {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                    }
            }
            .position(x: w * splitRatio, y: h / 2)
            // Labels
            VStack {
                HStack {
                    label("深度图"); Spacer(); label("原图")
                }
                .padding(.horizontal, 12).padding(.top, 10)
                Spacer()
            }
        }
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            splitRatio = max(0.02, min(0.98, v.location.x / w))
        })
        .frame(width: w, height: h)
    }

    func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
    }

    // MARK: Mode Bar

    var modeBar: some View {
        HStack(spacing: 8) {
            ForEach(DepthMode.allCases, id: \.self) { m in
                let active   = mode == m
                let enabled  = depthColored != nil || m == .original
                Button { withAnimation(.easeInOut(duration: 0.2)) { mode = m } } label: {
                    VStack(spacing: 5) {
                        Image(systemName: m.icon).font(.system(size: 17))
                        Text(m.rawValue).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(active ? .black : .white.opacity(enabled ? 0.6 : 0.2))
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(active ? .white : .white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!enabled)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Action Bar

    var actionBar: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("选择照片", systemImage: "photo.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
            }
            if originalImage != nil {
                Button {
                    guard let img = originalImage else { return }
                    Task { await estimateDepth(img) }
                } label: {
                    Label(isProcessing ? "处理中" : "估计深度",
                          systemImage: isProcessing ? "hourglass" : "wand.and.stars")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(Color(red: 0.2, green: 0.45, blue: 1.0),
                                    in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isProcessing)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: Empty / Loading

    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.metering.spot")
                .font(.system(size: 64)).foregroundStyle(.white.opacity(0.1))
            Text("选择一张照片").font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
            Text("AI 将自动分析场景深度")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().progressViewStyle(.circular).tint(.white).scaleEffect(1.5)
                Text("正在估计深度…")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    // MARK: Actions

    func loadAndRun(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let src  = CGImageSourceCreateWithData(data as CFData, nil),
              let img  = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        originalImage = img
        depthColored  = nil
        processMs     = nil
        errorMsg      = nil
        withAnimation { mode = .original }
        await estimateDepth(img)
    }

    func estimateDepth(_ cgImage: CGImage) async {
        isProcessing = true
        errorMsg     = nil
        let t0 = Date()
        do {
            let colored  = try await depthInference(cgImage)
            processMs    = Date().timeIntervalSince(t0) * 1000
            depthColored = colored
            withAnimation(.easeInOut(duration: 0.35)) { mode = .compare; splitRatio = 0.5 }
        } catch {
            errorMsg = error.localizedDescription
        }
        isProcessing = false
    }
}

// MARK: - Inference（Vision 框架：自动处理图像缩放与 I/O 格式）

nonisolated func depthInference(_ cgImage: CGImage) async throws -> CGImage {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let url = Bundle.main.url(forResource: "DepthAnythingV2SmallF16",
                                                withExtension: "mlmodelc") else {
                    throw DepthError.modelNotFound
                }
                let cfg = MLModelConfiguration()
                cfg.computeUnits = .all
                let mlModel = try MLModel(contentsOf: url, configuration: cfg)
                let vnModel = try VNCoreMLModel(for: mlModel)

                var depthBuf: CVPixelBuffer? = nil
                var reqErr:   Error?         = nil

                let request = VNCoreMLRequest(model: vnModel) { req, err in
                    reqErr = err
                    // imageType 输出 → VNPixelBufferObservation
                    if let obs = req.results?.first as? VNPixelBufferObservation {
                        depthBuf = obs.pixelBuffer
                    }
                    // 兜底：featureValue 形式
                    if depthBuf == nil,
                       let obs = req.results?.first as? VNCoreMLFeatureValueObservation {
                        depthBuf = obs.featureValue.imageBufferValue
                    }
                }
                request.imageCropAndScaleOption = .scaleFill

                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

                if let e = reqErr { throw e }
                guard let buf = depthBuf      else { throw DepthError.noOutput   }
                guard let img = colorize(buf) else { throw DepthError.colorFailed }
                cont.resume(returning: img)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

// MARK: - Image Helpers (nonisolated — pure computation, no actor state)

nonisolated func pixelBuffer(from cgImage: CGImage, w: Int, h: Int) -> CVPixelBuffer? {
    let attrs: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]
    var pb: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                              kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
          let buf = pb else { return nil }

    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }

    guard let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(buf), width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }

    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buf
}

nonisolated func colorize(_ buf: CVPixelBuffer) -> CGImage? {
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }

    let w   = CVPixelBufferGetWidth(buf)
    let h   = CVPixelBufferGetHeight(buf)
    let bpr = CVPixelBufferGetBytesPerRow(buf)
    let fmt = CVPixelBufferGetPixelFormatType(buf)
    guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }

    // ── 1. 把各种格式统一读成 [Float] ──────────────────────────
    var vals = [Float](repeating: 0, count: w * h)
    switch fmt {

    case kCVPixelFormatType_OneComponent16Half:          // Float16 灰度（模型原生输出）
        let stride = bpr / 2
        let ptr = base.bindMemory(to: Float16.self, capacity: stride * h)
        for y in 0..<h { for x in 0..<w { vals[y*w+x] = Float(ptr[y*stride+x]) } }

    case kCVPixelFormatType_OneComponent32Float:         // Float32 灰度
        let stride = bpr / 4
        let ptr = base.bindMemory(to: Float32.self, capacity: stride * h)
        for y in 0..<h { for x in 0..<w { vals[y*w+x] = ptr[y*stride+x] } }

    case kCVPixelFormatType_OneComponent8:               // UInt8 灰度
        let ptr = base.bindMemory(to: UInt8.self, capacity: bpr * h)
        for y in 0..<h { for x in 0..<w { vals[y*w+x] = Float(ptr[y*bpr+x]) / 255.0 } }

    default:                                             // 兜底：当 Float16 处理
        let stride = bpr / 2
        let ptr = base.bindMemory(to: Float16.self, capacity: stride * h)
        for y in 0..<h { for x in 0..<w { vals[y*w+x] = Float(ptr[y*stride+x]) } }
    }

    // ── 2. 归一化 ──────────────────────────────────────────────
    let finite = vals.filter(\.isFinite)
    guard !finite.isEmpty else { return nil }
    let lo    = finite.min()!
    let hi    = finite.max()!
    let range = Swift.max(hi - lo, 1e-6)

    // ── 3. Turbo 色谱 → RGBA ────────────────────────────────────
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    for i in 0..<(w * h) {
        let t = (vals[i] - lo) / range
        let c = turbo(t)
        rgba[i*4] = c.0; rgba[i*4+1] = c.1; rgba[i*4+2] = c.2; rgba[i*4+3] = 255
    }

    let data = Data(rgba)
    guard let prov = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

// Turbo colormap: blue (far) → cyan → green → yellow → red (near)
nonisolated func turbo(_ t: Float) -> (UInt8, UInt8, UInt8) {
    let s: [(Float,Float,Float)] = [
        (0.190, 0.071, 0.232),
        (0.070, 0.370, 0.990),
        (0.070, 0.780, 0.870),
        (0.220, 0.940, 0.470),
        (0.760, 0.970, 0.130),
        (0.990, 0.740, 0.050),
        (0.980, 0.380, 0.070),
        (0.740, 0.050, 0.110),
    ]
    let v = Swift.max(0, Swift.min(1, t)) * Float(s.count - 1)
    let i = Swift.min(Int(v), s.count - 2)
    let f = v - Float(i)
    let (r0,g0,b0) = s[i]; let (r1,g1,b1) = s[i+1]
    let clamp = { (x: Float) in UInt8(Swift.max(0, Swift.min(255, x * 255))) }
    return (clamp(r0 + (r1-r0)*f), clamp(g0 + (g1-g0)*f), clamp(b0 + (b1-b0)*f))
}

#Preview { ContentView() }
