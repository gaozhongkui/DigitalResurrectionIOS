import SwiftUI
import SceneKit

struct USDZViewerScreen: View {
    @State private var loadError: String?
    @State private var showFaceCapture = false
    @State private var showMaterialInspector = false
    @State private var faceTexture: UIImage?
    @State private var materialInfos: [MaterialInfo] = []

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
                SceneKitView(
                    loadError: $loadError,
                    faceTexture: $faceTexture,
                    materialInfos: $materialInfos
                )
            }

            // ── 顶部工具栏 ──
            VStack {
                HStack {
                    // 材质检查按钮
                    Button {
                        showMaterialInspector = true
                    } label: {
                        Label("材质", systemImage: "square.3.layers.3d")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .foregroundColor(.white)
                    }
                    .padding(.leading, 16)
                    .padding(.top, 30)
                    .safeAreaPadding(.top)

                    Spacer()

                    Button {
                        showFaceCapture = true
                    } label: {
                        Label("换脸", systemImage: "face.smiling")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .foregroundColor(.white)
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 30)
                    .safeAreaPadding(.top)
                }
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
        .ignoresSafeArea()
        .sheet(isPresented: $showFaceCapture) {
            ARFaceCaptureView(isPresented: $showFaceCapture) { texture in
                faceTexture = texture
            }
        }
        .sheet(isPresented: $showMaterialInspector) {
            MaterialInspectorView(materials: materialInfos)
        }
    }
}

// MARK: - 材质信息结构

struct MaterialInfo: Identifiable {
    let id = UUID()
    let nodeName: String
    let materialName: String
    let texturePreview: UIImage?   // 材质现有贴图缩略图（如果有）
}

// MARK: - 材质检查器

struct MaterialInspectorView: View {
    let materials: [MaterialInfo]

    var body: some View {
        NavigationStack {
            List(materials) { info in
                HStack(spacing: 12) {
                    if let preview = info.texturePreview {
                        Image(uiImage: preview)
                            .resizable()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.3))
                            .frame(width: 56, height: 56)
                            .overlay(Image(systemName: "photo.slash").foregroundColor(.secondary))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.materialName.isEmpty ? "(未命名材质)" : info.materialName)
                            .font(.headline)
                        Text("节点: \(info.nodeName.isEmpty ? "(未命名节点)" : info.nodeName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(info.texturePreview != nil ? "✓ 有贴图" : "无贴图（纯色）")
                            .font(.caption2)
                            .foregroundColor(info.texturePreview != nil ? .green : .orange)
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("模型材质列表")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if materials.isEmpty {
                    ContentUnavailableView("模型未加载", systemImage: "cube.transparent")
                }
            }
        }
    }
}

// MARK: - 不拦截触摸的 SCNView 子类
// SceneKit 的 allowsCameraControl 会懒加载添加手势识别器，重写 addGestureRecognizer
// 确保每一个被添加进来的识别器都不会阻断上层 SwiftUI 按钮的点击

private final class PassthroughSCNView: SCNView {
    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        gestureRecognizer.cancelsTouchesInView = false
        gestureRecognizer.delaysTouchesBegan  = false
        super.addGestureRecognizer(gestureRecognizer)
    }
}

// MARK: - SceneKit View

struct SceneKitView: UIViewRepresentable {
    @Binding var loadError: String?
    @Binding var faceTexture: UIImage?
    @Binding var materialInfos: [MaterialInfo]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let scnView = PassthroughSCNView()
        scnView.backgroundColor = UIColor.black
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.antialiasingMode = .multisampling4X
        scnView.showsStatistics = false
        scnView.scene = SCNScene()
        loadSceneAsync(into: scnView)
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // 仅当拿到新贴图时才替换（用对象标识避免重复应用）
        guard let texture = faceTexture,
              texture !== context.coordinator.lastAppliedTexture else { return }
        context.coordinator.lastAppliedTexture = texture
        applyFaceTexture(texture, to: uiView)
    }

    // MARK: Coordinator

    final class Coordinator {
        var lastAppliedTexture: UIImage?
    }

    // MARK: - 异步加载场景

    private func loadSceneAsync(into scnView: SCNView) {
        guard let url = Bundle.main.url(forResource: "Strut Walking", withExtension: "usdz") else {
            DispatchQueue.main.async { loadError = "找不到 Strut Walking.usdz" }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let scene = try SCNScene(url: url, options: [
                    SCNSceneSource.LoadingOption.animationImportPolicy:
                        SCNSceneSource.AnimationImportPolicy.playRepeatedly
                ])

                addLights(to: scene)
                let (center, radius) = boundingSphere(of: scene.rootNode)

                // 在控制台打印所有材质名，方便调试贴图效果
                debugPrintMaterials(in: scene.rootNode)

                DispatchQueue.main.async {
                    scnView.prepare([scene]) { _ in
                        scnView.scene = scene
                        playAllAnimations(in: scene.rootNode)
                        setupCamera(in: scnView, scene: scene, center: center, radius: radius)
                        materialInfos = collectMaterialInfos(from: scene.rootNode)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    loadError = "加载失败:\n\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 贴图替换

    private func applyFaceTexture(_ texture: UIImage, to scnView: SCNView) {
        guard let scene = scnView.scene else { return }

        // 优先匹配含人脸/头部关键词的材质
        let keywords = ["face", "head", "skin", "body", "char", "human"]
        var targets = findMaterials(keywords: keywords, in: scene.rootNode)

        // 没找到则用第一个材质（保证第一次能看到效果）
        if targets.isEmpty {
            targets = allMaterials(in: scene.rootNode)
            if let first = targets.first { targets = [first] }
        }

        for mat in targets {
            mat.diffuse.contents  = texture
            mat.diffuse.wrapS     = .clamp
            mat.diffuse.wrapT     = .clamp
        }

        print("[FaceTexture] 已替换 \(targets.count) 个材质：\(targets.compactMap(\.name))")
    }

    // MARK: - 场景辅助

    private func addLights(to scene: SCNScene) {
        let ambient = SCNLight()
        ambient.type      = .ambient
        ambient.intensity = 500
        ambient.color     = UIColor.white
        let ambientNode   = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let dir = SCNLight()
        dir.type          = .directional
        dir.intensity     = 800
        let dirNode       = SCNNode()
        dirNode.light     = dir
        dirNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
        scene.rootNode.addChildNode(dirNode)
    }

    private func setupCamera(in scnView: SCNView, scene: SCNScene,
                             center: SCNVector3, radius: Float) {
        let cam = SCNCamera()
        cam.zFar = CGFloat(radius) * 20
        let camNode = SCNNode()
        camNode.camera = cam
        camNode.position = SCNVector3(center.x, center.y, Float(radius) * 2.5)
        scene.rootNode.addChildNode(camNode)
        scnView.pointOfView = camNode
    }

    private func playAllAnimations(in node: SCNNode) {
        for key in node.animationKeys {
            if let player = node.animationPlayer(forKey: key) {
                player.animation.repeatCount = .greatestFiniteMagnitude
                player.play()
            }
        }
        node.childNodes.forEach { playAllAnimations(in: $0) }
    }

    private func boundingSphere(of node: SCNNode) -> (SCNVector3, Float) {
        let (mn, mx) = node.boundingBox
        let center = SCNVector3((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2)
        let radius = Swift.max(Swift.max(mx.x - mn.x, mx.y - mn.y), mx.z - mn.z) / 2
        return (center, radius)
    }

    // MARK: - 材质查找

    private func findMaterials(keywords: [String], in node: SCNNode) -> [SCNMaterial] {
        var result: [SCNMaterial] = []
        for mat in node.geometry?.materials ?? [] {
            let name = (mat.name ?? "").lowercased()
            if keywords.contains(where: { name.contains($0) }) {
                result.append(mat)
            }
        }
        node.childNodes.forEach { result += findMaterials(keywords: keywords, in: $0) }
        return result
    }

    private func allMaterials(in node: SCNNode) -> [SCNMaterial] {
        var result = node.geometry?.materials ?? []
        node.childNodes.forEach { result += allMaterials(in: $0) }
        return result
    }

    private func collectMaterialInfos(from node: SCNNode, nodeName: String = "") -> [MaterialInfo] {
        var result: [MaterialInfo] = []
        let name = node.name ?? nodeName
        for mat in node.geometry?.materials ?? [] {
            // 尝试提取现有贴图缩略图
            var preview: UIImage?
            if let img = mat.diffuse.contents as? UIImage {
                preview = img
            }
            result.append(MaterialInfo(
                nodeName: name,
                materialName: mat.name ?? "",
                texturePreview: preview
            ))
        }
        for child in node.childNodes {
            result += collectMaterialInfos(from: child, nodeName: child.name ?? name)
        }
        return result
    }

    private func debugPrintMaterials(in node: SCNNode, depth: Int = 0) {
        let pad = String(repeating: "  ", count: depth)
        if let geo = node.geometry, !geo.materials.isEmpty {
            print("\(pad)Node[\(node.name ?? "-")]: \(geo.materials.count) 个材质")
            for mat in geo.materials {
                print("\(pad)  · '\(mat.name ?? "unnamed")' diffuse=\(mat.diffuse.contents ?? "nil")")
            }
        }
        node.childNodes.forEach { debugPrintMaterials(in: $0, depth: depth + 1) }
    }
}
