import CoreGraphics
import XCTest
@testable import TandemUI

final class MarkupRendererTests: XCTestCase {
    // MARK: Crop

    func testCropOutputSizeIsCropTimesImageSizeRounded() throws {
        let image = try makeImage(width: 400, height: 300) { _, _ in .white }
        let document = MarkupDocument(crop: CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.4))
        let output = try XCTUnwrap(MarkupRenderer.render(image, document: document))
        XCTAssertEqual(output.width, 200)
        XCTAssertEqual(output.height, 120)

        let thirds = MarkupDocument(crop: CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 2.0 / 3.0))
        let thirdsOutput = try XCTUnwrap(MarkupRenderer.render(image, document: thirds))
        XCTAssertEqual(thirdsOutput.width, 133)
        XCTAssertEqual(thirdsOutput.height, 200)
    }

    func testOutputIsEightBitPremultipliedSRGBAndPixelIdenticalWithoutMarkup() throws {
        let image = try makeImage(width: 64, height: 48) { x, y in
            RGB(UInt8(x * 4), UInt8(y * 5), UInt8((x * y) % 256))
        }
        let output = try XCTUnwrap(MarkupRenderer.render(image, document: MarkupDocument()))
        XCTAssertEqual(output.bitsPerComponent, 8)
        XCTAssertEqual(output.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(output.alphaInfo, .premultipliedLast)
        let source = try Bitmap(image), rendered = try Bitmap(output)
        XCTAssertEqual(source.bytes, rendered.bytes, "rendering an empty document must not shift colors")
    }

    func testCropAndAnnotationsShareImageCoordinates() throws {
        let image = try makeImage(width: 1000, height: 800) { _, _ in .white }
        let rectangle = MarkupAnnotation(
            kind: .rectangle,
            points: [CGPoint(x: 0.2, y: 0.25), CGPoint(x: 0.6, y: 0.75)],
            color: .red,
            lineWidth: .thick
        )
        // Uncropped: the left edge of the rectangle sits at x = 200 px, spanning y = 200…600.
        let full = try Bitmap(XCTUnwrap(MarkupRenderer.render(image, document: MarkupDocument(annotations: [rectangle]))))
        assertRed(full.pixel(200, 400))
        assertRed(full.pixel(600, 400))
        assertRed(full.pixel(400, 200))
        assertWhite(full.pixel(400, 400), "interior stays clear")
        assertWhite(full.pixel(100, 100), "outside stays clear")
        assertWhite(full.pixel(215, 400), "stroke is only a few pixels wide")

        // Cropped to x 100…700, y 160…640: the same edge moves to (100, 240).
        let crop = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.6)
        let croppedImage = try XCTUnwrap(MarkupRenderer.render(image, document: MarkupDocument(annotations: [rectangle], crop: crop)))
        XCTAssertEqual(croppedImage.width, 600)
        XCTAssertEqual(croppedImage.height, 480)
        let cropped = try Bitmap(croppedImage)
        assertRed(cropped.pixel(100, 240))
        assertRed(cropped.pixel(500, 240))
        assertRed(cropped.pixel(300, 40))
        assertRed(cropped.pixel(300, 440))
        assertWhite(cropped.pixel(300, 240))
        assertWhite(cropped.pixel(50, 20))
    }

    // MARK: Redaction

    func testPixelateRedactionScramblesCheckerboardAndLeavesOutsideUntouched() throws {
        let image = try makeImage(width: 600, height: 400) { x, y in ((x / 2 + y / 2) % 2 == 0) ? .black : .white }
        let redact = MarkupAnnotation(
            kind: .redact,
            points: [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.75)],
            redactStyle: .pixelate
        )
        let source = try Bitmap(image)
        let output = try Bitmap(XCTUnwrap(MarkupRenderer.render(image, document: MarkupDocument(annotations: [redact]))))
        let inside = CGRect(x: 150, y: 100, width: 300, height: 200)

        var changedInside = 0, totalInside = 0, changedOutside = 0
        var insideLuma: Set<UInt8> = []
        for y in 0..<400 {
            for x in 0..<600 {
                let differs = source.pixel(x, y) != output.pixel(x, y)
                if inside.contains(CGPoint(x: x, y: y)) {
                    totalInside += 1
                    if differs { changedInside += 1 }
                    insideLuma.insert(output.pixel(x, y).r)
                } else if differs {
                    changedOutside += 1
                }
            }
        }
        XCTAssertGreaterThan(Double(changedInside) / Double(totalInside), 0.9, "most redacted pixels must change")
        XCTAssertEqual(changedOutside, 0, "pixels outside the redaction must be untouched")
        // The checkerboard averages out to flat gray blocks: no pure black/white pattern survives.
        XCTAssertFalse(insideLuma.contains(0))
        XCTAssertFalse(insideLuma.contains(255))
    }

    func testPixelationBlockSizeScalesWithImageWidth() {
        XCTAssertEqual(MarkupRenderer.pixelationBlockSize(forImageWidth: 300), 12)
        XCTAssertEqual(MarkupRenderer.pixelationBlockSize(forImageWidth: 2880), 48)
        XCTAssertEqual(MarkupRenderer.pixelationBlockSize(forImageWidth: 5120), 85)
    }

    func testSolidRedactionIsBlack() throws {
        let image = try makeImage(width: 300, height: 200) { _, _ in .white }
        let redact = MarkupAnnotation(
            kind: .redact,
            points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)],
            redactStyle: .solid
        )
        let output = try Bitmap(XCTUnwrap(MarkupRenderer.render(image, document: MarkupDocument(annotations: [redact]))))
        XCTAssertEqual(output.pixel(30, 20), Pixel(r: 0, g: 0, b: 0, a: 255))
        XCTAssertEqual(output.pixel(100, 60), Pixel(r: 0, g: 0, b: 0, a: 255))
        XCTAssertEqual(output.pixel(149, 99), Pixel(r: 0, g: 0, b: 0, a: 255))
        assertWhite(output.pixel(151, 101))
        assertWhite(output.pixel(10, 10))
    }

    func testRedactionsPaintBeneathInk() throws {
        let image = try makeImage(width: 400, height: 400) { _, _ in .white }
        // The arrow is created first, the redaction second, yet the arrow stays visible on top.
        let arrow = MarkupAnnotation(kind: .arrow, points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)], color: .red, lineWidth: .thick)
        let redact = MarkupAnnotation(kind: .redact, points: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.7, y: 0.7)], redactStyle: .solid)
        let output = try Bitmap(XCTUnwrap(MarkupRenderer.render(image, document: MarkupDocument(annotations: [arrow, redact]))))
        assertRed(output.pixel(200, 200))
        XCTAssertEqual(output.pixel(200, 150), Pixel(r: 0, g: 0, b: 0, a: 255))
    }

    // MARK: Ink

    func testArrowDrawsShaftAndHead() throws {
        let image = try makeImage(width: 800, height: 600) { _, _ in .white }
        let arrow = MarkupAnnotation(
            kind: .arrow,
            points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)],
            color: .red,
            lineWidth: .thick
        )
        let output = try Bitmap(XCTUnwrap(MarkupRenderer.render(image, document: MarkupDocument(annotations: [arrow]))))
        for x in stride(from: 90, through: 700, by: 50) {
            assertRed(output.pixel(x, 300), "shaft at x=\(x)")
        }
        // Inside the head but beyond the shaft's half-width: only the arrowhead covers this.
        assertRed(output.pixel(708, 304), "arrowhead")
        assertRed(output.pixel(708, 296), "arrowhead")
        assertWhite(output.pixel(400, 310), "off the shaft")
        assertWhite(output.pixel(740, 300), "past the tip")
    }

    func testPenDrawsSmoothedPathThroughPoints() throws {
        let image = try makeImage(width: 600, height: 600) { _, _ in .white }
        let points = stride(from: 0.1, through: 0.9, by: 0.05).map { t in
            CGPoint(x: t, y: 0.5 + 0.2 * sin(t * .pi * 2))
        }
        let pen = MarkupAnnotation(kind: .pen, points: points, color: .blue, lineWidth: .thick)
        let output = try Bitmap(XCTUnwrap(MarkupRenderer.render(image, document: MarkupDocument(annotations: [pen]))))
        // Every sample point (and each midpoint the curve passes through) carries ink.
        let midpoints = zip(points, points.dropFirst()).map { CGPoint(x: ($0.x + $1.x) / 2, y: ($0.y + $1.y) / 2) }
        for point in points + midpoints {
            let x = Int(point.x * 600), y = Int(point.y * 600)
            XCTAssertTrue(output.hasInk(nearX: x, y: y, radius: 2), "pen ink near (\(x), \(y))")
        }
        assertWhite(output.pixel(300, 50))
        assertWhite(output.pixel(300, 550))
    }

    func testTextRendersInkInsideItsLayoutBox() throws {
        let image = try makeImage(width: 800, height: 600) { _, _ in .white }
        let text = MarkupAnnotation(kind: .text, points: [CGPoint(x: 0.1, y: 0.1)], color: .red, lineWidth: .thick, text: "Hello")
        let output = try Bitmap(XCTUnwrap(MarkupRenderer.render(image, document: MarkupDocument(annotations: [text]))))
        let frame = try XCTUnwrap(MarkupGeometry.textFrame(for: text, in: MarkupSpace(pixelSize: CGSize(width: 800, height: 600))))
        XCTAssertGreaterThan(frame.width, 20)
        var inkInside = 0
        for y in Int(frame.minY)..<Int(frame.maxY) {
            for x in Int(frame.minX)..<Int(frame.maxX) where output.pixel(x, y).isReddish {
                inkInside += 1
            }
        }
        XCTAssertGreaterThan(inkInside, 50)
        assertWhite(output.pixel(700, 500))
    }

    func testHighlightTintsBackgroundButKeepsDarkContentDark() throws {
        let image = try makeImage(width: 400, height: 200) { _, y in (90..<110).contains(y) ? .black : .white }
        let highlight = MarkupAnnotation(kind: .highlight, points: [CGPoint(x: 0.1, y: 0.25), CGPoint(x: 0.9, y: 0.75)], color: .yellow)
        let output = try Bitmap(XCTUnwrap(MarkupRenderer.render(image, document: MarkupDocument(annotations: [highlight]))))
        let background = output.pixel(200, 70)
        XCTAssertGreaterThan(background.r, 240)
        XCTAssertLessThan(background.b, 200, "white turns yellow")
        let text = output.pixel(200, 100)
        XCTAssertLessThan(max(text.r, text.g, text.b), 50, "dark content stays dark")
        assertWhite(output.pixel(200, 20))
    }

    // MARK: Geometry

    func testSpaceRoundTripsNormalizedCoordinates() {
        let space = MarkupSpace(imageRect: CGRect(x: 40, y: 30, width: 500, height: 250), imagePixelSize: CGSize(width: 2000, height: 1000))
        XCTAssertEqual(space.scale, 0.25)
        let point = CGPoint(x: 0.3, y: 0.7)
        let view = space.point(point)
        XCTAssertEqual(view.x, 190, accuracy: 1e-9)
        XCTAssertEqual(view.y, 205, accuracy: 1e-9)
        let back = space.normalized(view)
        XCTAssertEqual(back.x, point.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, point.y, accuracy: 1e-9)
    }

    func testHitTestPrefersTopmostStrokeOverRectangleInterior() {
        let space = MarkupSpace(pixelSize: CGSize(width: 1000, height: 1000))
        let box = MarkupAnnotation(kind: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)])
        let arrow = MarkupAnnotation(kind: .arrow, points: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.7, y: 0.5)])
        let cover = MarkupAnnotation(kind: .rectangle, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8)])
        let annotations = [arrow, box, cover]
        XCTAssertEqual(MarkupGeometry.hitTest(CGPoint(x: 500, y: 500), annotations: annotations, in: space), arrow.id)
        XCTAssertEqual(MarkupGeometry.hitTest(CGPoint(x: 100, y: 500), annotations: annotations, in: space), box.id)
        XCTAssertEqual(MarkupGeometry.hitTest(CGPoint(x: 500, y: 300), annotations: annotations, in: space), cover.id)
        XCTAssertNil(MarkupGeometry.hitTest(CGPoint(x: 20, y: 20), annotations: annotations, in: space))
    }

    // MARK: Codable

    func testDocumentCodableRoundTrip() throws {
        let document = MarkupDocument(
            annotations: [
                MarkupAnnotation(kind: .rectangle, points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.4)], color: .green, lineWidth: .thin),
                MarkupAnnotation(kind: .highlight, points: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.6, y: 0.55)], color: .yellow),
                MarkupAnnotation(kind: .arrow, points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)], color: .purple, lineWidth: .thick),
                MarkupAnnotation(kind: .pen, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.15, y: 0.12), CGPoint(x: 0.2, y: 0.1)], color: .blue),
                MarkupAnnotation(kind: .text, points: [CGPoint(x: 0.4, y: 0.4)], color: .white, text: "Look here ✨"),
                MarkupAnnotation(kind: .redact, points: [CGPoint(x: 0.7, y: 0.7), CGPoint(x: 0.9, y: 0.8)], color: .black, redactStyle: .solid)
            ],
            crop: CGRect(x: 0.05, y: 0.1, width: 0.8, height: 0.7)
        )
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(MarkupDocument.self, from: data)
        XCTAssertEqual(decoded, document)
        XCTAssertFalse(decoded.isEmpty)
        XCTAssertTrue(decoded.containsRedactions)
        XCTAssertTrue(MarkupDocument().isEmpty)
    }

    // MARK: Editor state

    @MainActor
    func testAddUndoRedo() {
        let state = MarkupEditorState()
        XCTAssertFalse(state.canUndo)
        let annotation = MarkupAnnotation(kind: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)])
        state.add(annotation)
        XCTAssertEqual(state.document.annotations, [annotation])
        XCTAssertTrue(state.canUndo)
        XCTAssertFalse(state.canRedo)

        state.undo()
        XCTAssertTrue(state.document.annotations.isEmpty)
        XCTAssertTrue(state.canRedo)
        state.redo()
        XCTAssertEqual(state.document.annotations, [annotation])
        XCTAssertFalse(state.canRedo)
    }

    @MainActor
    func testMoveAndDeleteAreUndoable() {
        let state = MarkupEditorState()
        let original = MarkupAnnotation(kind: .arrow, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.4, y: 0.4)])
        state.add(original)
        let moved = original.translated(dx: 0.2, dy: 0.1)
        state.update(moved)
        XCTAssertEqual(state.document.annotations.first?.points.first?.x ?? 0, 0.3, accuracy: 1e-9)

        state.selection = original.id
        XCTAssertTrue(state.deleteSelection())
        XCTAssertTrue(state.document.annotations.isEmpty)
        XCTAssertNil(state.selection)

        state.undo()
        XCTAssertEqual(state.document.annotations, [moved])
        state.undo()
        XCTAssertEqual(state.document.annotations, [original])
        state.undo()
        XCTAssertTrue(state.document.annotations.isEmpty)
        XCTAssertFalse(state.canUndo)

        state.redo()
        state.redo()
        XCTAssertEqual(state.document.annotations, [moved])
        // A new edit after undo discards the redo history.
        state.undo()
        state.update(original.translated(dx: -0.05, dy: 0))
        XCTAssertFalse(state.canRedo)
    }

    @MainActor
    func testInteractiveDragCoalescesIntoOneUndoStep() {
        let state = MarkupEditorState()
        let original = MarkupAnnotation(kind: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)])
        state.add(original)

        state.beginInteractiveChange()
        XCTAssertTrue(state.isInteracting)
        for step in 1...20 {
            state.update(original.translated(dx: CGFloat(step) * 0.01, dy: 0))
        }
        state.endInteractiveChange()
        XCTAssertFalse(state.isInteracting)
        XCTAssertEqual(state.document.annotations.first?.points.first?.x ?? 0, 0.3, accuracy: 1e-9)

        state.undo()
        XCTAssertEqual(state.document.annotations, [original], "one undo reverts the whole drag")
        state.undo()
        XCTAssertTrue(state.document.annotations.isEmpty)
        XCTAssertFalse(state.canUndo)

        // A drag that ends where it started records nothing.
        state.redo()
        state.beginInteractiveChange()
        state.update(original.translated(dx: 0.1, dy: 0))
        state.update(original)
        state.endInteractiveChange()
        state.undo()
        XCTAssertTrue(state.document.annotations.isEmpty)

        // Cancelling a drag restores the pre-drag document.
        state.redo()
        state.beginInteractiveChange()
        state.update(original.translated(dx: 0.3, dy: 0.3))
        state.cancelInteractiveChange()
        XCTAssertEqual(state.document.annotations, [original])
    }

    @MainActor
    func testCropIsUndoableAndNormalized() {
        let state = MarkupEditorState()
        state.setCrop(CGRect(x: -0.2, y: 0.1, width: 0.7, height: 0.5))
        assertRect(state.document.crop, CGRect(x: 0, y: 0.1, width: 0.5, height: 0.5))
        state.setCrop(CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertNil(state.document.crop, "a full-image crop is no crop")
        state.undo()
        assertRect(state.document.crop, CGRect(x: 0, y: 0.1, width: 0.5, height: 0.5))
        state.resetCrop()
        XCTAssertTrue(state.document.isEmpty)
        state.undo()
        XCTAssertNotNil(state.document.crop)
    }

    @MainActor
    func testTextEditingCommitsCancelsAndDiscardsEmptyText() {
        let state = MarkupEditorState()
        state.tool = .text
        state.beginTextEditing(at: CGPoint(x: 0.2, y: 0.3))
        state.textSession?.text = "  Bug here  "
        state.commitTextEditing()
        XCTAssertEqual(state.document.annotations.count, 1)
        let annotation = state.document.annotations.first
        XCTAssertEqual(annotation?.text, "Bug here")
        XCTAssertEqual(annotation?.kind, .text)

        state.beginTextEditing(at: CGPoint(x: 0.5, y: 0.5))
        state.commitTextEditing()
        XCTAssertEqual(state.document.annotations.count, 1, "empty text is discarded")

        guard let id = annotation?.id else { return XCTFail("missing text annotation") }
        state.beginTextEditing(existing: id)
        state.textSession?.text = "Changed"
        state.cancelTextEditing()
        XCTAssertEqual(state.document.annotations.first?.text, "Bug here", "cancel leaves the document alone")

        state.beginTextEditing(existing: id)
        state.textSession?.text = ""
        state.commitTextEditing()
        XCTAssertTrue(state.document.annotations.isEmpty, "clearing an existing label deletes it")
        state.undo()
        XCTAssertEqual(state.document.annotations.first?.text, "Bug here")
    }

    @MainActor
    func testColorAppliesToSelectionAndIsRememberedPerTool() {
        let state = MarkupEditorState()
        XCTAssertEqual(state.color(for: .highlight), .yellow)
        XCTAssertEqual(state.color(for: .arrow), .red)
        state.tool = .arrow
        state.applyColor(.blue)
        XCTAssertEqual(state.color, .blue)
        XCTAssertEqual(state.color(for: .highlight), .yellow)

        let rect = MarkupAnnotation(kind: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)])
        state.add(rect)
        state.tool = .select
        state.selection = rect.id
        state.applyColor(.green)
        state.applyLineWidth(.thick)
        XCTAssertEqual(state.selectedAnnotation?.color, .green)
        XCTAssertEqual(state.selectedAnnotation?.lineWidth, .thick)
        state.undo()
        XCTAssertEqual(state.selectedAnnotation?.lineWidth, .medium)
        XCTAssertEqual(state.selectedAnnotation?.color, .green)
    }

    // MARK: Helpers

    private func assertRed(_ pixel: Pixel, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(pixel.isReddish, "expected red, got \(pixel) \(message)", file: file, line: line)
    }

    private func assertWhite(_ pixel: Pixel, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pixel, .white, message, file: file, line: line)
    }

    private func assertRect(_ rect: CGRect?, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        guard let rect else { return XCTFail("expected \(expected), got nil", file: file, line: line) }
        XCTAssertEqual(rect.minX, expected.minX, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: 1e-9, file: file, line: line)
    }
}

// MARK: - Bitmap fixtures

private struct RGB {
    var r: UInt8, g: UInt8, b: UInt8
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    static let white = RGB(255, 255, 255)
    static let black = RGB(0, 0, 0)
}

private struct Pixel: Equatable, CustomStringConvertible {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    static let white = Pixel(r: 255, g: 255, b: 255, a: 255)
    var isReddish: Bool { r > 200 && g < 120 && b < 120 }
    var description: String { "rgba(\(r), \(g), \(b), \(a))" }
}

private enum FixtureError: Error { case context }

/// Reads any CGImage back as 8-bit premultiplied sRGB RGBA.
private struct Bitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw FixtureError.context }
        bytes = buffer
    }

    /// Pixel at (x, y) with a top-left origin.
    func pixel(_ x: Int, _ y: Int) -> Pixel {
        let offset = (y * width + x) * 4
        return Pixel(r: bytes[offset], g: bytes[offset + 1], b: bytes[offset + 2], a: bytes[offset + 3])
    }

    /// Whether any pixel within `radius` of (x, y) differs from white.
    func hasInk(nearX x: Int, y: Int, radius: Int) -> Bool {
        for dy in -radius...radius {
            for dx in -radius...radius {
                let px = x + dx, py = y + dy
                guard px >= 0, py >= 0, px < width, py < height else { continue }
                if pixel(px, py) != .white { return true }
            }
        }
        return false
    }
}

/// Builds an opaque sRGB image from a per-pixel color function (top-left origin).
private func makeImage(width: Int, height: Int, color: (Int, Int) -> RGB) throws -> CGImage {
    var buffer = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let value = color(x, y), offset = (y * width + x) * 4
            buffer[offset] = value.r
            buffer[offset + 1] = value.g
            buffer[offset + 2] = value.b
        }
    }
    let image: CGImage? = buffer.withUnsafeMutableBytes { raw in
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
    guard let image else { throw FixtureError.context }
    return image
}
