import SwiftUI
import PhotosUI
import RealityKit
import Combine

struct AniGenGeneratorView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var isGenerating = false
    @State private var generatedModelURL: URL?
    @State private var statusMessage = "请选择照片"
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
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
                        Color.black.opacity(0.6).cornerRadius(16)
                        VStack(spacing: 15) {
                            ProgressView().tint(.white).scaleEffect(1.5)
                            Text(statusMessage).foregroundColor(.white).font(.headline)
                        }
                    }
                }
                .padding()

                VStack(spacing: 12) {
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Label("从相册选择", systemImage: "photo.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                            .background(Color.blue).foregroundColor(.white).cornerRadius(12)
                    }
                    .onChange(of: selectedItem) { _ in loadSelectedImage() }

                    Button {
                        generate3DModel()
                    } label: {
                        Label("AniGen AI 生成并跳舞", systemImage: "sparkles")
                            .font(.headline).frame(maxWidth: .infinity).padding()
                            .background(selectedImage == nil || isGenerating ? Color.gray : Color.purple)
                            .foregroundColor(.white).cornerRadius(12)
                    }
                    .disabled(selectedImage == nil || isGenerating)
                }
                .padding(.horizontal)
                Spacer()
            }
            .navigationTitle("3D 形象复活")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
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
        statusMessage = "AI 正在构建 3D 形象..."

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let modelURL = Bundle.main.url(forResource: "Strut Walking", withExtension: "usdz") ??
                          Bundle.main.url(forResource: "Strut Walking", withExtension: "usdz", subdirectory: "Resource")

            self.generatedModelURL = modelURL ?? URL(string: "debug://notfound")!
            isGenerating = false
        }
    }
}

// MARK: - 预览与动画页面 (RealityKit)

struct ModelDancePreviewScreen: View {
    let modelURL: URL
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RealityViewContainer(modelURL: modelURL)
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
                Text("RealityKit 渲染就绪")
                    .font(.caption.monospaced())
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.bottom, 20)
            }
        }
    }
}

struct RealityViewContainer: UIViewRepresentable {
    let modelURL: URL

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        arView.environment.background = .color(.black)

        if modelURL.scheme != "debug" {
            Entity.loadAsync(contentsOf: modelURL).sink(receiveCompletion: { _ in }, receiveValue: { entity in
                let anchor = AnchorEntity(world: [0, 0, 0])

                // 关键点：RealityKit 自动应用 USDZ 动画
                entity.availableAnimations.forEach { animation in
                    entity.playAnimation(animation.repeat())
                }

                // 自动调整位置，防止模型偏离视野
                entity.position = [0, -0.6, -2.0]

                anchor.addChild(entity)
                arView.scene.addAnchor(anchor)
            }).store(in: &context.coordinator.cancellables)
        } else {
            // 失败反馈：显示红色方块并自转
            let mesh = MeshResource.generateBox(size: 0.4)
            let material = SimpleMaterial(color: .red, isMetallic: true)
            let model = ModelEntity(mesh: mesh, materials: [material])
            let anchor = AnchorEntity(world: [0, 0, -1.5])
            anchor.addChild(model)
            arView.scene.addAnchor(anchor)
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var cancellables = Set<AnyCancellable>()
    }
}

extension URL: Identifiable {
    public var id: String { self.absoluteString }
}
