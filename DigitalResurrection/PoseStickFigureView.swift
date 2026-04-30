import SwiftUI
import PhotosUI
import AVKit
import MediaPipeTasksVision
import SceneKit
import simd

// MARK: - 姿态帧数据

struct PoseFrame {
    var points: [SIMD3<Float>]  // 33 个 MediaPipe World Landmarks（米制）
}

// MARK: - 骨骼连接定义

private let kJointIndices = [0, 11, 12, 13, 14, 15, 16, 23, 24, 25, 26, 27, 28]

private let kBoneConnections: [(Int, Int, UIColor)] = [
    // 手臂（左侧 = 青色，右侧 = 橙色，从观察者视角看）
    (11, 13, .systemTeal),   (13, 15, .systemTeal),
    (12, 14, .systemOrange), (14, 16, .systemOrange),
    // 腿部
    (23, 25, .systemTeal),   (25, 27, .systemTeal),
    (24, 26, .systemOrange), (26, 28, .systemOrange),
    // 肩膀 / 髋部横线
    (11, 12, .systemGreen),
    (23, 24, .systemGreen),
]

// MARK: - 主视图

struct PoseStickFigureView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var statusMessage = "请选择视频"
    @State private var poseFrames: [PoseFrame] = []
    @State private var showResult = false
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                previewZone.padding()

                VStack(spacing: 12) {
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        Label("选择视频", systemImage: "play.rectangle.on.rectangle.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                            .background(Color.blue).foregroundColor(.white).cornerRadius(12)
                    }
                    .onChange(of: selectedItem) { _ in loadVideo() }

                    Button { extractPose() } label: {
                        Label("提取姿态并查看线条", systemImage: "figure.walk.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                            .background(videoURL == nil || isProcessing ? Color.gray : Color.purple)
                            .foregroundColor(.white).cornerRadius(12)
                    }
                    .disabled(videoURL == nil || isProcessing)
                }
                .padding(.horizontal)
                Spacer()
            }
            .navigationTitle("姿态线条预览")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .fullScreenCover(isPresented: $showResult) {
            StickFigurePlaybackView(frames: poseFrames)
        }
    }

    private var previewZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.1))
                .frame(height: 300)

            if let url = videoURL {
                VideoPlayer(player: AVPlayer(url: url))
                    .frame(height: 280).cornerRadius(12).padding(10)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "figure.walk").font(.system(size: 60)).foregroundColor(.gray)
                    Text("选择一段全身人物视频").font(.callout).foregroundColor(.gray)
                }
            }

            if isProcessing {
                RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.75))
                VStack(spacing: 14) {
                    ProgressView(value: progress).tint(.blue).frame(width: 200)
                    Text(statusMessage).foregroundColor(.white).font(.headline)
                }
            }
        }
    }

    // MARK: - 加载视频

    private func loadVideo() {
        Task {
            if let movie = try? await selectedItem?.loadTransferable(type: VideoFile.self) {
                await MainActor.run { videoURL = movie.url }
            }
        }
    }

    // MARK: - MediaPipe 提取

    private func extractPose() {
        guard let url = videoURL else { return }
        isProcessing = true; progress = 0; poseFrames = []
        statusMessage = "MediaPipe 正在识别关键点..."

        Task(priority: .userInitiated) {
            guard let modelPath = Bundle.main.path(forResource: "pose_landmarker_full", ofType: "task") else {
                await MainActor.run { isProcessing = false; statusMessage = "找不到模型文件" }
                return
            }

            let options = PoseLandmarkerOptions()
            options.baseOptions.modelAssetPath = modelPath
            options.runningMode = .video
            options.numPoses = 1

            let landmarker = try! PoseLandmarker(options: options)
            let asset = AVURLAsset(url: url)
            let reader = try! AVAssetReader(asset: asset)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }

            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            reader.add(output); reader.startReading()

            let totalSecs = (try? await asset.load(.duration))?.seconds ?? 1.0
            var frameCount = 0
            var frames: [PoseFrame] = []

            while let sample = output.copyNextSampleBuffer() {
                frameCount += 1
                if frameCount % 2 != 0 { continue }   // 约 15fps
                guard let imgBuf = CMSampleBufferGetImageBuffer(sample) else { continue }
                let tsMs = Int(CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1000)
                let mpImage = try! MPImage(pixelBuffer: imgBuf)

                if let result = try? landmarker.detect(videoFrame: mpImage, timestampInMilliseconds: tsMs),
                   let wl = result.worldLandmarks.first {
                    // MediaPipe World: X+ = 人体右, Y+ = 向下（图像坐标系）, Z+ = 朝摄像头
                    // 取反 X：人体左侧映射到 SceneKit +X（正面视角）
                    // 取反 Y：MediaPipe Y 向下，SceneKit Y 向上，必须翻转
                    // 取反 Z：深度转换为 SceneKit -Z 惯例
                    let pts = wl.map { SIMD3<Float>(-Float($0.x), -Float($0.y), -Float($0.z)) }
                    frames.append(PoseFrame(points: pts))
                }

                if frames.count % 5 == 0 {
                    let p = min(Double(tsMs) / (totalSecs * 1000), 0.99)
                    let cnt = frames.count
                    await MainActor.run { progress = p; statusMessage = "已提取 \(cnt) 帧" }
                }
                if frames.count >= 900 { break }
            }

            await MainActor.run {
                poseFrames = frames
                isProcessing = false
                showResult = !frames.isEmpty
                statusMessage = frames.isEmpty ? "未检测到人体" : "完成！共 \(frames.count) 帧"
            }
        }
    }
}

// MARK: - 线条回放视图

struct StickFigurePlaybackView: View {
    let frames: [PoseFrame]
    @Environment(\.dismiss) var dismiss
    @State private var currentFrame = 0
    @State private var isPlaying = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            StickFigureSceneView(frames: frames,
                                 currentFrame: $currentFrame,
                                 isPlaying: $isPlaying)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title).foregroundColor(.white.opacity(0.8)).padding()
                    }
                }
                Spacer()

                // 控制栏
                VStack(spacing: 10) {
                    HStack(spacing: 32) {
                        Button {
                            isPlaying = false
                            currentFrame = max(0, currentFrame - 1)
                        } label: {
                            Image(systemName: "backward.frame.fill")
                                .font(.title2).foregroundColor(.white)
                        }

                        Button {
                            isPlaying.toggle()
                        } label: {
                            Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 52)).foregroundColor(.white)
                        }

                        Button {
                            isPlaying = false
                            currentFrame = min(frames.count - 1, currentFrame + 1)
                        } label: {
                            Image(systemName: "forward.frame.fill")
                                .font(.title2).foregroundColor(.white)
                        }
                    }

                    Text("帧 \(currentFrame + 1) / \(frames.count)  ·  拖拽可旋转视角")
                        .font(.caption).foregroundColor(.white.opacity(0.5))
                }
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - SceneKit 火柴人渲染

struct StickFigureSceneView: UIViewRepresentable {
    let frames: [PoseFrame]
    @Binding var currentFrame: Int
    @Binding var isPlaying: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(frames: frames, currentFrame: $currentFrame)
    }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = UIColor(white: 0.04, alpha: 1)
        scnView.allowsCameraControl = true
        scnView.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        scnView.scene = scene

        // 相机：正前方，稍微偏上以看到全身
        let camNode = SCNNode()
        camNode.camera = SCNCamera()
        camNode.position = SCNVector3(0, -0.2, 2.8)
        scene.rootNode.addChildNode(camNode)
        scnView.pointOfView = camNode

        // 环境光（常量光照，让颜色纯粹）
        let ambLight = SCNLight(); ambLight.type = .ambient; ambLight.intensity = 1000
        let ambNode = SCNNode(); ambNode.light = ambLight
        scene.rootNode.addChildNode(ambNode)

        // 地面参考线（淡色网格平面）
        let floor = SCNFloor()
        floor.firstMaterial?.diffuse.contents = UIColor(white: 0.12, alpha: 1)
        floor.firstMaterial?.lightingModel = .constant
        let floorNode = SCNNode(geometry: floor)
        floorNode.simdPosition = SIMD3<Float>(0, -1.05, 0)
        scene.rootNode.addChildNode(floorNode)

        context.coordinator.buildFigure(in: scene)
        context.coordinator.startTimer()
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let c = context.coordinator
        c.isPlaying = isPlaying
        // 暂停时手动跳帧也能即时刷新
        if !isPlaying, currentFrame < frames.count {
            c.applyFrame(frames[currentFrame])
        }
    }

    // MARK: Coordinator

    class Coordinator: NSObject {
        let frames: [PoseFrame]
        @Binding var currentFrame: Int
        var isPlaying = true
        var timer: Timer?

        var jointNodes: [Int: SCNNode] = [:]
        var boneNodes: [(Int, Int, SCNNode)] = []
        var spineNode: SCNNode?

        init(frames: [PoseFrame], currentFrame: Binding<Int>) {
            self.frames = frames
            self._currentFrame = currentFrame
        }

        // MARK: 构建场景节点

        func buildFigure(in scene: SCNScene) {
            // 关节球
            for idx in kJointIndices {
                let r: CGFloat = idx == 0 ? 0.04 : 0.022
                let sphere = SCNSphere(radius: r)
                sphere.firstMaterial?.diffuse.contents = UIColor.white
                sphere.firstMaterial?.lightingModel = .constant
                let node = SCNNode(geometry: sphere)
                scene.rootNode.addChildNode(node)
                jointNodes[idx] = node
            }

            // 脊柱虚拟骨骼（肩中心 → 髋中心）
            spineNode = makeCylinder(color: .systemGreen)
            scene.rootNode.addChildNode(spineNode!)

            // 颈部（鼻子 → 肩中心，虚拟）
            let neckNode = makeCylinder(color: .white)
            scene.rootNode.addChildNode(neckNode)
            boneNodes.append((-1, -1, neckNode))   // 特殊标记，在 applyFrame 中单独计算

            // 常规骨骼
            for (from, to, color) in kBoneConnections {
                let node = makeCylinder(color: color)
                scene.rootNode.addChildNode(node)
                boneNodes.append((from, to, node))
            }

            if let first = frames.first { applyFrame(first) }
        }

        private func makeCylinder(color: UIColor) -> SCNNode {
            let cyl = SCNCylinder(radius: 0.014, height: 1.0)
            cyl.firstMaterial?.diffuse.contents = color
            cyl.firstMaterial?.lightingModel = .constant
            return SCNNode(geometry: cyl)
        }

        // MARK: 动画驱动

        func startTimer() {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
                guard let self = self, !self.frames.isEmpty else { return }
                let idx = self.currentFrame
                self.applyFrame(self.frames[idx])
                if self.isPlaying {
                    self.currentFrame = (idx + 1) % self.frames.count
                }
            }
        }

        func applyFrame(_ frame: PoseFrame) {
            guard frame.points.count >= 29 else { return }
            let pts = frame.points

            // 更新关节球位置
            for (idx, node) in jointNodes {
                guard idx < pts.count else { continue }
                node.simdPosition = pts[idx]
            }

            // 脊柱
            if let spineNode = spineNode {
                let sc = (pts[11] + pts[12]) * 0.5
                let hc = (pts[23] + pts[24]) * 0.5
                placeBone(spineNode, from: hc, to: sc)
            }

            // 其他骨骼（-1 标记的是颈部，单独处理）
            for (from, to, node) in boneNodes {
                if from == -1 {
                    // 颈部：鼻子 → 肩中心
                    let sc = (pts[11] + pts[12]) * 0.5
                    placeBone(node, from: sc, to: pts[0])
                } else if from < pts.count, to < pts.count {
                    placeBone(node, from: pts[from], to: pts[to])
                }
            }
        }

        // 将圆柱节点放置在两点之间
        private func placeBone(_ node: SCNNode, from a: SIMD3<Float>, to b: SIMD3<Float>) {
            let diff = b - a
            let len = simd_length(diff)
            guard len > 1e-6 else { node.isHidden = true; return }
            node.isHidden = false
            node.simdPosition = (a + b) * 0.5
            node.simdScale = SIMD3<Float>(1, len, 1)   // 仅拉伸 Y 轴以匹配长度

            let dir = diff / len
            let up = SIMD3<Float>(0, 1, 0)
            let d = simd_clamp(dot(up, dir), -1.0, 1.0)
            if abs(d) > 0.9999 {
                node.simdOrientation = d > 0
                    ? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                    : simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
            } else {
                node.simdOrientation = simd_quatf(angle: acos(d), axis: normalize(cross(up, dir)))
            }
        }

        deinit { timer?.invalidate() }
    }
}
