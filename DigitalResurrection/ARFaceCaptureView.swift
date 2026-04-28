import SwiftUI
import ARKit
import SceneKit

// MARK: - 入口：自动检测设备支持情况

struct ARFaceCaptureView: View {
    @Binding var isPresented: Bool
    let onTextureReady: (UIImage) -> Void

    var body: some View {
        if ARFaceTrackingConfiguration.isSupported {
            ARFaceScannerRepresentable(isPresented: $isPresented, onTextureReady: onTextureReady)
                .ignoresSafeArea()
        } else {
            // 不支持 TrueDepth 时的降级提示
            VStack(spacing: 20) {
                Image(systemName: "camera.metering.none")
                    .font(.system(size: 56))
                    .foregroundColor(.secondary)
                Text("此设备不支持 TrueDepth 人脸扫描")
                    .font(.headline)
                Text("需要配备 Face ID 的 iPhone（iPhone X 及以上）")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("关闭") { isPresented = false }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}

// MARK: - UIViewControllerRepresentable 包装

struct ARFaceScannerRepresentable: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onTextureReady: (UIImage) -> Void

    func makeUIViewController(context: Context) -> ARFaceScannerVC {
        ARFaceScannerVC(
            onCapture: { texture in
                onTextureReady(texture)
                isPresented = false
            },
            onCancel: { isPresented = false }
        )
    }

    func updateUIViewController(_ vc: ARFaceScannerVC, context: Context) {}
}

// MARK: - ARKit 扫脸 ViewController

final class ARFaceScannerVC: UIViewController, ARSCNViewDelegate {

    // ── 回调 ──
    var onCapture: (UIImage) -> Void
    var onCancel:  () -> Void

    // ── ARKit ──
    private let sceneView   = ARSCNView()
    private var isFaceReady = false  // 人脸检测到 + 稳定

    // ── UI ──
    private let captureButton = UIButton(type: .custom)
    private let statusLabel   = UILabel()
    private let cancelButton  = UIButton(type: .system)
    private let guideLayer    = CAShapeLayer()  // 椭圆引导框
    private let processingView = UIActivityIndicatorView(style: .large)

    init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onCancel  = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupAR()
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = true
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sceneView.session.pause()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateGuideFrame()
    }

    // MARK: Setup

    private func setupAR() {
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        view.addSubview(sceneView)
    }

    private func setupUI() {
        // 椭圆引导框
        guideLayer.fillColor   = UIColor.clear.cgColor
        guideLayer.strokeColor = UIColor.white.withAlphaComponent(0.6).cgColor
        guideLayer.lineWidth   = 2
        guideLayer.lineDashPattern = [8, 4]
        view.layer.addSublayer(guideLayer)

        // 状态文字
        statusLabel.textColor     = .white
        statusLabel.font          = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.text          = "将面部对准框内"
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        statusLabel.layer.cornerRadius = 10
        statusLabel.clipsToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        // 拍摄按钮
        captureButton.layer.cornerRadius = 36
        captureButton.layer.borderWidth  = 4
        captureButton.layer.borderColor  = UIColor.white.cgColor
        captureButton.backgroundColor    = UIColor.white.withAlphaComponent(0.3)
        captureButton.isEnabled = false
        captureButton.alpha = 0.5
        captureButton.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captureButton)

        // 内圆（按钮装饰）
        let inner = UIView()
        inner.backgroundColor = .white
        inner.layer.cornerRadius = 26
        inner.isUserInteractionEnabled = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        captureButton.addSubview(inner)

        // 取消按钮
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)

        // 加载指示器
        processingView.color = .white
        processingView.hidesWhenStopped = true
        processingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(processingView)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: captureButton.topAnchor, constant: -24),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
            statusLabel.heightAnchor.constraint(equalToConstant: 36),

            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            captureButton.widthAnchor.constraint(equalToConstant: 72),
            captureButton.heightAnchor.constraint(equalToConstant: 72),

            inner.centerXAnchor.constraint(equalTo: captureButton.centerXAnchor),
            inner.centerYAnchor.constraint(equalTo: captureButton.centerYAnchor),
            inner.widthAnchor.constraint(equalToConstant: 52),
            inner.heightAnchor.constraint(equalToConstant: 52),

            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),

            processingView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            processingView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func updateGuideFrame() {
        let w = view.bounds.width * 0.72
        let h = w * 1.28
        let x = (view.bounds.width  - w) / 2
        let y = (view.bounds.height - h) / 2 - 30
        let rect = CGRect(x: x, y: y, width: w, height: h)
        guideLayer.path = UIBezierPath(ovalIn: rect).cgPath
    }

    // MARK: ARSCNViewDelegate

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard anchor is ARFaceAnchor,
              let device = sceneView.device,
              let faceGeo = ARSCNFaceGeometry(device: device) else { return }

        // 绿色半透明网格覆盖，帮助用户对准
        faceGeo.firstMaterial?.fillMode        = .lines
        faceGeo.firstMaterial?.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.5)
        node.geometry = faceGeo

        DispatchQueue.main.async { self.setFaceDetected(true) }
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let face = anchor as? ARFaceAnchor,
              let geo  = node.geometry as? ARSCNFaceGeometry else { return }
        DispatchQueue.main.async { geo.update(from: face.geometry) }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard anchor is ARFaceAnchor else { return }
        DispatchQueue.main.async { self.setFaceDetected(false) }
    }

    private func setFaceDetected(_ detected: Bool) {
        isFaceReady = detected
        UIView.animate(withDuration: 0.25) {
            self.captureButton.isEnabled = detected
            self.captureButton.alpha     = detected ? 1.0 : 0.5
            self.guideLayer.strokeColor  = (detected
                ? UIColor.systemGreen : UIColor.white).withAlphaComponent(0.8).cgColor
        }
        statusLabel.text = detected ? "面部已就绪，点击拍摄 ✓" : "将面部对准框内"
        statusLabel.textColor = detected ? .systemGreen : .white
    }

    // MARK: 拍摄

    @objc private func captureTapped() {
        guard isFaceReady else { return }

        captureButton.isEnabled = false
        processingView.startAnimating()
        statusLabel.text = "处理中…"

        // 从 ARSCNView 截图（已含正确的屏幕朝向 + 镜像校正）
        let snapshot = sceneView.snapshot()

        Task {
            let processor = FaceTextureProcessor()
            do {
                // 用 Vision 在截图上精确定位五官
                let result  = try await processor.detect(in: snapshot)
                let texture = processor.generateTexture(from: result, outputSize: 512)
                await MainActor.run { onCapture(texture) }
            } catch {
                // Vision 失败时直接用截图做粗略裁剪
                let fallback = cropFace(from: snapshot)
                await MainActor.run { onCapture(fallback) }
            }
        }
    }

    @objc private func cancelTapped() { onCancel() }

    // MARK: 粗略兜底：将截图中心区域裁出

    private func cropFace(from image: UIImage) -> UIImage {
        let size = image.size
        let side = min(size.width, size.height) * 0.75
        let rect = CGRect(
            x: (size.width  - side) / 2,
            y: (size.height - side) / 2 - size.height * 0.05,
            width: side, height: side
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { _ in
            image.draw(in: CGRect(
                x: -rect.origin.x * (512 / side),
                y: -rect.origin.y * (512 / side),
                width: size.width * (512 / side),
                height: size.height * (512 / side)
            ))
        }
    }
}
