/// VideoDanceView.swift
///
/// 第一步：从视频中抠出人物，替换背景颜色
///
/// 技术栈：
///   - Vision VNGeneratePersonSegmentationRequest  —— 逐帧人物分割
///   - CoreImage CIBlendWithMask                   —— 人物 + 自定义背景合成
///   - AVAssetReader / AVAssetWriter               —— 视频帧读写

import SwiftUI
import PhotosUI
import AVKit
import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos

// MARK: - 主视图

struct VideoDanceView: View {

    @State private var pickerItem:  PhotosPickerItem?
    @State private var sourceURL:   URL?
    @State private var isProcessing = false
    @State private var progress:    Double = 0
    @State private var statusMsg    = "请选择一段包含人物的视频"
    @State private var resultURL:   URL?
    @State private var showResult   = false
    @State private var bgIndex      = 0

    static let bgOptions: [(label: String, ci: CIColor, ui: Color)] = [
        ("纯黑",   CIColor(red: 0,    green: 0,    blue: 0),    .black),
        ("深蓝",   CIColor(red: 0.05, green: 0.15, blue: 0.45),
                   Color(red: 0.05, green: 0.15, blue: 0.45)),
        ("霓虹紫", CIColor(red: 0.35, green: 0.05, blue: 0.6),
                   Color(red: 0.35, green: 0.05, blue: 0.6)),
        ("绿幕",   CIColor(red: 0,    green: 0.75, blue: 0.2),
                   Color(red: 0, green: 0.75, blue: 0.2)),
    ]

    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {

                    // ── 视频预览 ─────────────────────────────────────────
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 220)

                        if let url = sourceURL {
                            VideoPlayer(player: AVPlayer(url: url))
                                .frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        } else {
                            VStack(spacing: 10) {
                                Image(systemName: "person.fill.viewfinder")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("选择视频后显示预览")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // ── 选择视频 ─────────────────────────────────────────
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Label("从相册选择视频", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                            .padding(14)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // ── 背景颜色 ─────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        Text("替换背景").font(.headline)
                        HStack(spacing: 16) {
                            ForEach(0..<Self.bgOptions.count, id: \.self) { i in
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(Self.bgOptions[i].ui)
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Circle().stroke(
                                                bgIndex == i ? Color.white : Color.clear,
                                                lineWidth: 3)
                                        )
                                        .shadow(radius: bgIndex == i ? 5 : 0)
                                    Text(Self.bgOptions[i].label)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .onTapGesture { bgIndex = i }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // ── 处理按钮 ─────────────────────────────────────────
                    Button { startProcess() } label: {
                        HStack {
                            if isProcessing {
                                ProgressView().tint(.white).padding(.trailing, 4)
                            }
                            Text(isProcessing ? "处理中…" : "开始抠图")
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

                    // ── 进度 ─────────────────────────────────────────────
                    if isProcessing {
                        VStack(spacing: 6) {
                            ProgressView(value: progress).tint(.purple)
                            Text(statusMsg)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("视频抠人")
            .navigationBarItems(leading: Button("关闭") { dismiss() })
            .onChange(of: pickerItem) { item in loadVideo(item) }
            .fullScreenCover(isPresented: $showResult) {
                if let url = resultURL {
                    SegmentResultView(videoURL: url)
                }
            }
        }
    }

    // MARK: - 加载视频

    private func loadVideo(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("seg_src_\(UUID().uuidString).mov")
            try? data.write(to: tmp)
            await MainActor.run { sourceURL = tmp }
        }
    }

    // MARK: - 启动处理

    private func startProcess() {
        guard let src = sourceURL else { return }
        isProcessing = true
        progress = 0
        let ciColor = Self.bgOptions[bgIndex].ci

        Task(priority: .userInitiated) {
            do {
                let out = try await segmentPersonFromVideo(
                    inputURL: src,
                    backgroundColor: ciColor
                ) { p, msg in
                    Task { @MainActor in
                        self.progress = p
                        self.statusMsg = msg
                    }
                }
                await MainActor.run {
                    resultURL = out
                    isProcessing = false
                    showResult = true
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

// MARK: - 核心处理：逐帧分割 + 导出

func segmentPersonFromVideo(
    inputURL: URL,
    backgroundColor: CIColor,
    onProgress: @escaping (Double, String) -> Void
) async throws -> URL {

    let asset  = AVURLAsset(url: inputURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else {
        throw NSError(domain: "Seg", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "找不到视频轨道"])
    }

    let naturalSize = try await track.load(.naturalSize)
    let transform   = try await track.load(.preferredTransform)
    let duration    = try await asset.load(.duration)

    // 处理手机竖拍旋转
    let isRotated  = abs(transform.b) == 1 || abs(transform.c) == 1
    let outputSize = isRotated
        ? CGSize(width: naturalSize.height, height: naturalSize.width)
        : naturalSize

    // ── 读取器 ────────────────────────────────────────────────────────
    let reader    = try AVAssetReader(asset: asset)
    let readerOut = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    )
    readerOut.alwaysCopiesSampleData = false
    reader.add(readerOut)
    reader.startReading()

    // ── 写入器 ────────────────────────────────────────────────────────
    let outURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("seg_out_\(UUID().uuidString).mp4")
    let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
    let writerIn = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
        ]
    )
    writerIn.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: writerIn,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey  as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
        ]
    )
    writer.add(writerIn)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    // ── Vision 分割请求 ───────────────────────────────────────────────
    // iOS 17+：VNGeneratePersonInstanceMaskRequest
    //   - 比旧版 VNGeneratePersonSegmentationRequest 精度更高
    //   - 对头发、手臂边缘、复杂背景处理更好
    //   - generateScaledMaskForImage 直接输出与原帧等大的高精度 mask
    //
    // VNSequenceRequestHandler 跨帧复用上下文，保持时序一致性，
    // 避免帧间 mask 闪烁抖动。
    let instanceReq = VNGeneratePersonInstanceMaskRequest()
    let seqHandler  = VNSequenceRequestHandler()   // 跨帧保持时序一致

    let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
    let bgImg = CIImage(color: backgroundColor)
        .cropped(to: CGRect(origin: .zero, size: outputSize))

    let totalSec = max(duration.seconds, 0.01)
    var frameIdx = 0

    while let sb = readerOut.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)

        // 1. Vision 人物实例分割
        try? seqHandler.perform([instanceReq], on: pb, orientation: .up)

        let origRect = CGRect(origin: .zero, size: outputSize)

        // 构建原始帧 CIImage（含竖拍旋转修正）
        var orig = CIImage(cvPixelBuffer: pb)
        if isRotated {
            orig = orig.transformed(by: transform)
                .transformed(by: CGAffineTransform(
                    translationX: 0, y: -orig.extent.width))
        }
        orig = orig.cropped(to: origRect)

        // ── Mask 处理 ─────────────────────────────────────────────
        let maskCI: CIImage

        if #available(iOS 17.0, *),
           let obs = instanceReq.results?.first as? VNInstanceMaskObservation {
            // iOS 17+：生成与原帧等大的高精度 mask（内部已做上采样）
            let frameHandler = VNImageRequestHandler(
                cvPixelBuffer: pb, orientation: .up, options: [:])
            if let maskPB = try? obs.generateScaledMaskForImage(
                forInstances: obs.allInstances, from: frameHandler) {
                maskCI = CIImage(cvPixelBuffer: maskPB)
            } else {
                continue
            }
        } else {
            // 降级：使用旧版分割（iOS 16 及以下）
            let fallbackReq = VNGeneratePersonSegmentationRequest()
            fallbackReq.qualityLevel      = .accurate
            fallbackReq.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let fbHandler = VNImageRequestHandler(
                cvPixelBuffer: pb, orientation: .up, options: [:])
            try? fbHandler.perform([fallbackReq])
            guard let obs = fallbackReq.results?.first else { continue }
            let raw = CIImage(cvPixelBuffer: obs.pixelBuffer)
            let sx  = outputSize.width  / raw.extent.width
            let sy  = outputSize.height / raw.extent.height
            maskCI  = raw.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        // 轻微高斯羽化边缘（消除锯齿，自然过渡）
        let feathered = maskCI
            .applyingFilter("CIGaussianBlur",
                            parameters: [kCIInputRadiusKey: 1.5])
            .cropped(to: origRect)

        // 2. CoreImage 合成：人物 × mask + 背景 × (1-mask)
        guard let composited = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey:           orig,
            kCIInputBackgroundImageKey: bgImg,
            kCIInputMaskImageKey:       feathered,
        ])?.outputImage else { continue }

        // 3. 渲染 → pixel buffer → 写入
        guard let outPB = makeSegPixelBuffer(size: outputSize) else { continue }
        ciCtx.render(composited, to: outPB)

        while !writerIn.isReadyForMoreMediaData {
            try? await Task.sleep(nanoseconds: 500_000)
        }
        adaptor.append(outPB, withPresentationTime: pts)

        frameIdx += 1
        if frameIdx % 10 == 0 {
            let prog = min(pts.seconds / totalSec, 0.98)
            onProgress(prog, "处理第 \(frameIdx) 帧 (\(Int(prog * 100))%)")
        }
    }

    writerIn.markAsFinished()
    await writer.finishWriting()
    if let err = writer.error { throw err }

    onProgress(1.0, "✅ 完成！共处理 \(frameIdx) 帧")
    return outURL
}

private func makeSegPixelBuffer(size: CGSize) -> CVPixelBuffer? {
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

struct SegmentResultView: View {
    let videoURL: URL
    @Environment(\.dismiss) var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let p = player {
                VideoPlayer(player: p)
                    .ignoresSafeArea()
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

                // 保存按钮
                Button {
                    saveVideo()
                } label: {
                    Label("保存到相册", systemImage: "square.and.arrow.down")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
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
        p.play()
        self.player = p
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: p.currentItem, queue: .main
        ) { _ in p.seek(to: .zero); p.play() }
    }

    private func saveVideo() {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: self.videoURL)
            }
        }
    }
}
