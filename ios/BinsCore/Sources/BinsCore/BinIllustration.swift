import SwiftUI

/// Original vector drawings of Bromley's household containers: green food
/// caddy, green mixed-recycling box, black paper box, black refuse sack and
/// black garden-waste wheelie bin with a brown lid. Drawn on a 100×100 grid and
/// scaled to fit, so they stay crisp from widget size up.
struct BinIllustration: View {
    let type: BinCollectionType
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Black containers would vanish against dark backgrounds, so outline
        // them faintly in dark mode.
        let outline: GraphicsContext.Shading? = colorScheme == .dark ? .color(.white.opacity(0.35)) : nil
        return Canvas { context, size in
            let scale = min(size.width, size.height) / 100
            context.translateBy(x: (size.width - 100 * scale) / 2, y: (size.height - 100 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            switch type {
            case .food: Self.drawCaddy(in: &context)
            case .recycling: Self.drawBox(in: &context, palette: .greenBox, outline: nil, contents: Self.drawBottles)
            case .paper: Self.drawBox(in: &context, palette: .blackBox, outline: outline, contents: Self.drawPaper)
            case .refuse: Self.drawSack(in: &context, outline: outline)
            case .garden: Self.drawWheelieBin(in: &context, outline: outline)
            case .other: break
            }
        }
    }

    // MARK: - Palette

    private struct BoxPalette {
        let rim: Color
        let body: Color
        let shade: Color
        let highlight: Color
        let clips: Color

        static let greenBox = BoxPalette(
            rim: Color(hex: 0x14B07A),
            body: Color(hex: 0x069B6B),
            shade: Color(hex: 0x0A6A2F),
            highlight: Color(hex: 0x17BE84),
            clips: Color(hex: 0x0E8A58)
        )
        static let blackBox = BoxPalette(
            rim: Color(hex: 0x2B2B2B),
            body: Color(hex: 0x3A3A3A),
            shade: Color(hex: 0x2A2A2A),
            highlight: Color(hex: 0x444444),
            clips: Color(hex: 0x9A9A9A)
        )
    }

    // MARK: - Shared pieces

    private static func recycleSymbol(in context: inout GraphicsContext, center: CGPoint, size: CGFloat) {
        var symbol = context.resolve(Image(systemName: "arrow.3.trianglepath"))
        symbol.shading = .color(.white)
        let natural = symbol.size
        let ratio = size / max(natural.width, natural.height)
        let drawSize = CGSize(width: natural.width * ratio, height: natural.height * ratio)
        context.draw(symbol, in: CGRect(
            x: center.x - drawSize.width / 2,
            y: center.y - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        ))
    }

    /// A tapered container body: wide at `top`, narrower at `bottom`.
    private static func taperedBody(top: CGFloat, bottom: CGFloat, topLeft: CGFloat, topRight: CGFloat, inset: CGFloat, radius: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: topLeft, y: top))
            path.addLine(to: CGPoint(x: topRight, y: top))
            path.addLine(to: CGPoint(x: topRight - inset, y: bottom - radius))
            path.addQuadCurve(to: CGPoint(x: topRight - inset - radius, y: bottom), control: CGPoint(x: topRight - inset, y: bottom))
            path.addLine(to: CGPoint(x: topLeft + inset + radius, y: bottom))
            path.addQuadCurve(to: CGPoint(x: topLeft + inset, y: bottom - radius), control: CGPoint(x: topLeft + inset, y: bottom))
            path.closeSubpath()
        }
    }

    // MARK: - Food caddy

    private static func drawCaddy(in context: inout GraphicsContext) {
        let handle = Color(hex: 0x5F6266)
        // Handle folded down against the sides.
        for mirror in [false, true] {
            var path = Path()
            path.move(to: CGPoint(x: 25, y: 31))
            path.addLine(to: CGPoint(x: 16, y: 36))
            path.addLine(to: CGPoint(x: 16, y: 56))
            path.addLine(to: CGPoint(x: 25, y: 64))
            if mirror {
                path = path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 100, ty: 0))
            }
            context.stroke(path, with: .color(handle), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            let lug = CGRect(x: mirror ? 75 : 20, y: 30, width: 5, height: 9)
            context.fill(Path(roundedRect: lug, cornerRadius: 1.5), with: .color(handle))
        }

        let body = taperedBody(top: 26, bottom: 92, topLeft: 22, topRight: 78, inset: 5, radius: 5)
        context.fill(body, with: .color(Color(hex: 0x0C9A6C)))
        // Darker right-hand face.
        var shade = context
        shade.clip(to: body)
        shade.fill(Path(CGRect(x: 62, y: 20, width: 20, height: 80)), with: .color(Color(hex: 0x078A52)))
        shade.fill(Path(CGRect(x: 22, y: 20, width: 12, height: 80)), with: .color(Color(hex: 0x15A67A)))

        // Lid with a lip.
        context.fill(Path(roundedRect: CGRect(x: 18, y: 18, width: 64, height: 9), cornerRadius: 2), with: .color(Color(hex: 0x10A172)))
        context.fill(Path(CGRect(x: 22, y: 27, width: 56, height: 3)), with: .color(Color(hex: 0x087A4C)))
        for x in [34.0, 50, 66] {
            context.fill(Path(CGRect(x: x - 1, y: 27, width: 2, height: 8)), with: .color(Color(hex: 0x0B8A5B)))
        }

        recycleSymbol(in: &context, center: CGPoint(x: 50, y: 62), size: 28)
    }

    // MARK: - Boxes

    private static func drawBox(
        in context: inout GraphicsContext,
        palette: BoxPalette,
        outline: GraphicsContext.Shading?,
        contents: (inout GraphicsContext) -> Void
    ) {
        contents(&context)

        let body = taperedBody(top: 48, bottom: 92, topLeft: 10, topRight: 90, inset: 5, radius: 5)
        context.fill(body, with: .color(palette.body))
        var faces = context
        faces.clip(to: body)
        faces.fill(Path(CGRect(x: 72, y: 44, width: 22, height: 52)), with: .color(palette.shade))
        faces.fill(Path(CGRect(x: 8, y: 44, width: 14, height: 52)), with: .color(palette.highlight))

        let rim = Path(roundedRect: CGRect(x: 6, y: 42, width: 88, height: 8), cornerRadius: 1.5)
        if let outline {
            context.stroke(body, with: outline, lineWidth: 2)
            context.stroke(rim, with: outline, lineWidth: 2)
        }
        context.fill(rim, with: .color(palette.rim))
        context.fill(Path(CGRect(x: 10, y: 50, width: 80, height: 2)), with: .color(palette.shade.opacity(0.8)))
        for x in [24.0, 50, 76] {
            context.fill(Path(CGRect(x: x - 1, y: 49, width: 2, height: 9)), with: .color(palette.clips))
        }

        recycleSymbol(in: &context, center: CGPoint(x: 50, y: 71), size: 22)
    }

    private static func drawBottles(in context: inout GraphicsContext) {
        func item(_ rect: CGRect, _ color: UInt32, radius: CGFloat = 3, rotation: Double = 0) {
            var ctx = context
            let center = CGPoint(x: rect.midX, y: rect.midY)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: .degrees(rotation))
            ctx.fill(
                Path(roundedRect: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height), cornerRadius: radius),
                with: .color(Color(hex: color))
            )
        }
        // Blue bottle, leaning.
        item(CGRect(x: 14, y: 22, width: 10, height: 26), 0x4A90D9, radius: 3, rotation: -14)
        item(CGRect(x: 13, y: 16, width: 5, height: 8), 0x3A78BF, radius: 1.5, rotation: -14)
        // Aerosol can.
        item(CGRect(x: 27, y: 20, width: 12, height: 26), 0xA9B1BA, radius: 2)
        item(CGRect(x: 29, y: 15, width: 8, height: 6), 0xCBD1D7, radius: 2)
        // Tub.
        item(CGRect(x: 32, y: 30, width: 16, height: 16), 0xD9DEE3, radius: 3, rotation: 8)
        // Washing-up liquid with a pink cap.
        item(CGRect(x: 48, y: 22, width: 13, height: 24), 0x3D3B78, radius: 3)
        item(CGRect(x: 51, y: 14, width: 7, height: 9), 0xE8527A, radius: 2)
        // Milk bottles.
        item(CGRect(x: 60, y: 26, width: 13, height: 20), 0xC6E0F4, radius: 4, rotation: 10)
        item(CGRect(x: 72, y: 24, width: 16, height: 22), 0xDCEBF7, radius: 5, rotation: 4)
        item(CGRect(x: 83, y: 20, width: 5, height: 6), 0x2E6FB7, radius: 1.5, rotation: 4)
    }

    private static func drawPaper(in context: inout GraphicsContext) {
        func item(_ rect: CGRect, _ color: UInt32, radius: CGFloat = 1.5, rotation: Double = 0) {
            var ctx = context
            let center = CGPoint(x: rect.midX, y: rect.midY)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: .degrees(rotation))
            ctx.fill(
                Path(roundedRect: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height), cornerRadius: radius),
                with: .color(Color(hex: color))
            )
        }
        // Crumpled paper.
        context.fill(Path(ellipseIn: CGRect(x: 10, y: 33, width: 22, height: 14)), with: .color(Color(hex: 0xEEF1F4)))
        context.fill(Path(ellipseIn: CGRect(x: 16, y: 30, width: 12, height: 10)), with: .color(Color(hex: 0xE2E6EA)))
        // Cardboard.
        item(CGRect(x: 28, y: 26, width: 30, height: 20), 0xE9C39A, rotation: -12)
        item(CGRect(x: 44, y: 22, width: 16, height: 8), 0xD9A877, rotation: -20)
        // Newspaper.
        item(CGRect(x: 44, y: 32, width: 26, height: 14), 0xDADDE1, rotation: 6)
        context.fill(Path(CGRect(x: 48, y: 37, width: 16, height: 1.5)), with: .color(Color(hex: 0xB5BAC0)))
        // Egg box.
        item(CGRect(x: 62, y: 38, width: 18, height: 9), 0xC9DE9C, radius: 3)
        // Juice carton.
        item(CGRect(x: 72, y: 24, width: 14, height: 22), 0x7DB6E8, rotation: 12)
        item(CGRect(x: 73, y: 20, width: 12, height: 6), 0x9CCBF0, rotation: 12)
    }

    // MARK: - Refuse sack

    private static func drawSack(in context: inout GraphicsContext, outline: GraphicsContext.Shading?) {
        let bag = Color(hex: 0x333333)
        var body = Path()
        body.move(to: CGPoint(x: 42, y: 22))
        body.addLine(to: CGPoint(x: 58, y: 22))
        body.addQuadCurve(to: CGPoint(x: 76, y: 42), control: CGPoint(x: 62, y: 30))
        body.addQuadCurve(to: CGPoint(x: 80, y: 90), control: CGPoint(x: 84, y: 66))
        body.addLine(to: CGPoint(x: 66, y: 92))
        body.addLine(to: CGPoint(x: 58, y: 88))
        body.addLine(to: CGPoint(x: 50, y: 93))
        body.addLine(to: CGPoint(x: 20, y: 90))
        body.addQuadCurve(to: CGPoint(x: 24, y: 42), control: CGPoint(x: 16, y: 66))
        body.addQuadCurve(to: CGPoint(x: 42, y: 22), control: CGPoint(x: 38, y: 30))
        body.closeSubpath()
        context.fill(body, with: .color(bag))

        // Tied top.
        var knot = Path()
        knot.move(to: CGPoint(x: 42, y: 22))
        knot.addLine(to: CGPoint(x: 36, y: 12))
        knot.addLine(to: CGPoint(x: 46, y: 15))
        knot.addLine(to: CGPoint(x: 50, y: 8))
        knot.addLine(to: CGPoint(x: 55, y: 15))
        knot.addLine(to: CGPoint(x: 64, y: 11))
        knot.addLine(to: CGPoint(x: 58, y: 22))
        knot.closeSubpath()
        if let outline {
            context.stroke(body, with: outline, lineWidth: 2)
            context.stroke(knot, with: outline, lineWidth: 2)
        }
        context.fill(knot, with: .color(Color(hex: 0x2A2A2A)))

        // Creases and sheen.
        let sheen = Color(hex: 0x5A5A5A)
        var crease1 = Path()
        crease1.move(to: CGPoint(x: 26, y: 58))
        crease1.addLine(to: CGPoint(x: 38, y: 64))
        crease1.addLine(to: CGPoint(x: 30, y: 66))
        crease1.closeSubpath()
        context.fill(crease1, with: .color(sheen))
        var crease2 = Path()
        crease2.move(to: CGPoint(x: 74, y: 60))
        crease2.addLine(to: CGPoint(x: 66, y: 74))
        crease2.addLine(to: CGPoint(x: 72, y: 72))
        crease2.closeSubpath()
        context.fill(crease2, with: .color(sheen))
        var shoulder = Path()
        shoulder.move(to: CGPoint(x: 44, y: 26))
        shoulder.addQuadCurve(to: CGPoint(x: 30, y: 40), control: CGPoint(x: 34, y: 30))
        context.stroke(shoulder, with: .color(sheen), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    // MARK: - Garden wheelie bin

    private static func drawWheelieBin(in context: inout GraphicsContext, outline: GraphicsContext.Shading?) {
        let body = taperedBody(top: 24, bottom: 90, topLeft: 24, topRight: 76, inset: 4, radius: 3)
        if let outline {
            context.stroke(body, with: outline, lineWidth: 2)
        }
        context.fill(body, with: .color(Color(hex: 0x363636)))
        var faces = context
        faces.clip(to: body)
        faces.fill(Path(CGRect(x: 62, y: 20, width: 18, height: 74)), with: .color(Color(hex: 0x262626)))
        faces.fill(Path(CGRect(x: 24, y: 20, width: 9, height: 74)), with: .color(Color(hex: 0x444444)))

        // Brown lid and handle.
        context.fill(Path(roundedRect: CGRect(x: 20, y: 15, width: 60, height: 10), cornerRadius: 2.5), with: .color(Color(hex: 0x7B4A28)))
        context.fill(Path(CGRect(x: 22, y: 24, width: 56, height: 2)), with: .color(Color(hex: 0x5C3519)))
        context.fill(Path(roundedRect: CGRect(x: 36, y: 10, width: 28, height: 5), cornerRadius: 2), with: .color(Color(hex: 0x2A2A2A)))

        // Wheels.
        for x in [30.0, 70] {
            context.fill(Path(ellipseIn: CGRect(x: x - 6, y: 84, width: 12, height: 12)), with: .color(Color(hex: 0x1E1E1E)))
            context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: 87.5, width: 5, height: 5)), with: .color(Color(hex: 0x7A7A7A)))
        }

        recycleSymbol(in: &context, center: CGPoint(x: 50, y: 55), size: 24)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

#Preview {
    HStack(spacing: 16) {
        ForEach(BinCollectionType.allCases, id: \.self) { type in
            BinBadge(type, size: 80)
        }
    }
    .padding()
}
