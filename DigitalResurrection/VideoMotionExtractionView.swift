import SwiftUI
import PhotosUI
import AVKit
import Vision
import RealityKit
import Combine

// MARK: - 动作数据模型
struct MotionFrame: Identifiable {
    let id = UUID()
    // 存储关键骨骼相对于 T-Pose 的旋转四元数
    let boneRotations: [String: simd_quatf]
    let rootTransform: simd_float4x4
}

struct VideoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let tempDir = FileManager.default.temporaryDirectory
            let copyURL = tempDir.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: copyURL)
            try FileManager.default.copyItem(at: received.file, to: copyURL)
            return VideoFile(url: copyURL)
        }
    }
}

struct VideoMotionExtractionView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var statusMessage = "请选择视频"
    @State private var capturedMotion: [MotionFrame] = []
    @State private var showResult = false
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: 380)

                    if let videoURL {
                        VideoPlayer(player: AVPlayer(url: videoURL))
                            .frame(height: 360)
                            .cornerRadius(12)
                            .padding(10)
                    } else {
                        VStack(spacing: 15) {
                            Image(systemName: "video.badge.plus")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            Text("请选择一段包含全身动作的视频")
                                .font(.callout)
                                .foregroundColor(.gray)
                        }
                    }

                    if isProcessing {
                        Color.black.opacity(0.7).cornerRadius(16)
                        VStack(spacing: 20) {
                            ProgressView(value: progress, total: 1.0)
                                .progressViewStyle(.linear)
                                .tint(.blue)
                                .frame(width: 200)

                            Text(statusMessage)
                                .foregroundColor(.white)
                                .font(.headline)

                            Text("\(Int(progress * 100))%")
                                .foregroundColor(.white.opacity(0.8))
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
                .padding()

                VStack(spacing: 12) {
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        Label("选择视频", systemImage: "play.rectangle.on.rectangle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .onChange(of: selectedItem) { _ in loadVideo() }

                    Button {
                        processVideoRealAI()
                    } label: {
                        Label("AI 提取动作并驱动模型", systemImage: "figure.walk.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(videoURL == nil || isProcessing ? Color.gray : Color.purple)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .disabled(videoURL == nil || isProcessing)
                }
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("视频动作提取")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showResult) {
                let modelName = "Strut Walking"
                let finalURL = Bundle.main.url(forResource: modelName, withExtension: "usdz") ??
                              Bundle.main.url(forResource: modelName, withExtension: "usdz", subdirectory: "Resource") ??
                              URL(string: "debug://notfound")!

                MotionDrivenPreviewScreen(modelURL: finalURL, motionFrames: capturedMotion)
            }
        }
    }

    private func loadVideo() {
        Task {
            if let movie = try? await selectedItem?.loadTransferable(type: VideoFile.self) {
                self.videoURL = movie.url
                self.statusMessage = "视频已就绪"
            }
        }
    }

    private func processVideoRealAI() {
        guard let url = videoURL else { return }
        isProcessing = true
        statusMessage = "AI 正在计算骨骼旋转..."
        progress = 0
        capturedMotion = []

        Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
                await MainActor.run { self.isProcessing = false }
                return
            }

            let reader = try! AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            reader.add(output)
            reader.startReading()

            var processedFrames = 0
            let duration = try? await asset.load(.duration)
            let fps = try? await track.load(.nominalFrameRate)
            let totalFramesCount = Int((duration?.seconds ?? 1.0) * Double(fps ?? 30))

            while let sampleBuffer = output.copyNextSampleBuffer() {
                processedFrames += 1

                if processedFrames % 2 == 0 {
                    let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
                    let request = VNDetectHumanBodyPoseRequest()
                    let handler = VNImageRequestHandler(cvPixelBuffer: imageBuffer, options: [:])

                    do {
                        try handler.perform([request])
                        if let observation = request.results?.first {
                            let frame = try self.extractMotionFrame(from: observation)
                            await MainActor.run {
                                self.capturedMotion.append(frame)
                            }
                        }
                    } catch {
                        print("AI 处理失败: \(error)")
                    }

                    let currentProgress = Double(processedFrames) / Double(totalFramesCount)
                    await MainActor.run {
                        self.progress = min(currentProgress, 0.99)
                    }
                }

                if processedFrames > 300 { break }
            }

            await MainActor.run {
                self.progress = 1.0
                self.statusMessage = "动作提取成功！"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.isProcessing = false
                    self.showResult = true
                }
            }
        }
    }

    // MARK: - 核心：姿态重定向算法 (Motion Retargeting)
    private func extractMotionFrame(from observation: VNHumanBodyPoseObservation) throws -> MotionFrame {
        var rotations: [String: simd_quatf] = [:]

        // 辅助函数：计算两个关节之间的 2D 旋转角度
        func calculateAngle(from: VNHumanBodyPoseObservation.JointName, to: VNHumanBodyPoseObservation.JointName) -> Float? {
            guard let p1 = try? observation.recognizedPoint(from), p1.confidence > 0.3,
                  let p2 = try? observation.recognizedPoint(to), p2.confidence > 0.3 else { return nil }
            // 计算屏幕坐标系下的角度
            return Float(atan2(p2.location.y - p1.location.y, p2.location.x - p1.location.x))
        }

        // 映射关键骨骼 (基于常见 Mixamo 命名规范)
        // 臂部
        if let leftArmAngle = calculateAngle(from: .leftShoulder, to: .leftElbow) {
            rotations["LeftArm"] = simd_quatf(angle: leftArmAngle + .pi, axis: [0, 0, 1])
        }
        if let rightArmAngle = calculateAngle(from: .rightShoulder, to: .rightElbow) {
            rotations["RightArm"] = simd_quatf(angle: rightArmAngle, axis: [0, 0, 1])
        }

        // 腿部
        if let leftLegAngle = calculateAngle(from: .leftHip, to: .leftKnee) {
            rotations["LeftUpLeg"] = simd_quatf(angle: leftLegAngle + .pi/2, axis: [0, 0, 1])
        }
        if let rightLegAngle = calculateAngle(from: .rightHip, to: .rightKnee) {
            rotations["RightUpLeg"] = simd_quatf(angle: rightLegAngle + .pi/2, axis: [0, 0, 1])
        }

        // 身体重心偏移
        var transform = matrix_identity_float4x4
        if let hip = try? observation.recognizedPoint(.root), hip.confidence > 0.3 {
            transform.columns.3 = simd_float4(Float(hip.location.x - 0.5) * 2, Float(hip.location.y - 0.5) * 2, -2.0, 1.0)
        }

        return MotionFrame(boneRotations: rotations, rootTransform: transform)
    }
}

// MARK: - 驱动预览页面

struct MotionDrivenPreviewScreen: View {
    let modelURL: URL
    let motionFrames: [MotionFrame]
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MotionRealityView(modelURL: modelURL, frames: motionFrames)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white.opacity(0.8))
                            .padding()
                    }
                }
                Spacer()
                Text("正在应用从视频中提取的 \(motionFrames.count) 帧 3D 旋转")
                    .font(.caption.monospaced())
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.bottom, 20)
            }
        }
    }
}

struct MotionRealityView: UIViewRepresentable {
    let modelURL: URL
    let frames: [MotionFrame]

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        arView.environment.background = .color(.black)

        Entity.loadAsync(contentsOf: modelURL).sink(receiveCompletion: { _ in }, receiveValue: { entity in
            let anchor = AnchorEntity(world: [0, 0, 0])
            entity.position = [0, -0.6, -2.0]
            entity.scale = [0.01, 0.01, 0.01]

            entity.stopAllAnimations()
            anchor.addChild(entity)
            arView.scene.addAnchor(anchor)

            context.coordinator.drive(entity: entity, with: frames)
        }).store(in: &context.coordinator.cancellables)

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var cancellables = Set<AnyCancellable>()
        var timer: Timer?
        var frameIndex = 0

        func drive(entity: Entity, with frames: [MotionFrame]) {
            guard !frames.isEmpty else { return }

            timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let frame = frames[self.frameIndex]

                // 1. 驱动整体位移
                entity.position = [frame.rootTransform.columns.3.x, frame.rootTransform.columns.3.y, -2.0]

                // 2. 真实驱动核心：遍历并旋转骨骼
                for (boneName, rotation) in frame.boneRotations {
                    // 尝试匹配模型中可能的骨骼名（针对常见的 Mixamo 规范）
                    if let bone = self.findBone(in: entity, name: boneName) {
                        bone.orientation = rotation
                    }
                }

                self.frameIndex = (self.frameIndex + 1) % frames.count
            }
        }

        // 递归查找匹配骨骼节点的辅助函数
        private func findBone(in entity: Entity, name: String) -> Entity? {
            // 常见的命名前缀尝试
            let namesToTry = [name, "mixamorig_" + name, "mixamorig:" + name]
            for tryName in namesToTry {
                if let found = entity.findEntity(named: tryName) {
                    return found
                }
            }
            return nil
        }

        deinit {
            timer?.invalidate()
        }
    }
}
