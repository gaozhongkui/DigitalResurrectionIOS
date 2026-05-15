/// FunnyWalkView.swift
///
/// 从视频中提取人物骨骼 → 数学夸张化关键点 → 生成搞怪走路视频
///
/// 阶段一实现：
///   1. Vision 逐帧抠出人物（背景去除）
///   2. MediaPipe 提取 2D 图像坐标骨骼关键点
///   3. 按选定风格对关键点做夸张变换
///   4. 将人物整体按夸张后的髋部偏移量平移
///   5. 叠加彩色骨骼线条，写入输出视频

import SwiftUI
import PhotosUI
import AVKit
import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import MediaPipeTasksVision
import Photos

// MARK: - 搞怪风格

enum FunnyStyle: String, CaseIterable, Identifiable {
    case catwalk = "夸张走秀"
    case penguin = "企鹅走路"
    case bouncy  = "弹跳走路"
    case robot   = "机器人走路"
    case crab    = "螃蟹走路"

    var id: String { rawValue }
    var emoji: String {
        switch self {
        case .catwalk: "🎭"
        case .penguin: "🐧"
        case .bouncy:  "🏀"
        case .robot:   "🤖"
        case .crab:    "🦀"
        }
    }
}

// MARK: - 主视图

struct FunnyWalkView: View {
    @State private var pickerItem:  PhotosPickerItem?
    @State private var sourceURL:   URL?
    @State private var isProcessing = false
    @State private var progress:    Double = 0
    @State private var statusMsg    = "选择一段走路的视频"
    @State private var resultURL:   URL?
    @State private var showResult   = false
    @State private var style:       FunnyStyle = .catwalk
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {

                    // ── 视频预览 ──────────────────────────────────────────
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 220)
                        if let url = sourceURL {
                            VideoPlayer(player: AVPlayer(url: url))
                                .frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        } else {
                            VStack(spacing: 8) {
                                Text("🚶").font(.system(size: 52))
                                Text("选择一段走路视频").foregroundColor(.secondary)
                            }
                        }
                    }

                    // ── 选择视频 ──────────────────────────────────────────
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Label("从相册选择视频", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // ── 搞怪风格 ──────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        Text("搞怪风格").font(.headline)
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible()),
                                      GridItem(.flexible())],
                            spacing: 10
                        ) {
                            ForEach(FunnyStyle.allCases) { s in
                                Button { style = s } label: {
                                    VStack(spacing: 4) {
                                        Text(s.emoji).font(.system(size: 26))
                                        Text(s.rawValue)
                                            .font(.caption2).fontWeight(.medium)
                                            .multilineTextAlignment(.center)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        style == s
                                            ? Color.purple
                                            : Color.secondary.opacity(0.12)
                                    )
                                    .foregroundColor(style == s ? .white : .primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }

                    // ── 处理按钮 ──────────────────────────────────────────
                    Button { startProcess() } label: {
                        HStack {
                            if isProcessing {
                                ProgressView().tint(.white).padding(.trailing, 4)
                            }
                            Text(isProcessing ? "处理中…" : "开始生成搞怪视频")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(
                            sourceURL != nil && !isProcessing ? Color.purple : Color.gray
                        )
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(sourceURL == nil || isProcessing)

                    if isProcessing {
                        VStack(spacing: 6) {
                            ProgressView(value: progress).tint(.purple)
                            Text(statusMsg).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("搞怪走路")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("fw_src_\(UUID().uuidString).mov")
                    try? data.write(to: tmp)
                    await MainActor.run { sourceURL = tmp }
                }
            }
            .fullScreenCover(isPresented: $showResult) {
                if let url = resultURL { FunnyResultView(videoURL: url) }
            }
        }
    }

    private func startProcess() {
        guard let src = sourceURL else { return }
        isProcessing = true; progress = 0
        let sel = style
        Task(priority: .userInitiated) {
            do {
                let out = try await processFunnyWalk(inputURL: src, style: sel) { p, msg in
                    Task { @MainActor in self.progress = p; self.statusMsg = msg }
                }
                await MainActor.run {
                    resultURL = out; isProcessing = false; showResult = true
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    statusMsg = "处理失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - 核心处理管线

private func processFunnyWalk(
    inputURL: URL,
    style: FunnyStyle,
    onProgress: @escaping (Double, String) -> Void
) async throws -> URL {

    // ── MediaPipe 初始化 ───────────────────────────────────────────────
    guard let mpPath = Bundle.main.path(
        forResource: "pose_landmarker_full", ofType: "task") else {
        throw NSError(domain: "FW", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "找不到 pose_landmarker_full.task"])
    }
    let opts = PoseLandmarkerOptions()
    opts.baseOptions.modelAssetPath = mpPath
    opts.runningMode = .video
    opts.numPoses = 1
    let landmarker = try PoseLandmarker(options: opts)

    // ── 视频元数据 ─────────────────────────────────────────────────────
    let asset    = AVURLAsset(url: inputURL)
    let tracks   = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else {
        throw NSError(domain: "FW", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "无视频轨道"])
    }
    let naturalSize = try await track.load(.naturalSize)
    let transform   = try await track.load(.preferredTransform)
    let duration    = try await asset.load(.duration)
    let isRotated   = abs(transform.b) == 1 || abs(transform.c) == 1
    let rawSize     = isRotated
        ? CGSize(width: naturalSize.height, height: naturalSize.width)
        : naturalSize

    // ── 限制最长边 ≤ 1080（4K→1080p 减少约 75% 内存）────────────────
    let maxDim: CGFloat = 1080
    let scaleFactor = min(1.0, maxDim / max(rawSize.width, rawSize.height))
    let outputSize  = scaleFactor < 1.0
        ? CGSize(width:  (rawSize.width  * scaleFactor).rounded(.down),
                 height: (rawSize.height * scaleFactor).rounded(.down))
        : rawSize
    let origRect = CGRect(origin: .zero, size: outputSize)

    // ── 读取器 ─────────────────────────────────────────────────────────
    let reader    = try AVAssetReader(asset: asset)
    let readerOut = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    )
    readerOut.alwaysCopiesSampleData = false
    reader.add(readerOut); reader.startReading()

    // ── 写入器 ─────────────────────────────────────────────────────────
    let outURL   = FileManager.default.temporaryDirectory
        .appendingPathComponent("funny_\(UUID().uuidString).mp4")
    let writer   = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
    let writerIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey:  AVVideoCodecType.h264,
        AVVideoWidthKey:  Int(outputSize.width),
        AVVideoHeightKey: Int(outputSize.height),
    ])
    writerIn.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: writerIn,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey  as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
        ]
    )
    writer.add(writerIn); writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    // ── Vision + CIContext ─────────────────────────────────────────────
    let segReq     = VNGeneratePersonInstanceMaskRequest()
    let seqHandler = VNSequenceRequestHandler()
    // cacheIntermediates: false 防止 CI 累积中间渲染缓存
    let ciCtx = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates:  false,
    ])

    let totalSec = max(duration.seconds, 0.01)
    var frameIdx = 0

    while let sb = readerOut.copyNextSampleBuffer() {

        // ── autoreleasepool：每帧所有 ObjC 对象在此作用域结束时立即释放 ──
        // 这是解决逐帧视频处理内存积压的关键手段
        var frameResult: (CVPixelBuffer, CMTime)? = nil

        autoreleasepool {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            let ptime = CMSampleBufferGetPresentationTimeStamp(sb)

            // 1. 人物分割（在原始分辨率上运行，精度更高）
            try? seqHandler.perform([segReq], on: pb, orientation: .up)

            // 2. 原始帧 CIImage → 旋转修正 → 缩放到 outputSize
            var origCI = CIImage(cvPixelBuffer: pb)
            if isRotated {
                origCI = origCI.transformed(by: transform)
                    .transformed(by: CGAffineTransform(
                        translationX: 0, y: -origCI.extent.width))
            }
            if scaleFactor < 1.0 {
                origCI = origCI.transformed(
                    by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
            }
            origCI = origCI.cropped(to: origRect)

            // 3. MediaPipe 骨骼（归一化坐标与分辨率无关）
            var pts2D: [SIMD2<Float>]? = nil
            let tsMs = Int(ptime.seconds * 1000)
            if let mpImg = try? MPImage(pixelBuffer: pb),
               let res = try? landmarker.detect(
                   videoFrame: mpImg, timestampInMilliseconds: tsMs),
               let lm = res.landmarks.first {
                pts2D = lm.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
            }

            // 4. 骨骼搞怪变换（只影响骨骼线位置，不影响图像）
            let modPts = pts2D.map {
                applyFunnyTransform(pts: $0, style: style, frameIdx: frameIdx)
            }

            // 5. 分割 mask → 缩放到 outputSize
            var maskCI: CIImage? = nil
            if #available(iOS 17.0, *),
               let obs = segReq.results?.first as? VNInstanceMaskObservation {
                let fh = VNImageRequestHandler(
                    cvPixelBuffer: pb, orientation: .up, options: [:])
                if let mPB = try? obs.generateScaledMaskForImage(
                    forInstances: obs.allInstances, from: fh) {
                    var mCI = CIImage(cvPixelBuffer: mPB)
                    if scaleFactor < 1.0 {
                        mCI = mCI.transformed(
                            by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
                    }
                    maskCI = mCI
                        .applyingFilter("CIGaussianBlur",
                                        parameters: [kCIInputRadiusKey: 1.5])
                        .cropped(to: origRect)
                }
            } else {
                // iOS 16 降级
                let fb = VNGeneratePersonSegmentationRequest()
                fb.qualityLevel = .balanced
                fb.outputPixelFormat = kCVPixelFormatType_OneComponent8
                let fbh = VNImageRequestHandler(
                    cvPixelBuffer: pb, orientation: .up, options: [:])
                try? fbh.perform([fb])
                if let obs = fb.results?.first {
                    let raw = CIImage(cvPixelBuffer: obs.pixelBuffer)
                    let sx  = outputSize.width  / raw.extent.width
                    let sy  = outputSize.height / raw.extent.height
                    maskCI = raw.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                        .applyingFilter("CIGaussianBlur",
                                        parameters: [kCIInputRadiusKey: 1.5])
                        .cropped(to: origRect)
                }
            }

            // 7. CoreImage 合成 + 风格变形（直接作用于人物图像）
            let compositeCI = buildComposite(
                orig: origCI, mask: maskCI,
                style: style, frameIdx: frameIdx, size: outputSize)

            // 8. 从 adaptor pool 取 pixel buffer（复用内存，不每帧 malloc）
            guard let pool = adaptor.pixelBufferPool else { return }
            var outPB: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB) == kCVReturnSuccess,
                  let outPB else { return }

            ciCtx.render(compositeCI,
                         to: outPB,
                         bounds: origRect,
                         colorSpace: CGColorSpaceCreateDeviceRGB())

            // 9. CGContext 直接在 pixel buffer 上画骨骼
            if let sk = modPts {
                drawSkeletonOnBuffer(outPB, pts: sk, size: outputSize, style: style)
            }

            frameResult = (outPB, ptime)
        }
        // ── autoreleasepool 结束：当帧所有中间对象已释放 ──────────────

        // 等待写入器就绪（在 pool 外 await，不阻塞线程）
        if let (outPB, ptime) = frameResult {
            while !writerIn.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 500_000)
            }
            adaptor.append(outPB, withPresentationTime: ptime)
        }

        frameIdx += 1
        if frameIdx % 8 == 0,
           let sb2 = frameResult {
            let prog = min(sb2.1.seconds / totalSec, 0.98)
            onProgress(prog, "处理第 \(frameIdx) 帧 (\(Int(prog * 100))%)")
        }
    }

    writerIn.markAsFinished()
    await writer.finishWriting()
    if let err = writer.error { throw err }
    onProgress(1.0, "✅ 完成！共 \(frameIdx) 帧")
    return outURL
}

// MARK: - 搞怪变换：对 2D 归一化关键点做夸张化

/// pts：MediaPipe 2D 图像归一化坐标（0~1，左上角为原点，y 向下）
private func applyFunnyTransform(
    pts: [SIMD2<Float>],
    style: FunnyStyle,
    frameIdx: Int
) -> [SIMD2<Float>] {
    guard pts.count >= 29 else { return pts }
    var p = pts

    // 计算关键参考点
    let hipCenter  = (p[23] + p[24]) * 0.5
    let shoulderCX = (p[11].x + p[12].x) * 0.5

    switch style {

    case .catwalk:
        // 髋部横向摆动 × 2.5（相对于图像中心 0.5 的偏移放大）
        for i in [23, 24] {
            p[i].x = 0.5 + (p[i].x - 0.5) * 2.5
        }
        // 手腕甩动幅度 × 2
        for i in [13, 14, 15, 16] {
            p[i].x = hipCenter.x + (p[i].x - hipCenter.x) * 2.0
            p[i].y = hipCenter.y + (p[i].y - hipCenter.y) * 1.5
        }

    case .penguin:
        // 手臂固定：手腕压到腰侧，肘部向外撑
        p[13] = SIMD2(p[11].x - 0.08, p[11].y + 0.12) // 左肘向外
        p[14] = SIMD2(p[12].x + 0.08, p[12].y + 0.12) // 右肘向外
        p[15] = SIMD2(p[23].x - 0.04, p[23].y - 0.02) // 左腕贴腰
        p[16] = SIMD2(p[24].x + 0.04, p[24].y - 0.02) // 右腕贴腰
        // 躯干整体左右摇摆（正弦波）
        let sway = sin(Float(frameIdx) * 0.35) * 0.04
        for i in [11, 12, 13, 14, 15, 16, 23, 24] {
            p[i].x = max(0, min(1, p[i].x + sway))
        }

    case .bouncy:
        // 上下弹跳：整体 y 加正弦波（y 向下为正，减小 = 向上弹）
        let bounce = abs(sin(Float(frameIdx) * 0.6)) * 0.06
        for i in 0..<p.count {
            p[i].y -= bounce
        }
        // 手臂跟随甩动
        for i in [13, 14, 15, 16] {
            p[i].x = hipCenter.x + (p[i].x - hipCenter.x) * 1.8
        }

    case .robot:
        // 关节坐标量化（每 0.05 一格），让动作变成机械跳帧感
        let step: Float = 0.05
        for i in [13, 14, 15, 16, 25, 26, 27, 28] {
            p[i].x = (p[i].x / step).rounded() * step
            p[i].y = (p[i].y / step).rounded() * step
        }

    case .crab:
        // 腿部横向大幅扩展（像螃蟹横着走）
        for i in [25, 26] { // 膝盖
            p[i].x = hipCenter.x + (p[i].x - hipCenter.x) * 2.2
        }
        for i in [27, 28] { // 脚踝
            p[i].x = hipCenter.x + (p[i].x - hipCenter.x) * 2.8
        }
        // 肩部也横向拉开
        p[11].x = shoulderCX + (p[11].x - shoulderCX) * 1.5
        p[12].x = shoulderCX + (p[12].x - shoulderCX) * 1.5
    }

    return p
}

// MARK: - 计算整体平移量

/// 用髋部的夸张偏移量平移整个人物图像，增强搞怪感
private func computeShift(
    orig: [SIMD2<Float>]?,
    mod: [SIMD2<Float>]?,
    size: CGSize
) -> CGPoint {
    guard let o = orig, let m = mod,
          o.count >= 25, m.count >= 25 else { return .zero }

    let origHipX = (o[23].x + o[24].x) * 0.5
    let modHipX  = (m[23].x + m[24].x) * 0.5
    let origHipY = (o[23].y + o[24].y) * 0.5
    let modHipY  = (m[23].y + m[24].y) * 0.5

    return CGPoint(
        x: CGFloat(modHipX - origHipX) * size.width,
        y: CGFloat(modHipY - origHipY) * size.height
    )
}

// MARK: - 合成搞怪帧

private func buildFunnyFrame(
    orig: CIImage,
    mask: CIImage?,
    shift: CGPoint,
    skeleton: [SIMD2<Float>]?,
    size: CGSize,
    ciCtx: CIContext,
    style: FunnyStyle
) -> CIImage {
    let rect = CGRect(origin: .zero, size: size)

    // 人物（带 alpha 的抠图）
    var personCI: CIImage = orig
    if let m = mask {
        personCI = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey:           orig,
            kCIInputBackgroundImageKey: CIImage(color: CIColor(red: 0, green: 0,
                                                               blue: 0, alpha: 0))
                                            .cropped(to: rect),
            kCIInputMaskImageKey:       m,
        ])?.outputImage ?? orig
    }

    // 移位：CIImage y 轴向上，与屏幕 y 相反，所以 y 取负
    let shifted = personCI.transformed(
        by: CGAffineTransform(translationX: shift.x, y: -shift.y)
    )

    // 合成：深色背景 + 移位人物
    let bgCI = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.1))
        .cropped(to: rect)
    let composite = CIFilter(name: "CISourceOverCompositing", parameters: [
        kCIInputImageKey:           shifted.cropped(to: rect),
        kCIInputBackgroundImageKey: bgCI,
    ])?.outputImage ?? bgCI

    // 骨骼线条（UIKit 绘制后转回 CIImage）
    guard let sk = skeleton,
          let cgBase = ciCtx.createCGImage(composite, from: rect) else {
        return composite
    }
    let baseUI  = UIImage(cgImage: cgBase)
    let renderer = UIGraphicsImageRenderer(size: size)
    let withSk = renderer.image { ctx in
        baseUI.draw(at: .zero)
        drawSkeleton(ctx.cgContext, pts: sk, size: size, style: style)
    }
    return CIImage(image: withSk) ?? composite
}

// MARK: - CoreImage 合成 + 风格变形

/// 对抠出的人物图像直接施加仿射变换，让身体本身产生搞怪效果
private func buildComposite(
    orig: CIImage,
    mask: CIImage?,
    style: FunnyStyle,
    frameIdx: Int,
    size: CGSize
) -> CIImage {
    let rect   = CGRect(origin: .zero, size: size)
    let cx     = size.width  / 2   // 图像中心 X
    let cy     = size.height / 2   // 图像中心 Y（CIImage Y 轴朝上）

    // 1. 用 mask 把人物从背景里抠出（背景透明）
    var personCI: CIImage = orig
    if let m = mask {
        personCI = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey:           orig,
            kCIInputBackgroundImageKey: CIImage(color: CIColor(red: 0, green: 0,
                                                               blue: 0, alpha: 0))
                                            .cropped(to: rect),
            kCIInputMaskImageKey:       m,
        ])?.outputImage ?? orig
    }

    // 2. 按风格计算对人物图像的仿射变换
    let (tx, ty, sx, sy) = styleBodyTransform(style: style, frameIdx: frameIdx, size: size)

    // 以图像中心为锚点做缩放，再做平移（CIImage Y 轴朝上，ty 直接用）
    let transform = CGAffineTransform.identity
        .translatedBy(x: cx, y: cy)
        .scaledBy(x: sx, y: sy)
        .translatedBy(x: -cx, y: -cy)
        .translatedBy(x: tx, y: ty)

    let deformed = personCI.transformed(by: transform)

    // 3. 深色背景 + 变形人物叠加
    let bgCI = CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.1))
        .cropped(to: rect)
    return CIFilter(name: "CISourceOverCompositing", parameters: [
        kCIInputImageKey:           deformed.cropped(to: rect),
        kCIInputBackgroundImageKey: bgCI,
    ])?.outputImage?.cropped(to: rect) ?? bgCI
}

// MARK: - 风格变形参数

/// 返回 (tx, ty, scaleX, scaleY)，在 CIImage 坐标系（Y 轴向上）
/// tx/ty 单位为像素；scale 以图像中心为锚点
private func styleBodyTransform(
    style: FunnyStyle,
    frameIdx: Int,
    size: CGSize
) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
    let fi = Double(frameIdx)
    switch style {

    case .bouncy:
        // 整体上下弹跳：CIImage Y 向上，正值 = 向上跳
        let bounceY = CGFloat(abs(sin(fi * 0.5))) * size.height * 0.10
        // 落地时横向轻微压扁，跳起时拉长
        let phase   = abs(sin(fi * 0.5))
        let sY      = 1.0 + (phase - 0.5) * 0.12   // 0.94 ~ 1.06
        let sX      = 2.0 - sY                       // 反向：压扁时变宽
        return (0, bounceY, sX, sY)

    case .catwalk:
        // 夸张左右摇摆，像走秀
        let swayX = CGFloat(sin(fi * 0.25)) * size.width * 0.13
        // 摆到一侧时身体略微拉高
        let sY    = 1.0 + abs(CGFloat(sin(fi * 0.25))) * 0.06
        return (swayX, 0, 1.0, sY)

    case .penguin:
        // 横向压缩（矮胖）+ 小幅左右摇晃
        let swayX = CGFloat(sin(fi * 0.40)) * size.width * 0.05
        return (swayX, 0, 1.20, 0.88)   // 宽×1.2，高×0.88

    case .robot:
        // 把位置量化到固定格子 → 机械跳跃感
        let stepX = size.width  * 0.07
        let stepY = size.height * 0.04
        let rawX  = CGFloat(sin(fi * 0.30)) * size.width  * 0.08
        let rawY  = CGFloat(abs(cos(fi * 0.40))) * size.height * 0.05
        let qX    = (rawX / stepX).rounded() * stepX
        let qY    = (rawY / stepY).rounded() * stepY
        return (qX, qY, 1.0, 1.0)

    case .crab:
        // 身体横向拉宽 + 向侧面来回平移（螃蟹横着走）
        let crabbX = CGFloat(sin(fi * 0.18)) * size.width * 0.18
        return (crabbX, 0, 1.35, 0.80)  // 宽×1.35，高×0.80
    }
}

// MARK: - 直接在 CVPixelBuffer 上用 CGContext 绘制骨骼

/// 锁定 CVPixelBuffer，创建 CGContext，Y 翻转后调用 drawSkeleton
/// （CVPixelBuffer 与 MediaPipe 坐标系 Y 轴方向相同：向下，无需翻转）
private func drawSkeletonOnBuffer(
    _ pixelBuffer: CVPixelBuffer,
    pts: [SIMD2<Float>],
    size: CGSize,
    style: FunnyStyle
) {
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

    // BGRA → premultipliedFirst + byteOrder32Little
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                   | CGBitmapInfo.byteOrder32Little.rawValue

    guard let ctx = CGContext(
        data:             baseAddr,
        width:            Int(size.width),
        height:           Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow:      bytesPerRow,
        space:            CGColorSpaceCreateDeviceRGB(),
        bitmapInfo:       bitmapInfo
    ) else { return }

    // CVPixelBuffer 原点在左上、Y 向下，与 MediaPipe 坐标一致 → 不需要额外翻转
    drawSkeleton(ctx, pts: pts, size: size, style: style)
}

// MARK: - 骨骼绘制

private let skeletonBones: [(Int, Int, UIColor)] = [
    // 躯干 白
    (11, 12, .white), (11, 23, .white), (12, 24, .white), (23, 24, .white),
    // 左臂 青
    (11, 13, .cyan), (13, 15, .cyan),
    // 右臂 橙
    (12, 14, UIColor.orange), (14, 16, UIColor.orange),
    // 左腿 绿
    (23, 25, .green), (25, 27, .green),
    // 右腿 黄
    (24, 26, .yellow), (26, 28, .yellow),
]

private func drawSkeleton(
    _ ctx: CGContext,
    pts: [SIMD2<Float>],
    size: CGSize,
    style: FunnyStyle
) {
    guard pts.count >= 29 else { return }

    // 骨骼连线
    for (a, b, color) in skeletonBones {
        let pa = CGPoint(x: CGFloat(pts[a].x) * size.width,
                         y: CGFloat(pts[a].y) * size.height)
        let pb = CGPoint(x: CGFloat(pts[b].x) * size.width,
                         y: CGFloat(pts[b].y) * size.height)

        ctx.setStrokeColor(color.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(4)
        ctx.setLineCap(.round)
        ctx.move(to: pa); ctx.addLine(to: pb)
        ctx.strokePath()
    }

    // 关节圆点
    let jointIndices = [11, 12, 13, 14, 15, 16, 23, 24, 25, 26, 27, 28]
    for i in jointIndices {
        let p = CGPoint(x: CGFloat(pts[i].x) * size.width,
                        y: CGFloat(pts[i].y) * size.height)
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
    }
}

// MARK: - 辅助

private func makeFWPixelBuffer(size: CGSize) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(
        kCFAllocatorDefault,
        Int(size.width), Int(size.height),
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
        &pb
    )
    return pb
}

// MARK: - 结果视图

struct FunnyResultView: View {
    let videoURL: URL
    @Environment(\.dismiss) var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let p = player {
                VideoPlayer(player: p).ignoresSafeArea()
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.white.opacity(0.85))
                            .padding()
                    }
                }
                Spacer()
                Button { saveVideo() } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .foregroundColor(.white)
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear { setupPlayer() }
        .onDisappear { player?.pause() }
    }

    private func setupPlayer() {
        let p = AVPlayer(url: videoURL)
        p.play(); self.player = p
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: p.currentItem, queue: .main
        ) { _ in p.seek(to: .zero); p.play() }
    }

    private func saveVideo() {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(
                    atFileURL: self.videoURL)
            }
        }
    }
}
