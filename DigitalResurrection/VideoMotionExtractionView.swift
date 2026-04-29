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

    // MARK: - 3D 旋转计算
    private func calculateMotionFrame(landmarks: [NormalizedLandmark], worldLandmarks: [Landmark]?) -> MotionFrame {
        var currentFrameOrientations: [String: simd_quatf] = [:]

        // 坐标系对齐（基于实际骨骼调试数据确认）：
        // MediaPipe World: X+ = 人体右侧, Y+ = 上, Z+ = 朝摄像头
        // SceneKit 模型（面朝摄像头）: 左臂在 +X, 右臂在 -X
        // 即 MediaPipe X 与 SceneKit X 方向相反，必须取反 X
        // Z 方向：两者都是朝向观察者为正，不取反
        let points: [SIMD3<Float>]
        if let wl = worldLandmarks {
            points = wl.map { SIMD3<Float>(-Float($0.x), Float($0.y), Float($0.z)) }
        } else {
            // 归一化坐标：图像 X 从左到右，人面向摄像头时人体右侧在图像左侧
            // 0.5-x 等价于居中后取反，与 world landmarks 的 -x 逻辑一致
            points = landmarks.map { SIMD3<Float>(0.5 - Float($0.x), 0.5 - Float($0.y), -Float($0.z)) }
        }

        // 旋转计算（带边界保护 + 低通平滑）
        func getOrientation(name: String, from: Int, to: Int, restDir: SIMD3<Float>) -> simd_quatf {
            guard from < points.count, to < points.count else {
                return lastOrientations[name] ?? simd_quaternion(0, SIMD3<Float>(0, 0, 1))
            }
            let diff = points[to] - points[from]
            let len = simd_length(diff)
            guard len > 1e-6 else {
                return lastOrientations[name] ?? simd_quaternion(0, SIMD3<Float>(0, 0, 1))
            }
            let targetDir = diff / len
            let sourceDir = normalize(restDir)
            let dotProduct = simd_clamp(dot(sourceDir, targetDir), -1.0, 1.0)

            var quat: simd_quatf
            if dotProduct > 0.9999 {
                quat = simd_quaternion(0, SIMD3<Float>(0, 0, 1))
            } else if dotProduct < -0.9999 {
                quat = simd_quaternion(Float.pi, SIMD3<Float>(0, 1, 0))
            } else {
                let axis = normalize(cross(sourceDir, targetDir))
                quat = simd_quaternion(acos(dotProduct), axis)
            }

            if let prev = lastOrientations[name] {
                quat = simd_slerp(prev, quat, 0.4)
            }
            lastOrientations[name] = quat
            return quat
        }

        // restDir 来自调试数据中 T-Pose 骨骼的实际世界方向（取反 X 后）
        // LeftArm:    (21.98→46.33, 127.78→123.22) → 取反X后 normalized ≈ (0.98, -0.18, 0)
        // RightArm:   (-21.98→-46.33) → 取反X后 ≈ (-0.98, -0.18, 0)
        // LeftUpLeg:  (10.33→16.49, 86.94→47.47) normalized ≈ (0.154, -0.985, -0.08)
        // 用精确 restDir 消除骨骼对齐误差
        let lArmRest  = normalize(SIMD3<Float>(0.98, -0.18, 0))
        let rArmRest  = normalize(SIMD3<Float>(-0.98, -0.18, 0))
        let lLegRest  = normalize(SIMD3<Float>(0.154, -0.985, -0.08))
        let rLegRest  = normalize(SIMD3<Float>(-0.154, -0.985, 0.083))

        currentFrameOrientations["LeftArm"]     = getOrientation(name: "LA",  from: 11, to: 13, restDir: lArmRest)
        currentFrameOrientations["LeftForeArm"] = getOrientation(name: "LFA", from: 13, to: 15, restDir: lArmRest)
        currentFrameOrientations["RightArm"]     = getOrientation(name: "RA",  from: 12, to: 14, restDir: rArmRest)
        currentFrameOrientations["RightForeArm"] = getOrientation(name: "RFA", from: 14, to: 16, restDir: rArmRest)

        // 腿部（用实测 T-Pose 方向）
        currentFrameOrientations["LeftUpLeg"]  = getOrientation(name: "LUL", from: 23, to: 25, restDir: lLegRest)
        currentFrameOrientations["LeftLeg"]    = getOrientation(name: "LL",  from: 25, to: 27, restDir: lLegRest)
        currentFrameOrientations["RightUpLeg"] = getOrientation(name: "RUL", from: 24, to: 26, restDir: rLegRest)
        currentFrameOrientations["RightLeg"]   = getOrientation(name: "RL",  from: 26, to: 28, restDir: rLegRest)

        // 重心位移（优先用 world landmarks 的米制坐标，避免归一化坐标的畸变）
        let rootX: Float
        let rootY: Float
        if let wl = worldLandmarks, wl.count > 24 {
            rootX = (Float(wl[23].x) + Float(wl[24].x)) * 0.5
            rootY = (Float(wl[23].y) + Float(wl[24].y)) * 0.5
        } else if landmarks.count > 24 {
            rootX = (Float(landmarks[23].x) + Float(landmarks[24].x)) * 0.5 - 0.5
            rootY = 0.5 - (Float(landmarks[23].y) + Float(landmarks[24].y)) * 0.5
        } else {
            rootX = 0; rootY = 0
        }

        return MotionFrame(
            boneWorldOrientations: currentFrameOrientations,
            rootOffset: SCNVector3(rootX * 1.5, rootY * 1.5, 0)
        )
    }
}

// MARK: - SceneKit 驱动容器

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
            // 移除所有动画
            scene.rootNode.enumerateChildNodes { node, _ in node.removeAllAnimations() }

            // ── 调试：打印所有节点名，帮助确认骨骼名称 ──
            print("===== SCENE NODES =====")
            scene.rootNode.enumerateChildNodes { node, _ in
                guard let name = node.name else { return }
                let p = node.worldPosition
                print(String(format: "[Node] '%@'  worldPos=(%.2f, %.2f, %.2f)", name, p.x, p.y, p.z))
            }
            print("=======================")

            // ── 调试：打印 Skeleton 父节点的世界变换，了解其是否有旋转偏移 ──
            let skelNames = ["Skeleton", "mixamorig_Hips", "mixamorig:Hips", "Hips", "Armature"]
            for sn in skelNames {
                if let skelNode = scene.rootNode.childNode(withName: sn, recursively: true) {
                    let q = skelNode.simdOrientation
                    let wq = simd_quaternion(skelNode.simdWorldTransform)
                    print(String(format: "[%@] localOrient ix=%.3f iy=%.3f iz=%.3f r=%.3f", sn, q.imag.x, q.imag.y, q.imag.z, q.real))
                    print(String(format: "[%@] worldOrient ix=%.3f iy=%.3f iz=%.3f r=%.3f", sn, wq.imag.x, wq.imag.y, wq.imag.z, wq.real))
                    break
                }
            }

            // ── 通过 SCNSkinner 拿到真正的骨骼节点（不依赖名字）并重置为 T-Pose ──
            var skinnerBones: [SCNNode] = []
            scene.rootNode.enumerateChildNodes { node, _ in
                if let skinner = node.skinner {
                    print("[Skinner] found on '\(node.name ?? "-")' with \(skinner.bones.count) bones")
                    for bone in skinner.bones {
                        print("[Bone] '\(bone.name ?? "nil")'")
                        // 清为 identity = Mixamo bind pose = T-Pose
                        bone.simdOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                    }
                    skinnerBones = skinner.bones
                }
            }

            // ── 调试：打印 Spine 骨骼在 T-Pose 重置后的变换 ──
            let spineNames = ["Spine", "mixamorig_Spine", "mixamorig:Spine"]
            for sn in spineNames {
                if let spineNode = scene.rootNode.childNode(withName: sn, recursively: true) {
                    let q = spineNode.simdOrientation
                    let wq = simd_quaternion(spineNode.simdWorldTransform)
                    let wp = spineNode.simdWorldTransform.columns.3
                    print(String(format: "[Spine-TPose] localOrient ix=%.3f iy=%.3f iz=%.3f r=%.3f", q.imag.x, q.imag.y, q.imag.z, q.real))
                    print(String(format: "[Spine-TPose] worldOrient ix=%.3f iy=%.3f iz=%.3f r=%.3f", wq.imag.x, wq.imag.y, wq.imag.z, wq.real))
                    print(String(format: "[Spine-TPose] worldPos=(%.2f, %.2f, %.2f)", wp.x, wp.y, wp.z))
                    if let par = spineNode.parent {
                        let pq = simd_quaternion(par.simdWorldTransform)
                        print(String(format: "[Spine-parent '%@'] worldOrient ix=%.3f iy=%.3f iz=%.3f r=%.3f", par.name ?? "?", pq.imag.x, pq.imag.y, pq.imag.z, pq.real))
                    }
                    break
                }
            }

            // 如果没找到 skinner，退而用名字匹配
            if skinnerBones.isEmpty {
                print("[Warning] No skinner found, falling back to name-based reset")
                scene.rootNode.enumerateChildNodes { node, _ in
                    guard let name = node.name else { return }
                    let lower = name.lowercased()
                    let isBone = lower.contains("mixamorig") ||
                                 lower.contains("hip") || lower.contains("spine") ||
                                 lower.contains("arm") || lower.contains("leg") ||
                                 lower.contains("foot") || lower.contains("hand") ||
                                 lower.contains("shoulder") || lower.contains("knee") ||
                                 lower.contains("neck") || lower.contains("head")
                    if isBone { node.simdOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
                }
            }

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
            // 按层级顺序驱动：先驱动父骨骼，再驱动子骨骼，保证旋转叠加正确
            // 层级从上往下驱动：Spine 先于手臂（Spine 是手臂父链的一部分）
            let orderedBones = ["LeftArm", "LeftForeArm",
                                "RightArm", "RightForeArm",
                                "LeftUpLeg", "LeftLeg",
                                "RightUpLeg", "RightLeg"]
            // 视频抽帧 32fps ÷ 2 = 16fps，播放也用 16fps 保证时序一致
            timer = Timer.scheduledTimer(withTimeInterval: 1.0/16.0, repeats: true) { _ in
                guard !frames.isEmpty else { return }
                let frame = frames[self.frameIndex]
                for boneName in orderedBones {
                    if let worldOrient = frame.boneWorldOrientations[boneName] {
                        self.applyBoneRotation(scene, boneName, worldOrient)
                    }
                }
                self.frameIndex = (self.frameIndex + 1) % frames.count
            }
        }

        // 从含 scale 的 4x4 矩阵中安全提取纯旋转四元数
        private func extractRotation(from matrix: simd_float4x4) -> simd_quatf {
            let c0 = SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
            let c1 = SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
            let c2 = SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
            let n0 = simd_length(c0) > 1e-6 ? normalize(c0) : SIMD3<Float>(1, 0, 0)
            let n1 = simd_length(c1) > 1e-6 ? normalize(c1) : SIMD3<Float>(0, 1, 0)
            let n2 = simd_length(c2) > 1e-6 ? normalize(c2) : SIMD3<Float>(0, 0, 1)
            let rotMatrix = simd_float4x4(columns: (
                SIMD4<Float>(n0.x, n0.y, n0.z, 0),
                SIMD4<Float>(n1.x, n1.y, n1.z, 0),
                SIMD4<Float>(n2.x, n2.y, n2.z, 0),
                SIMD4<Float>(0, 0, 0, 1)
            ))
            return simd_quaternion(rotMatrix)
        }

        private func applyBoneRotation(_ scene: SCNScene, _ name: String, _ worldOrient: simd_quatf) {
            let possibleNames = [name, "mixamorig_" + name, "mixamorig:" + name]
            for boneName in possibleNames {
                if let boneNode = scene.rootNode.childNode(withName: boneName, recursively: true) {
                    if let parent = boneNode.parent {
                        // 用 scale 安全的旋转提取，避免 simd_quaternion(matrix) 在 scale≠1 时出错
                        let parentWorldRot = extractRotation(from: parent.simdWorldTransform)
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
