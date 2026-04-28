import SwiftUI
import PhotosUI
import SceneKit

struct AniGenGeneratorView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var isGenerating = false
    @State private var generatedModelURL: URL?
    @State private var statusMessage = "请选择一张照片开始"
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // 1. 图片预览区域
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(height: 350)

                    if let selectedImage {
                        Image(uiImage: selectedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 330)
                            .cornerRadius(12)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            Text("点击下方按钮选择人像照片")
                                .font(.callout)
                                .foregroundColor(.gray)
                        }
                    }

                    if isGenerating {
                        Color.black.opacity(0.6)
                            .cornerRadius(16)
                        VStack(spacing: 15) {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.5)
                            Text(statusMessage)
                                .foregroundColor(.white)
                                .font(.headline)
                        }
                    }
                }
                .padding()

                // 2. 操作按钮
                VStack(spacing: 12) {
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Label("从相册选择", systemImage: "photo.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .onChange(of: selectedItem) { _ in loadSelectedImage() }

                    Button {
                        generate3DModel()
                    } label: {
                        Label("AniGen AI 生成并跳舞", systemImage: "sparkles")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(selectedImage == nil || isGenerating ? Color.gray : Color.purple)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .disabled(selectedImage == nil || isGenerating)
                }
                .padding(.horizontal)

                Text("提示：使用全身正面照效果更佳")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)

                Spacer()
            }
            .navigationTitle("3D 形象复活")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .fullScreenCover(item: $generatedModelURL) { url in
                ModelDancePreviewScreen(modelURL: url)
            }
        }
    }

    private func loadSelectedImage() {
        Task {
            if let data = try? await selectedItem?.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                selectedImage = uiImage
            }
        }
    }

    private func generate3DModel() {
        guard selectedImage != nil else { return }
        isGenerating = true
        statusMessage = "上传中..."

        // 模拟 API 生成流程
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            statusMessage = "AniGen AI 正在重建 3D 骨架..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                statusMessage = "生成纹理贴图..."
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    // 模拟生成成功，加载演示 USDZ
                    if let demoURL = Bundle.main.url(forResource: "Strut Walking", withExtension: "usdz") {
                        self.generatedModelURL = demoURL
                    }
                    isGenerating = false
                }
            }
        }
    }
}

// MARK: - 预览与动画页面

struct ModelDancePreviewScreen: View {
    let modelURL: URL
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                DanceSceneView(modelURL: modelURL)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
                    Text("AniGen 生成完成")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.bottom, 20)
                }
            }
            .navigationTitle("生成预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                        .fontWeight(.bold)
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

struct DanceSceneView: UIViewRepresentable {
    let modelURL: URL

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = .black
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.antialiasingMode = .multisampling4X

        if let scene = try? SCNScene(url: modelURL, options: [
            SCNSceneSource.LoadingOption.animationImportPolicy: SCNSceneSource.AnimationImportPolicy.playRepeatedly
        ]) {
            scnView.scene = scene

            // 播放所有内嵌动画
            playAllAnimations(in: scene.rootNode)

            // 自动调整相机
            let (center, radius) = boundingSphere(of: scene.rootNode)
            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.zFar = Double(radius) * 10
            cameraNode.position = SCNVector3(center.x, center.y + Float(radius) * 0.2, Float(radius) * 2.5)
            scene.rootNode.addChildNode(cameraNode)
            scnView.pointOfView = cameraNode
        }
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

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
        let radius = max(max(mx.x - mn.x, mx.y - mn.y), mx.z - mn.z) / 2
        return (center, radius)
    }
}

extension URL: Identifiable {
    public var id: String { self.absoluteString }
}
