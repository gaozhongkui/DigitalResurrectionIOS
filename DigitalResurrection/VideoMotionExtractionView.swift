import SwiftUI
import PhotosUI
import AVKit
import MediaPipeTasksVision
import SceneKit
import simd

// MARK: - 动作帧数据模型 (优化版)
struct MotionFrame: Identifiable {
    let id = UUID()
    // 存储关键部位的角度：[关节名 : 旋转角度]
    var boneRotations: [String: SCNVector4] = [:]
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
        statusMessage = "初始化 MediaPipe 引擎..."
        progress = 0
        capturedMotion = []

        Task(priority: .userInitiated) {
            guard let modelPath = Bundle.main.path(forResource: "pose_landmarker_full", ofType: "task") else {
                await MainActor.run { self.isProcessing = false; self.statusMessage = "未找到模型文件" }
                return
            }

            let options = PoseLandmarkerOptions()
            options.baseOptions.modelAssetPath = modelPath
            options.runningMode = .video
            options.numPoses = 1
            options.minPoseDetectionConfidence = 0.5
            options.minPosePresenceConfidence = 0.5
            options.minTrackingConfidence = 0.5

            let poseLandmarker: PoseLandmarker
            do {
                poseLandmarker = try PoseLandmarker(options: options)
            } catch {
                await MainActor.run { self.isProcessing = false; self.statusMessage = "初始化失败" }
                return
            }

            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
                await MainActor.run { self.isProcessing = false; self.statusMessage = "读取轨道失败" }
                return
            }

            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                await MainActor.run { self.isProcessing = false; self.statusMessage = "解码器失败" }
                return
            }

            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            reader.startReading()

            var frameCount = 0
            let duration = try? await asset.load(.duration)
            let totalSeconds = duration?.seconds ?? 1.0

            while let sampleBuffer = output.copyNextSampleBuffer() {
                frameCount += 1
                if frameCount % 2 != 0 { continue }

                guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                let timestampMs = Int(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1000)

                let mpImage: MPImage
                do {
                    mpImage = try MPImage(pixelBuffer: imageBuffer)
                } catch { continue }

                do {
                    let result = try poseLandmarker.detect(videoFrame: mpImage, timestampInMilliseconds: timestampMs)
                    if let landmarks = result.landmarks.first {
                        let worldLandmarks = result.worldLandmarks.first
                        let frame = self.calculateMotionFrame(landmarks: landmarks, worldLandmarks: worldLandmarks)

                        await MainActor.run {
                            self.capturedMotion.append(frame)
                            self.progress = min(Double(timestampMs) / (totalSeconds * 1000), 0.99)
                            self.statusMessage = "已提取 \(self.capturedMotion.count) 帧"
                        }
                    }
                } catch {
                    print("MediaPipe Detection Error: \(error)")
                }

                if capturedMotion.count >= 450 { break }
            }

            await MainActor.run {
                self.isProcessing = false
                self.showResult = !self.capturedMotion.isEmpty
            }
        }
    }

    private func calculateMotionFrame(landmarks: [NormalizedLandmark], worldLandmarks: [Landmark]?) -> MotionFrame {
        var rotations: [String: SCNVector4] = [:]

        // 统一转换为包含 (x, y, z) 的 Float 数组以进行计算
        let points: [(x: Float, y: Float, z: Float)]
        if let wl = worldLandmarks {
            points = wl.map { (x: Float($0.x), y: Float($0.y), z: Float($0.z)) }
        } else {
            points = landmarks.map { (x: Float($0.x), y: Float($0.y), z: Float($0.z)) }
        }

        func getRotation(from: Int, to: Int, axis: SCNVector3) -> SCNVector4 {
            guard from < points.count, to < points.count else { return SCNVector4(0, 0, 1, 0) }
            let p1 = points[from]
            let p2 = points[to]
            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let angle = atan2(dy, dx)
            return SCNVector4(axis.x, axis.y, axis.z, angle)
        }

        // 映射 MediaPipe 索引
        rotations["LeftArm"] = getRotation(from: 11, to: 13, axis: SCNVector3(0, 0, 1))
        rotations["LeftForeArm"] = getRotation(from: 13, to: 15, axis: SCNVector3(0, 0, 1))
        rotations["RightArm"] = getRotation(from: 12, to: 14, axis: SCNVector3(0, 0, 1))
        rotations["RightForeArm"] = getRotation(from: 14, to: 16, axis: SCNVector3(0, 0, 1))
        rotations["LeftUpLeg"] = getRotation(from: 23, to: 25, axis: SCNVector3(0, 0, 1))
        rotations["LeftLeg"] = getRotation(from: 25, to: 27, axis: SCNVector3(0, 0, 1))
        rotations["RightUpLeg"] = getRotation(from: 24, to: 26, axis: SCNVector3(0, 0, 1))
        rotations["RightLeg"] = getRotation(from: 26, to: 28, axis: SCNVector3(0, 0, 1))

        let hipL = points[23]
        let hipR = points[24]
        let rootX = (hipL.x + hipR.x) / 2.0
        let rootY = (hipL.y + hipR.y) / 2.0
        let rootZ = (hipL.z + hipR.z) / 2.0

        return MotionFrame(
            boneRotations: rotations,
            rootOffset: SCNVector3(-rootX, -rootY, -rootZ)
        )
    }
}

// MARK: - SceneKit 驱动引擎

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
                Text("MediaPipe 引擎驱动中：已加载 \(frames.count) 帧")
                    .font(.caption).foregroundColor(.white.opacity(0.6)).padding(.bottom, 30)
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
            scene.rootNode.enumerateChildNodes { (node, _) in node.removeAllAnimations() }
            scnView.scene = scene
            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.position = SCNVector3(0, 1, 4)
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
                for (boneName, rotation) in frame.boneRotations {
                    self.applyRotation(scene, boneName, rotation)
                }
                self.frameIndex = (self.frameIndex + 1) % frames.count
            }
        }

        private func applyRotation(_ scene: SCNScene, _ name: String, _ rotation: SCNVector4) {
            let possibleNames = [name, "mixamorig_" + name, "mixamorig:" + name]
            for boneName in possibleNames {
                if let boneNode = scene.rootNode.childNode(withName: boneName, recursively: true) {
                    boneNode.rotation = rotation
                    return
                }
            }
        }
    }
}
