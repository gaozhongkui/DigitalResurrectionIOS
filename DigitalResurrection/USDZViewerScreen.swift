import SwiftUI
import SceneKit

struct USDZViewerScreen: View {
    @State private var loadError: String? = nil

    var body: some View {
        ZStack {
            Color.black

            if let error = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.yellow)
                    Text(error)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            } else {
                SceneKitView(loadError: $loadError)
            }

            VStack {
                Spacer()
                HStack(spacing: 16) {
                    Label("拖拽旋转", systemImage: "hand.draw")
                    Label("捏合缩放", systemImage: "magnifyingglass")
                }
                .font(.caption)
                .foregroundColor(.white.opacity(0.4))
                .padding(.bottom, 20)
            }
        }
    }
}

struct SceneKitView: UIViewRepresentable {
    @Binding var loadError: String?

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = UIColor.black
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.antialiasingMode = .multisampling4X
        scnView.showsStatistics = false

        // 先放一个空场景占位，避免 makeUIView 阻塞主线程
        scnView.scene = SCNScene()

        loadSceneAsync(into: scnView)
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    // MARK: - 异步加载

    private func loadSceneAsync(into scnView: SCNView) {
        guard let url = Bundle.main.url(forResource: "Strut Walking", withExtension: "usdz") else {
            DispatchQueue.main.async { loadError = "找不到 Strut Walking.usdz" }
            return
        }

        // 步骤 1：后台线程解析 USDZ（避免主线程卡顿）
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let scene = try SCNScene(url: url, options: [
                    SCNSceneSource.LoadingOption.animationImportPolicy: SCNSceneSource.AnimationImportPolicy.playRepeatedly
                ])

                addLights(to: scene)
                let (center, radius) = boundingSphere(of: scene.rootNode)

                // 步骤 2：回主线程，用 prepare() 预热 GPU 资源
                // prepare() 在内部使用后台线程上传纹理/几何体，完成后回调才显示场景
                DispatchQueue.main.async {
                    scnView.prepare([scene]) { _ in
                        scnView.scene = scene
                        playAllAnimations(in: scene.rootNode)
                        setupCamera(in: scnView, scene: scene, center: center, radius: radius)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    loadError = "加载失败:\n\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 场景配置

    private func addLights(to scene: SCNScene) {
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 500
        ambientLight.color = UIColor.white
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        let directionalLight = SCNLight()
        directionalLight.type = .directional
        directionalLight.intensity = 800
        let lightNode = SCNNode()
        lightNode.light = directionalLight
        lightNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
        scene.rootNode.addChildNode(lightNode)
    }

    private func setupCamera(in scnView: SCNView, scene: SCNScene, center: SCNVector3, radius: Float) {
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zFar = CGFloat(radius) * 20
        cameraNode.position = SCNVector3(center.x, center.y, Float(radius) * 2.5)
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode
    }

    private func playAllAnimations(in node: SCNNode) {
        for key in node.animationKeys {
            if let player = node.animationPlayer(forKey: key) {
                player.animation.repeatCount = .greatestFiniteMagnitude
                player.play()
            }
        }
        for child in node.childNodes {
            playAllAnimations(in: child)
        }
    }

    private func boundingSphere(of node: SCNNode) -> (center: SCNVector3, radius: Float) {
        let (minBound, maxBound) = node.boundingBox
        let center = SCNVector3(
            (minBound.x + maxBound.x) / 2,
            (minBound.y + maxBound.y) / 2,
            (minBound.z + maxBound.z) / 2
        )
        let dx = maxBound.x - minBound.x
        let dy = maxBound.y - minBound.y
        let dz = maxBound.z - minBound.z
        let radius = Swift.max(Swift.max(dx, dy), dz) / 2
        return (center, radius)
    }
}
