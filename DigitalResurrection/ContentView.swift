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
    @State private var isProcessing   = false
    @State private var processMs:     Double?           = nil
    @State private var mode:          DepthMode         = .original
    @State private var splitRatio:    CGFloat           = 0.5
    @State private var errorMsg:      String?           = nil

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
    }

    private var headerView: some View {
        VStack(spacing: 3) {
            Text("深度估计").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
            Text("Depth Anything V2 · Pro Fix").font(.system(size: 11)).foregroundStyle(.red.opacity(0.7)).tracking(1.5)
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
                .overlay(Circle().fill(.white).frame(width: 36, height: 36).shadow(radius: 4)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.caption2).bold().foregroundStyle(.black)))
                .position(x: size.width * splitRatio, y: size.height / 2)
        }
        .gesture(DragGesture().onChanged { splitRatio = max(0, min(1, $0.location.x / size.width)) })
    }

    private func fitImageFull(_ img: CGImage, size: CGSize) -> some View {
        Image(img, scale: 1, orientation: .up, label: Text(""))
            .resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
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
        HStack {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("更换照片", systemImage: "photo.fill")
                    .font(.headline).foregroundStyle(.black).frame(maxWidth: .infinity).padding().background(.white, in: Capsule())
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
        ZStack { Color.black.opacity(0.6).ignoresSafeArea(); ProgressView("分析中...").tint(.white).foregroundStyle(.white) }
    }

    private func handleImageSelection(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data), let cgImage = uiImage.cgImage else { return }
        await MainActor.run { self.originalImage = cgImage; self.isProcessing = true }
        let start = Date()
        do {
            let depth = try await performInference(cgImage)
            await MainActor.run {
                self.depthColored = depth
                self.processMs = Date().timeIntervalSince(start) * 1000
                self.mode = .compare
                self.isProcessing = false
            }
        } catch {
            await MainActor.run { self.errorMsg = error.localizedDescription; self.isProcessing = false }
        }
    }
}

// MARK: - Inference Logic
nonisolated func performInference(_ cgImage: CGImage) async throws -> CGImage {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let modelURL = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") else {
                    cont.resume(throwing: DepthError.modelNotFound); return
                }
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let model = try VNCoreMLModel(for: MLModel(contentsOf: modelURL, configuration: config))
                
                let request = VNCoreMLRequest(model: model) { req, _ in
                    guard let results = req.results else { return }
                    
                    var pixelBuffer: CVPixelBuffer?
                    if let obs = results.first as? VNPixelBufferObservation {
                        pixelBuffer = obs.pixelBuffer
                    } else if let obs = results.first as? VNCoreMLFeatureValueObservation {
                        pixelBuffer = obs.featureValue.imageBufferValue
                    }
                    
                    if let buffer = pixelBuffer, let colored = processAndColorize(buffer) {
                        cont.resume(returning: colored)
                    } else {
                        cont.resume(throwing: DepthError.noOutput)
                    }
                }
                request.imageCropAndScaleOption = .scaleFill
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
            } catch { cont.resume(throwing: error) }
        }
    }
}

nonisolated func processAndColorize(_ buffer: CVPixelBuffer) -> CGImage? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bpr = CVPixelBufferGetBytesPerRow(buffer)
    let format = CVPixelBufferGetPixelFormatType(buffer)
    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }

    var floatValues = [Float]()
    floatValues.reserveCapacity(width * height)

    // 修复 1: 严格按照行步长读取，防止内存偏移导致数据错误
    if format == kCVPixelFormatType_OneComponent16Half {
        let ptr = baseAddress.bindMemory(to: Float16.self, capacity: height * (bpr / 2))
        let stride = bpr / 2
        for y in 0..<height {
            for x in 0..<width {
                floatValues.append(Float(ptr[y * stride + x]))
            }
        }
    } else {
        let ptr = baseAddress.bindMemory(to: Float32.self, capacity: height * (bpr / 4))
        let stride = bpr / 4
        for y in 0..<height {
            for x in 0..<width {
                floatValues.append(ptr[y * stride + x])
            }
        }
    }

    // 修复 2: 鲁棒性归一化，剔除极值并拉开对比度
    let sorted = floatValues.filter { $0.isFinite }.sorted()
    guard !sorted.isEmpty else { return nil }
    let vMin = sorted[Int(Double(sorted.count) * 0.03)]
    let vMax = sorted[Int(Double(sorted.count) * 0.97)]
    let range = max(vMax - vMin, 1e-6)

    var rgbaData = [UInt8](repeating: 255, count: width * height * 4)
    for i in 0..<(width * height) {
        // 强制映射到 0.0 - 1.0 范围
        let normalized = max(0, min(1, (floatValues[i] - vMin) / range))
        let (r, g, b) = getTurboColor(normalized)
        rgbaData[i*4] = r; rgbaData[i*4+1] = g; rgbaData[i*4+2] = b; rgbaData[i*4+3] = 255
    }

    let cfData = Data(rgbaData) as CFData
    guard let provider = CGDataProvider(data: cfData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

func getTurboColor(_ t: Float) -> (UInt8, UInt8, UInt8) {
    let colormap: [(Float, Float, Float)] = [
        (0.19, 0.07, 0.23), (0.12, 0.25, 0.75), (0.07, 0.55, 0.95),
        (0.15, 0.82, 0.70), (0.55, 0.95, 0.30), (0.95, 0.85, 0.10),
        (0.98, 0.45, 0.05), (0.75, 0.05, 0.10)
    ]
    let scaled = t * Float(colormap.count - 1)
    let index = min(Int(scaled), colormap.count - 2)
    let fraction = scaled - Float(index)
    let c1 = colormap[index], c2 = colormap[index+1]
    let toUInt8 = { (f: Float) in UInt8(max(0, min(255, f * 255))) }
    return (toUInt8(c1.0 + (c2.0 - c1.0) * fraction),
            toUInt8(c1.1 + (c2.1 - c1.1) * fraction),
            toUInt8(c1.2 + (c2.2 - c1.2) * fraction))
}
