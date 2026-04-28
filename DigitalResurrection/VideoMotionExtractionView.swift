import SwiftUI
import PhotosUI
import AVKit
import Vision
import SceneKit
import simd

// MARK: - 动作帧数据模型 (SceneKit 兼容版)
struct MotionFrame: Identifiable {
    let id = UUID()
    // 存储关键部位的角度：[关节名 : 旋转角度]
    var boneAngles: [VNHumanBodyPoseObservation.JointName: Float] = [:]
    var rootOffset: SCNVector3 = SCNVector3Zero
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
                            .frame(height: 360).cornerRadius(12).padding(10)
                    } else {
                        VStack(spacing: 15) {
                            Image(systemName: "video.badge.plus").font(.system(size: 60)).foregroundColor(.gray)
                            Text("选择一段清晰的全身舞蹈视频").font(.callout).foregroundColor(.gray)
                        }
                    }

                    if isProcessing {
                        Color.black.opacity(0.7).cornerRadius(16)
                        VStack(spacing: 20) {
                            ProgressView(value: progress, total: 1.0).tint(.blue).frame(width: 200)
                            Text(statusMessage).foregroundColor(.white).font(.headline)
                        }
                    }
                }
                .padding()

                VStack(spacing: 12) {
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        Label("选择视频", systemImage: "play.rectangle.on.rectangle.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                            .background(Color.blue).foregroundColor(.white).cornerRadius(12)
                    }
                    .onChange(of: selectedItem) { _ in loadVideo() }

                    Button {
                        processVideoWithRealRetargeting()
                    } label: {
                        Label("AI 真实提取并同步到模型", systemImage: "figure.walk.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                            .background(videoURL == nil || isProcessing ? Color.gray : Color.purple)
                            .foregroundColor(.white).cornerRadius(12)
                    }
                    .disabled(videoURL == nil || isProcessing)
                }
                .padding(.horizontal)
                Spacer()
            }
            .navigationTitle("AI 视频驱动")
            .fullScreenCover(isPresented: $showResult) {
                let modelName = "Strut Walking"
                let finalURL = Bundle.main.url(forResource: modelName, withExtension: "usdz") ??
                              Bundle.main.url(forResource: modelName, withExtension: "usdz", subdirectory: "Resource") ??
                              URL(string: "debug://notfound")!

                RealMotionSceneView(modelURL: finalURL, frames: capturedMotion)
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

    // MARK: - 真实动作分析逻辑
    private func processVideoWithRealRetargeting() {
        guard let url = videoURL else { return }
        isProcessing = true
        statusMessage = "AI 正在逐帧计算 3D 旋转..."
        progress = 0
        capturedMotion = []

        Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
            let reader = try! AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            reader.startReading()

            var frameCount = 0
            while let sampleBuffer = output.copyNextSampleBuffer() {
                frameCount += 1
                if frameCount % 2 == 0 { // 15fps 采样
                    let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
                    let request = VNDetectHumanBodyPoseRequest()
                    let handler = VNImageRequestHandler(cvPixelBuffer: imageBuffer, options: [:])
                    try? handler.perform([request])

                    if let observation = request.results?.first {
                        let frame = self.extractBoneAngles(from: observation)
                        await MainActor.run { self.capturedMotion.append(frame) }
                    }
                    await MainActor.run { self.progress = min(Double(frameCount)/300.0, 0.99) }
                }
                if frameCount > 300 { break }
            }
            await MainActor.run {
                self.isProcessing = false
                self.showResult = true
            }
        }
    }

    private func extractBoneAngles(from observation: VNHumanBodyPoseObservation) -> MotionFrame {
        var angles: [VNHumanBodyPoseObservation.JointName: Float] = [:]

        func angleBetween(_ p1: VNHumanBodyPoseObservation.JointName, _ p2: VNHumanBodyPoseObservation.JointName) -> Float? {
            guard let pt1 = try? observation.recognizedPoint(p1), pt1.confidence > 0.3,
                  let pt2 = try? observation.recognizedPoint(p2), pt2.confidence > 0.3 else { return nil }
            return Float(atan2(pt2.location.y - pt1.location.y, pt2.location.x - pt1.location.x))
        }

        // 提取核心关节角度
        if let a = angleBetween(.leftShoulder, .leftElbow) { angles[.leftShoulder] = a }
        if let a = angleBetween(.leftElbow, .leftWrist) { angles[.leftElbow] = a }
        if let a = angleBetween(.rightShoulder, .rightElbow) { angles[.rightShoulder] = a }
        if let a = angleBetween(.rightElbow, .rightWrist) { angles[.rightElbow] = a }

        // 提取重心
        var offset = SCNVector3Zero
        if let root = try? observation.recognizedPoint(.root), root.confidence > 0.3 {
            offset = SCNVector3(Float(root.location.x - 0.5) * 2.0, Float(root.location.y - 0.5) * 2.0, 0)
        }

        return MotionFrame(boneAngles: angles, rootOffset: offset)
    }
}

// MARK: - SceneKit 驱动显示引擎

struct RealMotionSceneView: View {
    let modelURL: URL
    let frames: [MotionFrame]
    @Environment(\.dismiss) var dismiss
    @State private var currentFrame = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            SCNMotionContainer(modelURL: modelURL, frames: frames, frameIndex: $currentFrame)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundColor(.white.opacity(0.8)).padding()
                    }
                }
                Spacer()
                Text("已提取 \(frames.count) 帧：正在真实驱动 3D 骨骼").font(.caption).foregroundColor(.white.opacity(0.5)).padding(.bottom, 30)
            }
        }
    }
}

struct SCNMotionContainer: UIViewRepresentable {
    let modelURL: URL
    let frames: [MotionFrame]
    @Binding var frameIndex: Int

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = .black
        scnView.autoenablesDefaultLighting = true
        scnView.allowsCameraControl = true

        if let scene = try? SCNScene(url: modelURL, options: nil) {
            // 1. 禁用所有内嵌动画
            scene.rootNode.enumerateChildNodes { (node, _) in
                node.removeAllAnimations()
            }

            scnView.scene = scene

            // 2. 自动定位相机
            let (mn, mx) = scene.rootNode.boundingBox
            let radius = max(mx.x - mn.x, mx.y - mn.y)
            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(0, 0, Float(radius > 0 ? radius * 2.5 : 5.0))
            scene.rootNode.addChildNode(cameraNode)

            // 3. 启动驱动计时器
            context.coordinator.startDriving(scene: scene, frames: frames)
        }

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(frameIndex: $frameIndex) }

    class Coordinator {
        var timer: Timer?
        @Binding var frameIndex: Int

        init(frameIndex: Binding<Int>) {
            self._frameIndex = frameIndex
        }

        func startDriving(scene: SCNScene, frames: [MotionFrame]) {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0/15.0, repeats: true) { _ in
                guard !frames.isEmpty else { return }
                let frame = frames[self.frameIndex]

                // 1. 同步身体位移
                scene.rootNode.position = frame.rootOffset

                // 2. 映射骨骼旋转 (核心)
                self.rotateBone(scene, "LeftArm", angle: frame.boneAngles[.leftShoulder], offset: .pi)
                self.rotateBone(scene, "LeftForeArm", angle: frame.boneAngles[.leftElbow], offset: .pi)
                self.rotateBone(scene, "RightArm", angle: frame.boneAngles[.rightShoulder], offset: 0)
                self.rotateBone(scene, "RightForeArm", angle: frame.boneAngles[.rightElbow], offset: 0)

                self.frameIndex = (self.frameIndex + 1) % frames.count
            }
        }

        private func rotateBone(_ scene: SCNScene, _ name: String, angle: Float?, offset: Float) {
            guard let angle = angle else { return }
            // 尝试匹配多种骨骼命名
            let possibleNames = [name, "mixamorig_" + name, name.lowercased(), name.capitalized]
            for boneName in possibleNames {
                if let boneNode = scene.rootNode.childNode(withName: boneName, recursively: true) {
                    // 对于 2D 视频，主要影响 Z 轴旋转
                    boneNode.eulerAngles.z = angle + offset
                    return
                }
            }
        }
    }
}
