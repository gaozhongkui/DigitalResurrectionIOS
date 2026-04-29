import SwiftUI
import PhotosUI
import AVKit
import MediaPipeTasksVision
import SceneKit
import simd

// MARK: - 动作帧数据模型
struct MotionFrame: Identifiable {
    let id = UUID()
    // 存储关键部位的 3D 旋转 (世界坐标系下的期望方向)
    var boneWorldOrientations: [String: simd_quatf] = [:]
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

    // 平滑滤波器缓存
    @State private var lastOrientations: [String: simd_quatf] = [:]

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
                            Image(systemName: "video.badge.plus.fill").font(.system(size: 60)).foregroundColor(.gray)
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
                        processVideoWithMediaPipe()
                    } label: {
                        Label("MediaPipe 3D 深度提取", systemImage: "figure.walk.circle.fill")
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

    private func processVideoWithMediaPipe() {
        guard let url = videoURL else { return }
        isProcessing = true
        statusMessage = "AI 正在识别 3D 关键点..."
        progress = 0
        capturedMotion = []
        lastOrientations = [:]

        Task(priority: .userInitiated) {
            guard let modelPath = Bundle.main.path(forResource: "pose_landmarker_full", ofType: "task") else {
                await MainActor.run { self.isProcessing = false; self.statusMessage = "模型丢失" }
                return
            }

            let options = PoseLandmarkerOptions()
            options.baseOptions.modelAssetPath = modelPath
            options.runningMode = .video
            options.numPoses = 1

            let poseLandmarker = try! PoseLandmarker(options: options)
            let asset = AVURLAsset(url: url)
            let reader = try! AVAssetReader(asset: asset)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }

            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            reader.startReading()

            var frameCount = 0
            let duration = try? await asset.load(.duration)
            let totalSeconds = duration?.seconds ?? 1.0

            while let sampleBuffer = output.copyNextSampleBuffer() {
                frameCount += 1
                if frameCount % 2 != 0 { continue } // 15fps

                guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                let timestampMs = Int(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1000)
                let mpImage = try! MPImage(pixelBuffer: imageBuffer)

                if let result = try? poseLandmarker.detect(videoFrame: mpImage, timestampInMilliseconds: timestampMs),
                   let landmarks = result.landmarks.first {

                    let frame = self.calculateMotionFrame(landmarks: landmarks, worldLandmarks: result.worldLandmarks.first)

                    await MainActor.run {
                        self.capturedMotion.append(frame)
                        self.progress = min(Double(timestampMs) / (totalSeconds * 1000), 0.99)
                        self.statusMessage = "已同步 \(self.capturedMotion.count) 帧"
                    }
                }
                if capturedMotion.count >= 900 { break }
            }

            await MainActor.run { self.isProcessing = false; self.showResult = !self.capturedMotion.isEmpty }
        }
    }

    // MARK: - 3D 旋转计算 (修复版)
    private func calculateMotionFrame(landmarks: [NormalizedLandmark], worldLandmarks: [Landmark]?) -> MotionFrame {
        var currentFrameOrientations: [String: simd_quatf] = [:]

        // 1. 轴对齐转换：MediaPipe (X+ left, Y+ up, Z+ close) -> SceneKit (X+ right, Y+ up, Z+ out)
        // 注意 Z 轴反转，因为 MediaPipe Z 越小越近，SceneKit Z 越大越近
        let points: [SIMD3<Float>]
        if let wl = worldLandmarks {
            points = wl.map { SIMD3<Float>(-Float($0.x), Float($0.y), -Float($0.z)) }
        } else {
            points = landmarks.map { SIMD3<Float>(0.5 - Float($0.x), 0.5 - Float($0.y), -Float($0.z)) }
        }

        // 2. 旋转计算器 (带平滑滤波)
        func getOrientation(name: String, from: Int, to: Int, restDir: SIMD3<Float>) -> simd_quatf {
            guard from < points.count, to < points.count else { return simd_quaternion(0, SIMD3<Float>(0, 0, 1)) }
            let targetDir = normalize(points[to] - points[from])
            let sourceDir = normalize(restDir)

            let dotProduct = dot(sourceDir, targetDir)
            var quat: simd_quatf
            if dotProduct > 0.999 {
                quat = simd_quaternion(0, SIMD3<Float>(0, 0, 1))
            } else if dotProduct < -0.999 {
                quat = simd_quaternion(Float.pi, SIMD3<Float>(0, 1, 0))
            } else {
                let axis = normalize(cross(sourceDir, targetDir))
                let angle = acos(dotProduct)
                quat = simd_quaternion(angle, axis)
            }

            // 简单的低通滤波 (Exponential Smoothing) 减少抖动
            if let prev = lastOrientations[name] {
                quat = simd_slerp(prev, quat, 0.4) // 0.4 为平滑因子
            }
            lastOrientations[name] = quat
            return quat
        }

        // 3. 映射骨骼 (Mixamo 规范)
        currentFrameOrientations["LeftArm"] = getOrientation(name: "LA", from: 11, to: 13, restDir: SIMD3<Float>(-1, 0, 0))
        currentFrameOrientations["LeftForeArm"] = getOrientation(name: "LFA", from: 13, to: 15, restDir: SIMD3<Float>(-1, 0, 0))
        currentFrameOrientations["RightArm"] = getOrientation(name: "RA", from: 12, to: 14, restDir: SIMD3<Float>(1, 0, 0))
        currentFrameOrientations["RightForeArm"] = getOrientation(name: "RFA", from: 14, to: 16, restDir: SIMD3<Float>(1, 0, 0))

        currentFrameOrientations["LeftUpLeg"] = getOrientation(name: "LUL", from: 23, to: 25, restDir: SIMD3<Float>(0, -1, 0))
        currentFrameOrientations["LeftLeg"] = getOrientation(name: "LL", from: 25, to: 27, restDir: SIMD3<Float>(0, -1, 0))
        currentFrameOrientations["RightUpLeg"] = getOrientation(name: "RUL", from: 24, to: 26, restDir: SIMD3<Float>(0, -1, 0))
        currentFrameOrientations["RightLeg"] = getOrientation(name: "RL", from: 26, to: 28, restDir: SIMD3<Float>(0, -1, 0))

        // 4. 重心位移
        let hipL = landmarks[23]
        let hipR = landmarks[24]
        let rootX = (hipL.x + hipR.x) / 2.0
        let rootY = (hipL.y + hipR.y) / 2.0

        return MotionFrame(
            boneWorldOrientations: currentFrameOrientations,
            rootOffset: SCNVector3((rootX - 0.5) * 1.5, (0.5 - rootY) * 1.5, 0)
        )
    }
}

// MARK: - SceneKit 驱动容器 (层级修复)

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
            scene.rootNode.enumerateChildNodes { (node, _) in node.removeAllAnimations() }
            scnView.scene = scene
            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(0, 1.2, 3.5)
            scene.rootNode.addChildNode(cameraNode)
            context.coordinator.startDriving(scene: scene, frames: frames)
        }
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(frameIndex: $frameIndex) }

    class Coordinator {
        var timer: Timer?
        @Binding var frameIndex: Int
        init(frameIndex: Binding<Int>) { self._frameIndex = frameIndex }

        func startDriving(scene: SCNScene, frames: [MotionFrame]) {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0/20.0, repeats: true) { _ in
                guard !frames.isEmpty else { return }
                let frame = frames[self.frameIndex]

                // 按骨骼层级顺序处理是非常重要的，但在本例中我们直接设置世界姿态
                for (boneName, worldOrient) in frame.boneWorldOrientations {
                    self.applyBoneRotation(scene, boneName, worldOrient)
                }

                self.frameIndex = (self.frameIndex + 1) % frames.count
            }
        }

        private func applyBoneRotation(_ scene: SCNScene, _ name: String, _ worldOrient: simd_quatf) {
            let possibleNames = [name, "mixamorig_" + name, "mixamorig:" + name]
            for boneName in possibleNames {
                if let boneNode = scene.rootNode.childNode(withName: boneName, recursively: true) {
                    // 核心修复：消除层级干扰
                    // 将计算出的“世界旋转”转换为该节点的“本地旋转”
                    if let parent = boneNode.parent {
                        let parentWorldRot = simd_quaternion(parent.simdWorldTransform)
                        boneNode.simdOrientation = parentWorldRot.inverse * worldOrient
                    } else {
                        boneNode.simdOrientation = worldOrient
                    }
                    return
                }
            }
        }
    }
}

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
                Text("MediaPipe 3D 重定向已优化 (带平滑滤波)")
                    .font(.caption).foregroundColor(.white.opacity(0.6)).padding(.bottom, 30)
            }
        }
    }
}
