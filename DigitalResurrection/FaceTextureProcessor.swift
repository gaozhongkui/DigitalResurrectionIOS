import UIKit
import Vision

struct FaceDetectionResult {
    let originalImage: UIImage
    let faceRect: CGRect        // 像素坐标，top-left 原点
    let leftEyeCenter: CGPoint
    let rightEyeCenter: CGPoint
    let allLandmarkPoints: [CGPoint]
}

final class FaceTextureProcessor {

    enum DetectionError: LocalizedError {
        case invalidImage, noFaceDetected
        var errorDescription: String? {
            switch self {
            case .invalidImage:   return "无效图片"
            case .noFaceDetected: return "未检测到人脸，请使用正面清晰的照片"
            }
        }
    }

    // MARK: - 人脸检测（异步，后台线程执行 Vision）

    func detect(in image: UIImage) async throws -> FaceDetectionResult {
        guard let cgImage = image.cgImage else { throw DetectionError.invalidImage }
        let pixelW = CGFloat(cgImage.width)
        let pixelH = CGFloat(cgImage.height)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectFaceLandmarksRequest { req, err in
                    if let err = err {
                        continuation.resume(throwing: err)
                        return
                    }
                    guard let face = (req.results as? [VNFaceObservation])?.first,
                          let lm = face.landmarks else {
                        continuation.resume(throwing: DetectionError.noFaceDetected)
                        return
                    }
                    let result = Self.build(image: image, face: face, landmarks: lm,
                                           pixelW: pixelW, pixelH: pixelH)
                    continuation.resume(returning: result)
                }

                let handler = VNImageRequestHandler(cgImage: cgImage,
                                                   orientation: image.cgOrientation)
                do    { try handler.perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: - 构造检测结果

    private static func build(image: UIImage,
                              face: VNFaceObservation,
                              landmarks: VNFaceLandmarks2D,
                              pixelW: CGFloat,
                              pixelH: CGFloat) -> FaceDetectionResult {
        let bb = face.boundingBox
        // Vision 坐标：归一化，左下原点 → UIKit 像素坐标：左上原点
        let faceRect = CGRect(
            x: bb.minX * pixelW,
            y: (1.0 - bb.maxY) * pixelH,
            width:  bb.width  * pixelW,
            height: bb.height * pixelH
        )

        // landmark 点：归一化，相对 faceRect，左下原点 → 像素坐标
        func toPixel(_ np: CGPoint) -> CGPoint {
            CGPoint(
                x: faceRect.minX + np.x * faceRect.width,
                y: faceRect.minY + (1.0 - np.y) * faceRect.height
            )
        }

        func centerOf(_ region: VNFaceLandmarkRegion2D?) -> CGPoint {
            guard let pts = region?.normalizedPoints, !pts.isEmpty else {
                return CGPoint(x: faceRect.midX, y: faceRect.midY)
            }
            let sum = pts.reduce(CGPoint.zero) {
                CGPoint(x: $0.x + CGFloat($1.x), y: $0.y + CGFloat($1.y))
            }
            let n = CGFloat(pts.count)
            return toPixel(CGPoint(x: sum.x / n, y: sum.y / n))
        }

        let leftEye  = centerOf(landmarks.leftEye)
        let rightEye = centerOf(landmarks.rightEye)

        // 收集所有特征区域的点（用于预览叠加）
        let regions: [VNFaceLandmarkRegion2D?] = [
            landmarks.leftEye, landmarks.rightEye,
            landmarks.leftEyebrow, landmarks.rightEyebrow,
            landmarks.nose, landmarks.noseCrest,
            landmarks.outerLips, landmarks.innerLips,
            landmarks.faceContour
        ]
        let allPoints = regions
            .compactMap { $0?.normalizedPoints }
            .flatMap { $0 }
            .map { toPixel(CGPoint(x: CGFloat($0.x), y: CGFloat($0.y))) }

        return FaceDetectionResult(
            originalImage: image,
            faceRect: faceRect,
            leftEyeCenter: leftEye,
            rightEyeCenter: rightEye,
            allLandmarkPoints: allPoints
        )
    }

    // MARK: - 生成对齐贴图（512×512 像素）

    /// 以双眼为基准对齐人脸，输出正方形纹理
    func generateTexture(from result: FaceDetectionResult, outputSize: Int = 512) -> UIImage {
        guard let cgImage = result.originalImage.cgImage else { return result.originalImage }
        let pixelW = CGFloat(cgImage.width)
        let pixelH = CGFloat(cgImage.height)

        let L = result.leftEyeCenter
        let R = result.rightEyeCenter
        let eyeMid   = CGPoint(x: (L.x + R.x) / 2, y: (L.y + R.y) / 2)
        let eyeDX    = R.x - L.x
        let eyeDY    = R.y - L.y
        let angle    = atan2(eyeDY, eyeDX)          // 双眼连线偏转角
        let eyeDist  = hypot(eyeDX, eyeDY)

        // 目标：双眼间距占输出宽度 40%，眼部中点在 38% 高度处
        let out = CGFloat(outputSize)
        let scale = eyeDist > 0 ? (out * 0.40) / eyeDist : 1.0

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1   // 1pt = 1px
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: out, height: out), format: format)

        return renderer.image { ctx in
            // 背景
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: out, height: out))

            let c = ctx.cgContext
            // 变换：眼中点 → 输出中心偏上位置，旋转拉伸对齐
            c.translateBy(x: out * 0.5, y: out * 0.38)
            c.rotate(by: -angle)
            c.scaleBy(x: scale, y: scale)
            c.translateBy(x: -eyeMid.x, y: -eyeMid.y)

            result.originalImage.draw(in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        }
    }

    // MARK: - 特征点叠加预览图

    func landmarkPreview(image: UIImage, result: FaceDetectionResult) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let pixelW = CGFloat(cgImage.width)
        let pixelH = CGFloat(cgImage.height)
        let dotR: CGFloat = max(3, pixelW / 200)   // 自适应点大小

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: pixelW, height: pixelH), format: format)

        return renderer.image { ctx in
            image.draw(in: CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
            let c = ctx.cgContext

            // 所有特征点：绿色小圆点
            c.setFillColor(UIColor.systemGreen.cgColor)
            for pt in result.allLandmarkPoints {
                c.fillEllipse(in: CGRect(
                    x: pt.x - dotR, y: pt.y - dotR,
                    width: dotR * 2, height: dotR * 2))
            }

            // 双眼中心：青色圆圈
            let eyeR: CGFloat = max(10, pixelW / 70)
            c.setStrokeColor(UIColor.cyan.cgColor)
            c.setLineWidth(max(2, pixelW / 400))
            for eye in [result.leftEyeCenter, result.rightEyeCenter] {
                c.strokeEllipse(in: CGRect(
                    x: eye.x - eyeR, y: eye.y - eyeR,
                    width: eyeR * 2, height: eyeR * 2))
            }

            // 双眼连线：辅助对齐参考
            c.setStrokeColor(UIColor.yellow.withAlphaComponent(0.7).cgColor)
            c.setLineWidth(max(1, pixelW / 500))
            c.move(to: result.leftEyeCenter)
            c.addLine(to: result.rightEyeCenter)
            c.strokePath()
        }
    }
}

// MARK: - UIImage Orientation 转换

extension UIImage {
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up:            return .up
        case .down:          return .down
        case .left:          return .left
        case .right:         return .right
        case .upMirrored:    return .upMirrored
        case .downMirrored:  return .downMirrored
        case .leftMirrored:  return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }
}
