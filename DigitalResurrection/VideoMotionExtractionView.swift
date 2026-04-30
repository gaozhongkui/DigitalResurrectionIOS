import SwiftUI
import PhotosUI
import AVKit
import MediaPipeTasksVision
import SceneKit
import simd

// MARK: - 动作帧
struct MotionFrame: Identifiable {
    let id = UUID()
    var pts: [SIMD3<Float>]       // 33 个 MediaPipe world 坐标
    var rootOffset: SCNVector3
}

struct VideoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) }
            importing: { received in
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent(received.file.lastPathComponent)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: received.file, to: dst)
                return VideoFile(url: dst)
            }
    }
}

// MARK: - Main View

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
                        .fill(Color.secondary.opacity(0.1)).frame(height: 380)
                    if let videoURL {
                        VideoPlayer(player: AVPlayer(url: videoURL))
                            .frame(height: 360).cornerRadius(12).padding(10)
                    } else {
                        VStack(spacing: 15) {
                            Image(systemName: "video.badge.plus.fill")
                                .font(.system(size: 60)).foregroundColor(.gray)
                            Text("选择一段清晰的全身舞蹈视频")
                                .font(.callout).foregroundColor(.gray)
                        }
                    }
                    if isProcessing {
                        Color.black.opacity(0.7).cornerRadius(16)
                        VStack(spacing: 20) {
                            ProgressView(value: progress, total: 1.0).tint(.blue).frame(width: 200)
                            Text(statusMessage).foregroundColor(.white).font(.headline)
                        }
                    }
                }.padding()

                VStack(spacing: 12) {
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        Label("选择视频", systemImage: "play.rectangle.on.rectangle.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                            .background(Color.blue).foregroundColor(.white).cornerRadius(12)
                    }.onChange(of: selectedItem) { _ in loadVideo() }

                    Button { processVideo() } label: {
                        Label("MediaPipe 3D 提取", systemImage: "figure.walk.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                            .background(videoURL == nil || isProcessing ? Color.gray : Color.purple)
                            .foregroundColor(.white).cornerRadius(12)
                    }.disabled(videoURL == nil || isProcessing)
                }.padding(.horizontal)
                Spacer()
            }
            .navigationTitle("AI 视频驱动")
            .fullScreenCover(isPresented: $showResult) {
                let url = Bundle.main.url(forResource: "Strut Walking", withExtension: "usdz")!
                RealMotionSceneView(modelURL: url, frames: capturedMotion)
            }
        }
    }

    private func loadVideo() {
        Task {
            if let m = try? await selectedItem?.loadTransferable(type: VideoFile.self) {
                videoURL = m.url; statusMessage = "视频已就绪"
            }
        }
    }

    private func processVideo() {
        guard let url = videoURL else { return }
        isProcessing = true; progress = 0; statusMessage = "AI 识别中…"; capturedMotion = []
        Task(priority: .userInitiated) {
            guard let mp = Bundle.main.path(forResource: "pose_landmarker_full", ofType: "task") else {
                await MainActor.run { isProcessing = false; statusMessage = "模型文件丢失" }; return
            }
            let opts = PoseLandmarkerOptions()
            opts.baseOptions.modelAssetPath = mp; opts.runningMode = .video; opts.numPoses = 1
            let lmk = try! PoseLandmarker(options: opts)
            let asset = AVURLAsset(url: url)
            let reader = try! AVAssetReader(asset: asset)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
            let output = AVAssetReaderTrackOutput(track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); reader.startReading()
            var fi = 0
            let totalMs = (try? await asset.load(.duration))?.seconds ?? 1.0
            while let sb = output.copyNextSampleBuffer() {
                fi += 1; if fi % 2 != 0 { continue }
                guard let ib = CMSampleBufferGetImageBuffer(sb) else { continue }
                let ts = Int(CMSampleBufferGetPresentationTimeStamp(sb).seconds * 1000)
                if let res = try? lmk.detect(videoFrame: try! MPImage(pixelBuffer: ib), timestampInMilliseconds: ts),
                   let wl = res.worldLandmarks.first {
                    // MediaPipe World: X+=观察者右 Y+=上 Z+=朝摄像头，与 SceneKit 一致，直接映射
                    let pts = wl.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
                    let frame = MotionFrame(pts: pts, rootOffset: .init(0, 0, 0))
                    await MainActor.run {
                        capturedMotion.append(frame)
                        progress = min(Double(ts)/(totalMs*1000), 0.99)
                        statusMessage = "已提取 \(capturedMotion.count) 帧"
                    }
                }
                if capturedMotion.count >= 900 { break }
            }
            await MainActor.run { isProcessing = false; showResult = !capturedMotion.isEmpty }
        }
    }
}

// MARK: - SceneKit

struct SCNMotionContainer: UIViewRepresentable {
    let modelURL: URL
    let frames: [MotionFrame]
    @Binding var frameIndex: Int

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView(); v.backgroundColor = .black
        v.autoenablesDefaultLighting = true; v.allowsCameraControl = true
        guard let scene = try? SCNScene(url: modelURL, options: nil) else { return v }

        // 移除动画但【不清零旋转】——Strut Walking.usdz 的 T-Pose 由非 identity bind pose 旋转定义
        // 清零会使所有骨骼垂直叠加（direction 全变成 (0,1,0)）
        scene.rootNode.enumerateChildNodes { n, _ in n.removeAllAnimations() }

        // 在原始加载状态下测量真实 T-Pose 骨骼方向，同时记录每根骨骼的初始旋转
        context.coordinator.measureTPose(scene: scene)

        let cam = SCNNode(); cam.camera = SCNCamera()
        cam.position = SCNVector3(0, 1.0, 3.5)
        scene.rootNode.addChildNode(cam)
        v.scene = scene
        context.coordinator.start(scene: scene, frames: frames)
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(fi: $frameIndex) }

    // MARK: - Coordinator

    class Coordinator {
        var timer: Timer?
        @Binding var frameIndex: Int

        struct BoneCfg {
            let mpA: Int, mpB: Int    // MediaPipe 关节索引（骨骼起点/终点）
            let childName: String     // SceneKit 子骨骼名（测量方向用）
            // 以下字段在 measureTPose 时填充
            var tPoseDir: SIMD3<Float> = .init(0,1,0)      // T-Pose 时骨骼的世界方向
            var tPoseLocalOr: simd_quatf = .init(ix:0,iy:0,iz:0,r:1) // T-Pose 时骨骼自身的局部旋转
            var tPoseParentRot: simd_quatf = .init(ix:0,iy:0,iz:0,r:1) // T-Pose 时父骨骼的世界旋转
        }

        var cfgs: [String: BoneCfg] = [
            "LeftArm":      .init(mpA:11, mpB:13, childName:"LeftForeArm"),
            "LeftForeArm":  .init(mpA:13, mpB:15, childName:"LeftHand"),
            "RightArm":     .init(mpA:12, mpB:14, childName:"RightForeArm"),
            "RightForeArm": .init(mpA:14, mpB:16, childName:"RightHand"),
            "LeftUpLeg":    .init(mpA:23, mpB:25, childName:"LeftLeg"),
            "LeftLeg":      .init(mpA:25, mpB:27, childName:"LeftFoot"),
            "RightUpLeg":   .init(mpA:24, mpB:26, childName:"RightLeg"),
            "RightLeg":     .init(mpA:26, mpB:28, childName:"RightFoot"),
        ]

        // Spine 单独存
        var spineTPoseDir: SIMD3<Float> = .init(0,1,0)
        var spineTPoseLocalOr: simd_quatf = .init(ix:0,iy:0,iz:0,r:1)
        var spineTPoseParentRot: simd_quatf = .init(ix:0,iy:0,iz:0,r:1)

        var smoothBuf: [String: simd_quatf] = [:]

        init(fi: Binding<Int>) { _frameIndex = fi }

        // ── 测量 T-Pose（不清零旋转，直接读取加载后的状态）──
        func measureTPose(scene: SCNScene) {
            for key in cfgs.keys {
                guard let bone  = find(scene, key),
                      let child = find(scene, cfgs[key]!.childName) else {
                    print("[TPose] '\(key)' or child '\(cfgs[key]!.childName)' NOT FOUND")
                    continue
                }
                let dir = wpos(child) - wpos(bone)
                let len = simd_length(dir); guard len > 1e-6 else { continue }
                cfgs[key]?.tPoseDir      = dir / len
                cfgs[key]?.tPoseLocalOr  = bone.simdOrientation
                cfgs[key]?.tPoseParentRot = bone.parent.map { extractRot($0.simdWorldTransform) }
                    ?? simd_quatf(ix:0,iy:0,iz:0,r:1)
                print(String(format:"[TPose] %-14@ dir=(%.3f,%.3f,%.3f)", key, dir.x/len, dir.y/len, dir.z/len))
            }
            // Spine
            if let s = find(scene,"Spine"), let s1 = find(scene,"Spine1") {
                let dir = wpos(s1) - wpos(s); let len = simd_length(dir)
                if len > 1e-6 {
                    spineTPoseDir      = dir / len
                    spineTPoseLocalOr  = s.simdOrientation
                    spineTPoseParentRot = s.parent.map { extractRot($0.simdWorldTransform) }
                        ?? simd_quatf(ix:0,iy:0,iz:0,r:1)
                    print(String(format:"[TPose] Spine           dir=(%.3f,%.3f,%.3f)", dir.x/len, dir.y/len, dir.z/len))
                }
            }
        }

        func start(scene: SCNScene, frames: [MotionFrame]) {
            timer?.invalidate()
            let order = ["Spine","Spine1","LeftArm","LeftForeArm",
                         "RightArm","RightForeArm","LeftUpLeg","LeftLeg","RightUpLeg","RightLeg"]

            timer = Timer.scheduledTimer(withTimeInterval: 1/16.0, repeats: true) { [weak self] _ in
                guard let self, !frames.isEmpty else { return }
                let p = frames[self.frameIndex].pts
                guard p.count > 28 else { self.frameIndex=(self.frameIndex+1)%frames.count; return }

                for name in order {
                    if name == "Spine" || name == "Spine1" {
                        self.driveSpine(scene, name: name, pts: p)
                    } else if let cfg = self.cfgs[name] {
                        let boneDir = safeNorm(p[cfg.mpB] - p[cfg.mpA])
                        guard let d = boneDir else { continue }
                        self.driveBone(scene, name: name, cfg: cfg, targetDir: d)
                    }
                }
                self.frameIndex = (self.frameIndex+1) % frames.count
            }
        }

        // ── 驱动单根骨骼 ──
        // 公式推导：
        //   T-Pose 时：bone.worldRot = tPoseParentRot * tPoseLocalOr
        //   驱动后期望：bone.worldRot = deltaRot * tPoseParentRot * tPoseLocalOr
        //   bone.simdOrientation = parent.worldRot⁻¹ * bone.worldRot
        //                        = pRot⁻¹ * deltaRot * tPoseParentRot * tPoseLocalOr
        //   T-Pose 验证（delta=I, pRot=tPoseParentRot）：= tPoseLocalOr ✓
        private func driveBone(_ scene: SCNScene, name: String, cfg: BoneCfg, targetDir: SIMD3<Float>) {
            let delta = swingRot(from: cfg.tPoseDir, to: targetDir, key: name)
            applyBone(scene, name, delta, tPoseParentRot: cfg.tPoseParentRot, tPoseLocalOr: cfg.tPoseLocalOr)
        }

        private func driveSpine(_ scene: SCNScene, name: String, pts: [SIMD3<Float>]) {
            let hc = (pts[23]+pts[24])*0.5
            let sc = (pts[11]+pts[12])*0.5
            guard let d = safeNorm(sc - hc) else { return }
            let delta = swingRot(from: spineTPoseDir, to: d, key: name)
            applyBone(scene, name, delta, tPoseParentRot: spineTPoseParentRot, tPoseLocalOr: spineTPoseLocalOr)
        }

        private func applyBone(_ scene: SCNScene, _ name: String, _ delta: simd_quatf,
                                tPoseParentRot: simd_quatf, tPoseLocalOr: simd_quatf) {
            guard let bone = find(scene, name), let par = bone.parent else { return }
            let pRot = extractRot(par.simdWorldTransform)
            bone.simdOrientation = pRot.inverse * delta * tPoseParentRot * tPoseLocalOr
        }

        // 最小弧旋转（swing-only），带平滑
        private func swingRot(from src: SIMD3<Float>, to tgt: SIMD3<Float>, key: String) -> simd_quatf {
            let s = normalize(src), t = normalize(tgt)
            let d = simd_clamp(dot(s,t), -1, 1)
            var q: simd_quatf
            if d > 0.9999 {
                q = simd_quatf(ix:0,iy:0,iz:0,r:1)
            } else if d < -0.9999 {
                let perp = abs(s.x)<0.9 ? normalize(cross(s,.init(1,0,0))) : normalize(cross(s,.init(0,1,0)))
                q = simd_quaternion(Float.pi, perp)
            } else {
                q = simd_quaternion(acos(d), normalize(cross(s,t)))
            }
            if let prev = smoothBuf[key] { q = simd_slerp(prev, q, 0.65) }
            smoothBuf[key] = q; return q
        }

        private func extractRot(_ m: simd_float4x4) -> simd_quatf {
            func safe(_ c: SIMD4<Float>, _ fb: SIMD3<Float>) -> SIMD3<Float> {
                let v = SIMD3(c.x,c.y,c.z); return simd_length(v)>1e-6 ? normalize(v) : fb
            }
            return simd_quaternion(simd_float4x4(columns:(
                SIMD4(safe(m.columns.0,.init(1,0,0)),0),
                SIMD4(safe(m.columns.1,.init(0,1,0)),0),
                SIMD4(safe(m.columns.2,.init(0,0,1)),0),
                SIMD4(0,0,0,1))))
        }

        private func safeNorm(_ v: SIMD3<Float>) -> SIMD3<Float>? {
            let l = simd_length(v); return l > 1e-6 ? v/l : nil
        }

        private func wpos(_ n: SCNNode) -> SIMD3<Float> {
            let c = n.simdWorldTransform.columns.3; return .init(c.x,c.y,c.z)
        }

        private func find(_ scene: SCNScene, _ name: String) -> SCNNode? {
            for p in ["","mixamorig_","mixamorig:"] {
                if let n = scene.rootNode.childNode(withName:p+name, recursively:true) { return n }
            }; return nil
        }
    }
}

// MARK: - 结果展示

struct RealMotionSceneView: View {
    let modelURL: URL
    let frames: [MotionFrame]
    @Environment(\.dismiss) var dismiss
    @State private var idx = 0
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SCNMotionContainer(modelURL: modelURL, frames: frames, frameIndex: $idx).ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.largeTitle)
                            .foregroundColor(.white.opacity(0.8)).padding()
                    }
                }
                Spacer()
                Text("帧 \(idx+1)/\(frames.count)").font(.caption)
                    .foregroundColor(.white.opacity(0.5)).padding(.bottom, 30)
            }
        }
    }
}
