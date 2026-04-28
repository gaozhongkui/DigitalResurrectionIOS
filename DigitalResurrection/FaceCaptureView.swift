import SwiftUI
import PhotosUI

struct FaceCaptureView: View {
    @Binding var isPresented: Bool
    let onTextureReady: (UIImage) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var previewImage: UIImage?
    @State private var generatedTexture: UIImage?
    @State private var isProcessing = false
    @State private var errorMessage: String?

    private let processor = FaceTextureProcessor()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // ── 预览区域 ──
                ZStack {
                    Color(.systemGroupedBackground)

                    if let preview = previewImage {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "person.crop.rectangle.badge.plus")
                                .font(.system(size: 64))
                                .foregroundColor(.secondary)
                            Text("选一张正面人脸照片\n系统会自动识别五官位置")
                                .multilineTextAlignment(.center)
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }

                    if isProcessing {
                        ZStack {
                            Color.black.opacity(0.45)
                                .ignoresSafeArea()
                            VStack(spacing: 10) {
                                ProgressView().tint(.white).scaleEffect(1.3)
                                Text("正在识别人脸特征点…")
                                    .foregroundColor(.white)
                                    .font(.caption)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.top)

                // ── 错误提示 ──
                if let err = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                // ── 生成贴图预览 + 应用按钮 ──
                if let texture = generatedTexture {
                    Divider().padding(.top, 12)
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("生成贴图").font(.caption2).foregroundColor(.secondary)
                            Image(uiImage: texture)
                                .resizable()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.accentColor, lineWidth: 1.5)
                                )
                        }
                        Spacer()
                        Button {
                            onTextureReady(texture)
                            isPresented = false
                        } label: {
                            Label("应用到模型", systemImage: "checkmark.circle.fill")
                                .font(.headline)
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }

                Divider()

                // ── 选图按钮 ──
                PhotosPicker(
                    selection: $pickerItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label("从相册选择照片", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .font(.headline)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("选择人脸照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let item = newItem else { return }
            process(item: item)
        }
    }

    // MARK: - 加载并处理

    private func process(item: PhotosPickerItem) {
        isProcessing = true
        errorMessage = nil
        previewImage = nil
        generatedTexture = nil

        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    throw FaceTextureProcessor.DetectionError.invalidImage
                }

                let result  = try await processor.detect(in: image)
                let preview = processor.landmarkPreview(image: image, result: result)
                let texture = processor.generateTexture(from: result)

                await MainActor.run {
                    previewImage     = preview
                    generatedTexture = texture
                    isProcessing     = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isProcessing = false
                }
            }
        }
    }
}
