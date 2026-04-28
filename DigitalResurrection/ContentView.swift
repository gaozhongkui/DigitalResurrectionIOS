import SwiftUI

struct ContentView: View {
    @State private var showAniGen = false

    var body: some View {
        ZStack {
            // 主背景保持为你之前的面部扫描/查看器
            USDZViewerScreen()
                .ignoresSafeArea()

            // 底部入口按钮
            VStack {
                Spacer()

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
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                }
                .foregroundColor(.white)
                .padding(.bottom, 50)
            }
        }
        .fullScreenCover(isPresented: $showAniGen) {
            AniGenGeneratorView()
        }
    }
}
