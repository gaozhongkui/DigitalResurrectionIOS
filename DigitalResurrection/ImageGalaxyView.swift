import SwiftUI
import Photos
import ImageIO

// MARK: - Models

enum GalaxyShape: String, CaseIterable {
    case sphere = "SPHERE", heart = "HEART", spiral = "SPIRAL"
    case dna = "DNA", vortex = "VORTEX", cosmos = "COSMOS", grid = "GALLERY"

    func next() -> GalaxyShape {
        let all = GalaxyShape.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var glowColor: Color {
        switch self {
        case .heart:  return Color(red: 1,     green: 0.176, blue: 0.333)
        case .dna:    return Color(red: 0.204, green: 0.780, blue: 0.349)
        case .vortex: return Color(red: 1,     green: 0.584, blue: 0)
        case .spiral: return Color(red: 0.345, green: 0.337, blue: 0.839)
        default:      return Color(red: 0,     green: 0.824, blue: 1)
        }
    }
}

private struct Vec3 { var x, y, z: Double }

struct StarParticle {
    let nx, ny: Float
    let size, opacity, twinkleOffset: Float
}

struct GalaxyImageParticle: Identifiable {
    let id: Int
    let image: CGImage?
    let index: Int
    let seed: Int
}

// MARK: - Seeded LCG Random

private struct SeededRandom {
    private var state: UInt64
    init(seed: Int) { state = UInt64(bitPattern: Int64(seed &+ 1)) }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 33) / Double(UInt32.max)
    }
}

// MARK: - 3D Engine

private func rotate(_ p: Vec3, rx: Double, ry: Double) -> Vec3 {
    let sy = sin(ry), cy = cos(ry), sx = sin(rx), cx = cos(rx)
    let qx = p.x * cy + p.z * sy
    let qy = p.y
    let qz = -p.x * sy + p.z * cy
    return Vec3(x: qx, y: qy * cx - qz * sx, z: qy * sx + qz * cx)
}

private func project(_ p: Vec3, w: CGFloat, h: CGFloat, zoom: CGFloat) -> (x: CGFloat, y: CGFloat, scale: CGFloat) {
    let fov = 850.0, camZ = 450.0
    let f = CGFloat(fov / (fov + p.z + camZ)) * zoom
    return (CGFloat(p.x) * f + w / 2, CGFloat(p.y) * f + h / 2, f)
}

private func positionFor(_ p: GalaxyImageParticle, shape: GalaxyShape, total: Int, time: Double, w: CGFloat, h: CGFloat) -> Vec3 {
    let t = Double(p.index) / Double(max(total - 1, 1))
    switch shape {
    case .sphere:
        let phi   = acos(1.0 - 2.0 * (Double(p.index) + 0.5) / Double(max(total, 1)))
        let theta = Double(p.index) * .pi * (3.0 - sqrt(5.0))
        return Vec3(x: 420 * sin(phi) * cos(theta), y: 420 * sin(phi) * sin(theta), z: 420 * cos(phi))
    case .heart:
        let a = t * 2 * Double.pi; let s = sin(a)
        return Vec3(x: 18 * 16 * s * s * s * 1.2,
                    y: -18 * (13*cos(a) - 5*cos(2*a) - 2*cos(3*a) - cos(4*a)) * 1.2,
                    z: 0)
    case .spiral:
        let angle = t * 6 * .pi + time * 0.15; let r = 50 + 250 * t
        return Vec3(x: r * cos(angle), y: (t - 0.5) * 520, z: r * sin(angle))
    case .dna:
        let off = (p.index % 2 == 0) ? 0.0 : Double.pi
        let angle = t * 4 * .pi + off + time * 0.1
        return Vec3(x: 150 * cos(angle), y: (t - 0.5) * 600, z: 150 * sin(angle))
    case .vortex:
        let angle = t * 8 * .pi + time * 0.5; let r = 20 + 350 * t
        return Vec3(x: r * cos(angle), y: r * sin(angle), z: -500 + t * 1000)
    case .cosmos:
        var rng = SeededRandom(seed: p.seed)
        return Vec3(x: (rng.next() - 0.5) * Double(w) * 1.5,
                    y: (rng.next() - 0.5) * Double(h) * 1.5,
                    z: (rng.next() - 0.5) * 600)
    case .grid:
        let cols = 5, rows = 8
        let col = p.index % cols, row = (p.index / cols) % rows, layer = p.index / (cols * rows)
        return Vec3(
            x: Double(col - (cols - 1) / 2) * Double(w) / Double(cols + 1) * 0.8,
            y: Double(row - (rows - 1) / 2) * Double(h) / Double(rows + 1) * 0.8,
            z: Double(layer - 1) * 200)
    }
}

private func makeHeartPath(cx: CGFloat, cy: CGFloat, size: CGFloat) -> Path {
    var path = Path()
    let s = Double(size)
    for i in 0...45 {
        let t   = Double(i) * 2 * Double.pi / 45
        let sin1 = sin(t)
        let curve = 13*cos(t) - 5*cos(2*t) - 2*cos(3*t) - cos(4*t)
        let px  = CGFloat(sin1 * sin1 * sin1 * s)
        let py  = CGFloat(-curve / 16.0 * s * 0.9)
        let pt  = CGPoint(x: cx + px, y: cy + py)
        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
    }
    path.closeSubpath()
    return path
}

// MARK: - ImageGalaxyView

struct ImageGalaxyView: View {
    var onDismiss: (() -> Void)? = nil

    @State private var particles:  [GalaxyImageParticle] = []
    @State private var stars:      [StarParticle]        = []
    @State private var isLoading   = true
    @State private var shape       = GalaxyShape.sphere
    @State private var selected:   GalaxyImageParticle?  = nil
    @State private var canvasSize  = CGSize.zero

    @GestureState private var liveDrag  = CGSize.zero
    @State private var accDrag          = CGSize.zero

    @GestureState private var liveScale: CGFloat = 1.0
    @State private var baseScale: CGFloat         = 1.0

    private var rotX: Double { (accDrag.height + liveDrag.height) / 180.0 }
    private var rotY: Double { (accDrag.width  + liveDrag.width)  / 180.0 }
    private var zoom: CGFloat { (baseScale * liveScale).clamped(to: 0.5...3.5) }

    var body: some View {
        ZStack {
            Color(red: 0.004, green: 0.004, blue: 0.012).ignoresSafeArea()

            // ── Galaxy Canvas ──
            TimelineView(.animation) { tl in
                let time = tl.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    drawBackground(&ctx, size: size, time: time)
                    drawParticles(&ctx, size: size, time: time)
                }
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { canvasSize = $0 }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($liveDrag) { v, state, _ in state = v.translation }
                    .onEnded { v in
                        accDrag.width  += v.translation.width
                        accDrag.height += v.translation.height
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .updating($liveScale) { v, state, _ in state = v }
                    .onEnded { v in baseScale = (baseScale * v).clamped(to: 0.5...3.5) }
            )
            .onTapGesture(count: 2) { shape = shape.next() }
            .onTapGesture { loc in handleTap(at: loc) }

            // ── HUD overlay ──
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    Button { onDismiss?() } label: {
                        Image(systemName: "arrow.left")
                            .foregroundColor(.white)
                            .frame(width: 22, height: 22)
                            .padding(8)
                            .background(Color.black.opacity(0.4), in: Capsule())
                    }
                    .padding(.leading, 12)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(shape.rawValue)
                            .foregroundColor(.white)
                            .fontWeight(.bold)
                            .font(.system(size: 18))
                            .tracking(2)
                        Rectangle()
                            .fill(shape.glowColor)
                            .frame(width: 30, height: 2)
                    }
                    .padding(.trailing, 20)
                }
                .padding(.top, 8)

                Spacer()

                HStack(spacing: 8) {
                    ForEach(GalaxyShape.allCases, id: \.self) { s in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(s == shape ? Color.white : Color.white.opacity(0.3))
                            .frame(width: s == shape ? 20 : 6, height: 4)
                            .animation(.easeInOut(duration: 0.25), value: shape)
                    }
                }
                .padding(.bottom, 30)
            }
            .ignoresSafeArea(edges: .top)

            // ── Loading ──
            if isLoading {
                ZStack {
                    Color(red: 0.004, green: 0.004, blue: 0.012).ignoresSafeArea()
                    VStack(spacing: 20) {
                        ZStack {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(shape.glowColor)
                                .scaleEffect(1.5)
                            Circle()
                                .fill(shape.glowColor.opacity(0.15))
                                .frame(width: 32, height: 32)
                        }
                        Text("正在加载星系...")
                            .foregroundColor(.white.opacity(0.6))
                            .font(.system(size: 13))
                            .tracking(1)
                    }
                }
                .transition(.opacity)
            }

            // ── Selected preview ──
            if let p = selected {
                Color.black.opacity(0.7)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { selected = nil } }

                if let img = p.image {
                    Image(img, scale: 1, orientation: .up, label: Text(""))
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: canvasSize.width * 0.9,
                               maxHeight: canvasSize.height * 0.7)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1))
                        .onTapGesture { withAnimation { selected = nil } }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isLoading)
        .animation(.spring(duration: 0.3), value: selected == nil)
        .task { await setup() }
    }

    // MARK: - Setup

    private func setup() async {
        var rng = SeededRandom(seed: Int(Date().timeIntervalSince1970))
        stars = (0..<180).map { _ in
            StarParticle(nx: Float(rng.next()), ny: Float(rng.next()),
                         size: Float(1 + rng.next() * 2.5),
                         opacity: Float(0.2 + rng.next() * 0.7),
                         twinkleOffset: Float(rng.next() * 10))
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if status == .authorized || status == .limited {
            particles = await fetchGalleryImages(max: 40)
        }
        isLoading = false
    }

    // 在 @MainActor 上获取 PHAsset 列表（安全），然后逐张用 async 回调加载
    private func fetchGalleryImages(max maxCount: Int) async -> [GalaxyImageParticle] {
        let fetchOpts = PHFetchOptions()
        fetchOpts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOpts.fetchLimit = maxCount
        let result = PHAsset.fetchAssets(with: .image, options: fetchOpts)
        let count  = min(result.count, maxCount)

        var particles: [GalaxyImageParticle] = []
        for i in 0..<count {
            let asset = result.object(at: i)
            let cgImg = await loadCGImage(from: asset)
            particles.append(GalaxyImageParticle(id: i, image: cgImg, index: i,
                                                 seed: abs(asset.localIdentifier.hashValue)))
        }
        return particles
    }

    // 单张图片：用非阻塞回调 + withCheckedContinuation，主线程安全
    private func loadCGImage(from asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { cont in
            let reqOpts = PHImageRequestOptions()
            reqOpts.deliveryMode          = .fastFormat
            reqOpts.resizeMode            = .fast
            reqOpts.isNetworkAccessAllowed = false
            // isSynchronous = false：回调在任意线程，不阻塞主线程
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: reqOpts) { data, _, _, _ in
                var cgImage: CGImage? = nil
                if let data,
                   let src = CGImageSourceCreateWithData(data as CFData, nil) {
                    let thumbOpts: [CFString: Any] = [
                        kCGImageSourceThumbnailMaxPixelSize: 200,
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true
                    ]
                    cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
                }
                cont.resume(returning: cgImage)
            }
        }
    }

    // MARK: - Tap hit-test

    private func handleTap(at location: CGPoint) {
        guard !particles.isEmpty, canvasSize != .zero else { return }
        let time = Date().timeIntervalSinceReferenceDate
        let rX = time * 0.08 + rotX
        let rY = time * 0.12 + rotY
        var nearest: GalaxyImageParticle? = nil
        var minDist = CGFloat.greatestFiniteMagnitude
        for p in particles {
            let raw  = positionFor(p, shape: shape, total: particles.count, time: time, w: canvasSize.width, h: canvasSize.height)
            let rot  = rotate(raw, rx: rX, ry: rY)
            let proj = project(rot, w: canvasSize.width, h: canvasSize.height, zoom: zoom)
            let dist = hypot(proj.x - location.x, proj.y - location.y)
            if dist < 100 * proj.scale, dist < minDist { minDist = dist; nearest = p }
        }
        withAnimation { selected = nearest }
    }

    // MARK: - Drawing

    private func drawBackground(_ ctx: inout GraphicsContext, size: CGSize, time: Double) {
        let bg = Color(red: 0.004, green: 0.004, blue: 0.012)
        let fullRect = CGRect(origin: .zero, size: size)
        ctx.fill(Rectangle().path(in: fullRect), with: .color(bg))

        let dx = (accDrag.width  + liveDrag.width)  * 0.05
        let dy = (accDrag.height + liveDrag.height) * 0.05
        let center = CGPoint(x: size.width / 2 + dx, y: size.height / 2 + dy)
        let grad = Gradient(stops: [
            .init(color: Color(red: 0.051, green: 0.051, blue: 0.118), location: 0),
            .init(color: bg, location: 1)
        ])
        ctx.fill(Rectangle().path(in: fullRect),
                 with: .radialGradient(grad, center: center,
                                       startRadius: 0, endRadius: size.width * 1.5))

        for star in stars {
            let twinkle = Float(0.3 + 0.7 * abs(sin(Float(time) * 1.5 + star.twinkleOffset)))
            let r = CGFloat(star.size) / 2
            let cx = CGFloat(star.nx) * size.width
            let cy = CGFloat(star.ny) * size.height
            ctx.fill(Circle().path(in: CGRect(x: cx - r, y: cy - r, width: r*2, height: r*2)),
                     with: .color(.white.opacity(Double(star.opacity * twinkle))))
        }
    }

    private func drawParticles(_ ctx: inout GraphicsContext, size: CGSize, time: Double) {
        guard !particles.isEmpty else { return }
        let rX = time * 0.08 + rotX
        let rY = time * 0.12 + rotY
        let w = size.width, h = size.height
        let glow = shape.glowColor

        let sorted = particles
            .map { p -> (GalaxyImageParticle, Vec3) in
                let raw = positionFor(p, shape: shape, total: particles.count, time: time, w: w, h: h)
                return (p, rotate(raw, rx: rX, ry: rY))
            }
            .sorted { $0.1.z < $1.1.z }

        for (p, rotated) in sorted {
            let proj   = project(rotated, w: w, h: h, zoom: zoom)
            let zNorm  = CGFloat(((rotated.z + 420) / 840).clamped(to: 0...1))
            let alpha  = Double((zNorm * zNorm).clamped(to: 0.08...1))
            let baseSize: CGFloat = 48 + 42 * proj.scale
            let breathe = CGFloat(1 + 0.04 * sin(time * 2.5 + Double(p.seed % 10)))
            let pSize   = baseSize * (0.65 + 0.35 * zNorm) * breathe
            drawParticle(&ctx, p: p, cx: proj.x, cy: proj.y,
                         size: pSize, alpha: alpha, glowColor: glow, zDepth: Double(zNorm))
        }
    }

    private func drawParticle(_ ctx: inout GraphicsContext,
                              p: GalaxyImageParticle,
                              cx: CGFloat, cy: CGFloat, size: CGFloat,
                              alpha: Double, glowColor: Color, zDepth: Double) {
        let half = size / 2
        let path: Path = shape == .heart
            ? makeHeartPath(cx: cx, cy: cy, size: half)
            : Circle().path(in: CGRect(x: cx - half, y: cy - half, width: size, height: size))

        // Glow rings for close particles
        if zDepth > 0.6 {
            let focus = ((zDepth - 0.6) * 2.5).clamped(to: 0...1)
            ctx.stroke(path, with: .color(glowColor.opacity(0.4 * alpha * focus)), lineWidth: 6)
            ctx.stroke(path, with: .color(.white.opacity(0.5 * alpha * focus)), lineWidth: 1.2)
        }

        // Black base prevents ugly alpha accumulation
        ctx.fill(path, with: .color(.black.opacity(alpha)))

        // Image clipped to shape with depth-based darkening
        var clipped = ctx
        clipped.clip(to: path)
        if let cgImg = p.image {
            let resolved   = clipped.resolve(Image(cgImg, scale: 1, orientation: .up, label: Text("")))
            let brightness = (0.35 + 0.65 * zDepth).clamped(to: 0...1)
            clipped.draw(resolved, in: CGRect(x: cx - half, y: cy - half, width: size, height: size))
            clipped.fill(path, with: .color(.black.opacity(alpha * (1 - brightness))))
        } else {
            clipped.fill(path, with: .color(glowColor.opacity(0.2 * alpha)))
        }

        // Faint outer ring
        ctx.stroke(path, with: .color(.white.opacity(0.15 * alpha * zDepth)), lineWidth: 1.0)
    }
}


// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        max(range.lowerBound, min(range.upperBound, self))
    }
}
