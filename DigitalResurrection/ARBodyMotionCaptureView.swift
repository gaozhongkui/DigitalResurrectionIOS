import SwiftUI
import ARKit
import RealityKit

struct ARBodyMotionCaptureView: View {
    @Environment(\.dismiss) var dismiss
    @State private var isTracking = false

    var body: some View {
        ZStack {
            ARViewContainer(isTracking: $isTracking)
                .ignoresSafeArea()

            // 顶层 UI
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white.opacity(0.8))
                            .padding()
                    }
                    Spacer()

                    if isTracking {
                        HStack {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                            Text("正在追踪")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5))
                        .clipShape(Capsule())
                        .padding()
                    }
                }

                Spacer()

                if !isTracking {
                    VStack(spacing: 12) {
                        Image(systemName: "person.fill.viewfinder")
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                        Text("请将后置摄像头对准全身人像")
                            .foregroundColor(.white)
                            .font(.headline)
                        Text("站远一点，直到模型出现")
                            .foregroundColor(.white.opacity(0.7))
                            .font(.subheadline)
                    }
                    .padding(30)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                    .padding(.bottom, 100)
                }
            }
        }
    }
}

// MARK: - RealityKit AR 引擎

struct ARViewContainer: UIViewRepresentable {
    @Binding var isTracking: Bool

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // 1. 配置人像动作追踪
        guard ARBodyTrackingConfiguration.isSupported else {
            print("设备不支持 Body Tracking")
            return arView
        }

        let config = ARBodyTrackingConfiguration()
        config.automaticSkeletonScaleEstimationEnabled = true // 自动估算骨骼比例
        arView.session.run(config)

        arView.session.delegate = context.coordinator
        context.coordinator.arView = arView

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isTracking: $isTracking)
    }

    class Coordinator: NSObject, ARSessionDelegate {
        var arView: ARView?
        @Binding var isTracking: Bool

        // 存储加载的模型实体
        var character: BodyTrackedEntity?
        let characterAnchor = AnchorEntity()

        init(isTracking: Binding<Bool>) {
            self._isTracking = isTracking
            super.init()
            loadCharacter()
        }

        private func loadCharacter() {
            // 加载异步加载支持 RealityKit Body Tracking 的模型
            // 注意：模型必须符合特定的命名规范（如关节名需与 ARKit 一致）
            // 如果 Strut Walking.usdz 是标准的骨架，它会被自动驱动
            Entity.loadBodyTrackedAsync(named: "Strut Walking").sink(receiveCompletion: { completion in
                if case let .failure(error) = completion {
                    print("无法加载模型: \(error.localizedDescription)")
                }
            }, receiveValue: { [weak self] entity in
                if let bodyTrackedEntity = entity as? BodyTrackedEntity {
                    // 缩小一点点，方便在手机屏幕看全
                    bodyTrackedEntity.scale = [0.01, 0.01, 0.01]
                    self?.character = bodyTrackedEntity
                    print("模型加载成功，准备同步动作")
                }
            }).store(in: &cancellables)
        }

        private var cancellables = Set<AnyCancellable>()

        // ARSession 代理：当检测到人体锚点时
        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            for anchor in anchors {
                guard let bodyAnchor = anchor as? ARBodyAnchor else { continue }

                isTracking = true

                // 将模型添加到追踪到的锚点上
                let bodyAnchorEntity = AnchorEntity(anchor: bodyAnchor)
                if let character = character {
                    bodyAnchorEntity.addChild(character)
                    arView?.scene.addAnchor(bodyAnchorEntity)
                }
            }
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            for anchor in anchors {
                if let _ = anchor as? ARBodyAnchor {
                    if !isTracking { isTracking = true }
                }
            }
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            for anchor in anchors {
                if let _ = anchor as? ARBodyAnchor {
                    isTracking = false
                }
            }
        }
    }
}

import Combine
