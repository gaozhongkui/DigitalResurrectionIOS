import SwiftUI

struct ContentView: View {
    @State private var showAniGen = false
    @State private var showMotionCapture = false
    @State private var showVideoMotion = false

    var body: some View {
        ZStack {
            // 主背景
            USDZViewerScreen()
                .ignoresSafeArea()

            // 入口按钮
            VStack(spacing: 16) {
                Spacer()

                // 1. 动作捕捉入口
                Button {
                    showMotionCapture = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "figure.walk.motion")
                            .symbolRenderingMode(.multicolor)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("动作捕捉同步")
                                .font(.headline)
                            Text("真人驱动 3D 模型")
                                .font(.caption)
                                .opacity(0.8)
                        }
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 24)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                .foregroundColor(.white)

                // 2. 视频驱动入口 (新添加)
                Button {
                    showVideoMotion = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "video.badge.plus.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("视频驱动动作")
                                .font(.headline)
                            Text("从现有视频提取 3D 舞蹈")
                                .font(.caption)
                                .opacity(0.8)
                        }
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 24)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                .foregroundColor(.white)

                // 3. 原有的 3D 生成入口
                Button {
                    showAniGen = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI 形象复活")
                                .font(.headline)
                            Text("照片转 3D 舞蹈")
                                .font(.caption)
                                .opacity(0.8)
                        }
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 24)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                .foregroundColor(.white)
                .padding(.bottom, 50)
            }
        }
        .fullScreenCover(isPresented: $showAniGen) {
            AniGenGeneratorView()
        }
        .fullScreenCover(isPresented: $showMotionCapture) {
            ARBodyMotionCaptureView()
        }
        .fullScreenCover(isPresented: $showVideoMotion) {
            VideoMotionExtractionView()
        }
    }
}
