import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI
import XCTest
@testable import TandemUI

@MainActor
final class SnapshotEditorTests: XCTestCase {
    /// A 2000×1000 px image shown at 0.4× with its top-left at (100, 50): 800×400 pt.
    private let space = MarkupSpace(imageRect: CGRect(x: 100, y: 50, width: 800, height: 400), imagePixelSize: CGSize(width: 2000, height: 1000))

    // MARK: Aspect fit & conversion

    func testAspectFitLetterboxesAndCenters() {
        let wide = MarkupSpace.aspectFitRect(for: CGSize(width: 2000, height: 1000), in: CGRect(x: 0, y: 0, width: 800, height: 800))
        assertRect(wide, CGRect(x: 0, y: 200, width: 800, height: 400))

        let tall = MarkupSpace.aspectFitRect(for: CGSize(width: 1000, height: 2000), in: CGRect(x: 10, y: 20, width: 600, height: 400))
        assertRect(tall, CGRect(x: 210, y: 20, width: 200, height: 400))

        let upscaled = MarkupSpace.aspectFit(imagePixelSize: CGSize(width: 100, height: 50), in: CGRect(x: 0, y: 0, width: 400, height: 400))
        assertRect(upscaled.imageRect, CGRect(x: 0, y: 100, width: 400, height: 200))
        XCTAssertEqual(upscaled.scale, 4, accuracy: 1e-12)

        let empty = MarkupSpace.aspectFitRect(for: .zero, in: CGRect(x: 0, y: 0, width: 300, height: 100))
        assertRect(empty, CGRect(x: 150, y: 50, width: 0, height: 0))
        let noRoom = MarkupSpace.aspectFit(imagePixelSize: CGSize(width: 10, height: 10), in: .zero)
        XCTAssertEqual(noRoom.normalized(CGPoint(x: 5, y: 5)), .zero, "a zero-size image rect must not divide by zero")
    }

    func testViewAndNormalizedSpaceRoundTripForA5KScreenshot() {
        let pixelSize = CGSize(width: 5120, height: 2880)
        let canvas = CGSize(width: 1200, height: 800)
        let space = SnapshotEditorLayout.space(imagePixelSize: pixelSize, canvasSize: canvas)
        let bounds = SnapshotEditorLayout.imageBounds(in: canvas)
        XCTAssertTrue(bounds.insetBy(dx: -1e-9, dy: -1e-9).contains(space.imageRect), "the image stays inside the padded area")
        XCTAssertEqual(space.imageRect.width / space.imageRect.height, 5120.0 / 2880.0, accuracy: 1e-9, "aspect ratio preserved")
        XCTAssertEqual(space.imageRect.midX, bounds.midX, accuracy: 1e-9)
        XCTAssertEqual(space.imageRect.midY, bounds.midY, accuracy: 1e-9)
        XCTAssertEqual(space.scale, space.imageRect.width / 5120, accuracy: 1e-12)

        for normalized in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0.3141, y: 0.2718), CGPoint(x: 0.999, y: 0.001)] {
            let view = space.point(normalized)
            let back = space.normalized(view)
            XCTAssertEqual(back.x, normalized.x, accuracy: 1e-12)
            XCTAssertEqual(back.y, normalized.y, accuracy: 1e-12)
        }
        XCTAssertEqual(space.point(CGPoint(x: 0.5, y: 0.5)).x, space.imageRect.midX, accuracy: 1e-9)

        // Points outside the image clamp to its edges.
        XCTAssertEqual(space.clampedNormalized(CGPoint(x: -50, y: 10_000)), CGPoint(x: 0, y: 1))
        XCTAssertEqual(space.clampedToImage(CGPoint(x: 10_000, y: -5)), CGPoint(x: space.imageRect.maxX, y: space.imageRect.minY))
    }

    func testPreviewRectsSnapToExportPixels() {
        let normalized = CGRect(x: 0.12345, y: 0.23456, width: 0.3, height: 0.2)
        // Renderer: integral pixel rect in 2000×1000 → back to view space.
        let pixels = CGRect(x: normalized.minX * 2000, y: normalized.minY * 1000, width: 600, height: 200).integral
        let expected = CGRect(x: 100 + pixels.minX * 0.4, y: 50 + pixels.minY * 0.4, width: pixels.width * 0.4, height: pixels.height * 0.4)
        assertRect(space.pixelSnappedRect(normalized), expected, accuracy: 1e-9)

        let crop = CGRect(x: 1.0 / 3.0, y: 0.1, width: 1.0 / 3.0, height: 0.5)
        let cropPixels = MarkupRenderer.pixelCropRect(for: crop, imageSize: CGSize(width: 2000, height: 1000))
        let expectedCrop = CGRect(x: 100 + cropPixels.minX * 0.4, y: 50 + cropPixels.minY * 0.4, width: cropPixels.width * 0.4, height: cropPixels.height * 0.4)
        assertRect(space.exportedCropRect(crop), expectedCrop, accuracy: 1e-9)

        let redactions = space.snappedRedactions(for: [
            MarkupAnnotation(kind: .redact, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)], redactStyle: .solid),
            MarkupAnnotation(kind: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)]),
            MarkupAnnotation(kind: .redact, points: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.4, y: 0.4)])
        ])
        XCTAssertEqual(redactions.map(\.style), [.solid, .pixelate], "only redactions, in paint order")
    }

    // MARK: Drag & crop geometry

    func testDragConstraintsStaySquareAnd45DegreesInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(MarkupDragGeometry.rectEnd(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 150, y: 40), square: false, within: bounds), CGPoint(x: 100, y: 40))
        XCTAssertEqual(MarkupDragGeometry.rectEnd(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 30), square: true, within: bounds), CGPoint(x: 50, y: 50))
        // Would leave the bounds: the square shrinks to the room available.
        XCTAssertEqual(MarkupDragGeometry.rectEnd(from: CGPoint(x: 80, y: 10), to: CGPoint(x: 90, y: 60), square: true, within: bounds), CGPoint(x: 100, y: 30))
        XCTAssertEqual(MarkupDragGeometry.rectEnd(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 20, y: 40), square: true, within: bounds), CGPoint(x: 20, y: 20))

        let snapped = MarkupDragGeometry.arrowEnd(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 38), snap: true, within: bounds)
        XCTAssertEqual(snapped.x - 10, snapped.y - 10, accuracy: 1e-9, "snapped to 45°")
        let horizontal = MarkupDragGeometry.arrowEnd(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 90, y: 55), snap: true, within: bounds)
        XCTAssertEqual(horizontal.y, 50, accuracy: 1e-9)
        let clipped = MarkupDragGeometry.arrowEnd(from: CGPoint(x: 80, y: 80), to: CGPoint(x: 140, y: 141), snap: true, within: bounds)
        XCTAssertEqual(clipped.x, 100, accuracy: 1e-9, "shortened along the snapped direction")
        XCTAssertEqual(clipped.y, 100, accuracy: 1e-9)
    }

    func testCropHandleHitTestingAndResizing() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(MarkupCropGeometry.handle(at: CGPoint(x: 103, y: 96), in: rect), .topLeft)
        XCTAssertEqual(MarkupCropGeometry.handle(at: CGPoint(x: 305, y: 205), in: rect), .bottomRight)
        XCTAssertEqual(MarkupCropGeometry.handle(at: CGPoint(x: 200, y: 104), in: rect), .top)
        XCTAssertEqual(MarkupCropGeometry.handle(at: CGPoint(x: 296, y: 150), in: rect), .right)
        XCTAssertNil(MarkupCropGeometry.handle(at: CGPoint(x: 200, y: 150), in: rect), "the interior is for moving")
        XCTAssertEqual(MarkupCropHandle.left.position(in: rect), CGPoint(x: 100, y: 150))

        let crop = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        let minSize = CGSize(width: 0.1, height: 0.1)
        assertRect(MarkupCropGeometry.resize(crop, handle: .topLeft, by: CGVector(dx: -0.5, dy: 0.1), minSize: minSize), CGRect(x: 0, y: 0.3, width: 0.7, height: 0.4))
        assertRect(MarkupCropGeometry.resize(crop, handle: .right, by: CGVector(dx: -0.9, dy: 0.3), minSize: minSize), CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.5))
        assertRect(MarkupCropGeometry.resize(crop, handle: .bottom, by: CGVector(dx: 0, dy: 0.9), minSize: minSize), CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.8))
        assertRect(MarkupCropGeometry.move(crop, by: CGVector(dx: 0.6, dy: -0.3)), CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        assertRect(MarkupCropGeometry.enforcingMinimumSize(CGRect(x: 0.98, y: 0.5, width: 0.01, height: 0.2), minSize: minSize), CGRect(x: 0.9, y: 0.5, width: 0.1, height: 0.2))
    }

    func testClampedTranslationNeverPushesContentTheWrongWay() {
        let inside = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        XCTAssertEqual(MarkupEditorState.clampedTranslation(dx: -0.5, dy: 0.9, bounds: inside), CGVector(dx: -0.1, dy: 0.7))
        // Already partly off the left edge: moving further left is blocked, not reversed.
        let overhanging = CGRect(x: -0.1, y: 0.1, width: 0.2, height: 0.2)
        XCTAssertEqual(MarkupEditorState.clampedTranslation(dx: -0.01, dy: 0, bounds: overhanging), CGVector(dx: 0, dy: 0))
        XCTAssertEqual(MarkupEditorState.clampedTranslation(dx: 0.05, dy: 0, bounds: overhanging), CGVector(dx: 0.05, dy: 0))
    }

    // MARK: Drawing

    func testRectangleDragCreatesOneUndoableAnnotation() throws {
        let model = try makeModel()
        model.state.tool = .rectangle
        drag(model, from: CGPoint(x: 200, y: 100), through: [CGPoint(x: 300, y: 150)], to: CGPoint(x: 400, y: 250), finish: false)
        XCTAssertNotNil(model.state.draft, "the in-progress shape previews live")
        XCTAssertTrue(model.state.document.annotations.isEmpty, "…but isn't in the document yet")
        model.endDrag(at: CGPoint(x: 400, y: 250), in: space)

        XCTAssertNil(model.state.draft)
        let annotation = try XCTUnwrap(model.state.document.annotations.first)
        XCTAssertEqual(annotation.kind, .rectangle)
        assertPoint(annotation.points[0], CGPoint(x: 0.125, y: 0.125))
        assertPoint(annotation.points[1], CGPoint(x: 0.375, y: 0.5))
        XCTAssertEqual(annotation.color, .red)
        model.undo()
        XCTAssertTrue(model.state.document.annotations.isEmpty)
    }

    func testDragsUnderThreePointsCreateNothing() throws {
        let model = try makeModel()
        for tool in [MarkupTool.rectangle, .arrow, .pen, .highlight, .redact] {
            model.state.tool = tool
            drag(model, from: CGPoint(x: 300, y: 200), through: [CGPoint(x: 301, y: 201)], to: CGPoint(x: 302, y: 201))
            XCTAssertNil(model.state.draft, "\(tool)")
        }
        XCTAssertTrue(model.state.document.annotations.isEmpty)
        XCTAssertFalse(model.state.canUndo)
    }

    func testShiftDragMakesSquaresOnTheImageAnd45DegreeArrows() throws {
        let model = try makeModel()
        model.state.tool = .rectangle
        drag(model, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 400, y: 150), constrain: true)
        let rect = try XCTUnwrap(model.state.document.annotations.last?.normalizedRect)
        // Square in image pixels even though the image (and normalized space) isn't square.
        XCTAssertEqual(rect.width * 2000, rect.height * 1000, accuracy: 1e-6)
        XCTAssertEqual(rect.width * 2000, 500, accuracy: 1e-6)

        model.state.tool = .arrow
        drag(model, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 300, y: 190), constrain: true)
        let arrow = try XCTUnwrap(model.state.document.annotations.last)
        let start = space.point(arrow.points[0]), end = space.point(arrow.points[1])
        XCTAssertEqual(end.x - start.x, end.y - start.y, accuracy: 1e-6)
    }

    func testPenHighlightAndRedactUseTheirStyles() async throws {
        let model = try makeModel()
        model.state.tool = .pen
        let path = (0...20).map { CGPoint(x: 200 + CGFloat($0) * 10, y: 200 + sin(CGFloat($0) / 3) * 30) }
        drag(model, from: path[0], through: Array(path.dropFirst().dropLast()), to: path[path.count - 1])
        let pen = try XCTUnwrap(model.state.document.annotations.last)
        XCTAssertEqual(pen.kind, .pen)
        XCTAssertGreaterThan(pen.points.count, 10)

        model.select(tool: .highlight)
        drag(model, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 400, y: 130))
        XCTAssertEqual(model.state.document.annotations.last?.color, .yellow)

        model.select(tool: .redact)
        XCTAssertNotEqual(model.pixelationStatus, .idle, "choosing the redact tool starts the one-time pixelation")
        model.applyRedactStyle(.solid)
        drag(model, from: CGPoint(x: 500, y: 100), to: CGPoint(x: 600, y: 200))
        let redact = try XCTUnwrap(model.state.document.annotations.last)
        XCTAssertEqual(redact.kind, .redact)
        XCTAssertEqual(redact.effectiveRedactStyle, .solid)

        await model.waitForPixelation()
        XCTAssertEqual(model.pixelationStatus, .ready)
        let preview = try XCTUnwrap(model.pixelatedPreview)
        XCTAssertEqual(preview.width, 2000)
        XCTAssertEqual(preview.height, 1000)
    }

    // MARK: Select

    func testSelectClickDragMovesAndDeleteRemoves() throws {
        let model = try makeModel()
        let box = MarkupAnnotation(kind: .rectangle, points: [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5)])
        model.state.add(box)
        model.select(tool: .select)

        // View rect of the box: x 300…500, y 150…250. Click its border and drag.
        drag(model, from: CGPoint(x: 300, y: 200), through: [CGPoint(x: 320, y: 210)], to: CGPoint(x: 340, y: 220))
        XCTAssertEqual(model.state.selection, box.id)
        let moved = try XCTUnwrap(model.state.document.annotations.first)
        assertPoint(moved.points[0], CGPoint(x: 0.3, y: 0.3))
        assertPoint(moved.points[1], CGPoint(x: 0.55, y: 0.55))

        model.undo()
        XCTAssertEqual(model.state.document.annotations, [box], "one undo reverts the whole move")
        model.redo()

        // Clicking empty canvas deselects; clicking the box again selects it.
        click(model, at: CGPoint(x: 800, y: 400))
        XCTAssertNil(model.state.selection)
        click(model, at: CGPoint(x: 340, y: 210))
        XCTAssertEqual(model.state.selection, box.id)

        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_Delete))), .handled)
        XCTAssertTrue(model.state.document.annotations.isEmpty)
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_Delete))), .ignored, "nothing left to delete")
    }

    func testSelectPicksTheTopmostAnnotation() throws {
        let model = try makeModel()
        let lower = MarkupAnnotation(kind: .rectangle, points: [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5)])
        let upper = MarkupAnnotation(kind: .rectangle, points: [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.6, y: 0.6)])
        model.state.add(lower)
        model.state.add(upper)
        model.select(tool: .select)
        click(model, at: CGPoint(x: 300, y: 200))
        XCTAssertEqual(model.state.selection, upper.id)
    }

    func testCornerHandleResizesAndArrowEndpointsMove() throws {
        let model = try makeModel()
        let box = MarkupAnnotation(kind: .highlight, points: [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5)], color: .yellow)
        let arrow = MarkupAnnotation(kind: .arrow, points: [CGPoint(x: 0.75, y: 0.25), CGPoint(x: 0.875, y: 0.5)])
        model.state.add(box)
        model.state.add(arrow)
        model.select(tool: .select)
        model.state.selection = box.id

        // Bottom-right handle sits at (500, 250); grab it 2 pt off and drag.
        drag(model, from: CGPoint(x: 502, y: 251), to: CGPoint(x: 542, y: 291))
        let resized = try XCTUnwrap(model.state.document.annotation(id: box.id))
        assertRect(resized.normalizedRect, CGRect(x: 0.25, y: 0.25, width: 0.3, height: 0.35))

        // Arrow end handle at (800, 250).
        model.state.selection = arrow.id
        drag(model, from: CGPoint(x: 800, y: 250), to: CGPoint(x: 820, y: 290))
        let reshaped = try XCTUnwrap(model.state.document.annotation(id: arrow.id))
        assertPoint(reshaped.points[0], CGPoint(x: 0.75, y: 0.25))
        assertPoint(reshaped.points[1], CGPoint(x: 0.9, y: 0.6))
    }

    // MARK: Text

    func testTextClickPlacesFieldReturnCommitsAndShortcutsAreSuppressed() throws {
        let model = try makeModel()
        model.select(tool: .text)
        click(model, at: CGPoint(x: 300, y: 200))
        let session = try XCTUnwrap(model.state.textSession, "a click places a text field")
        XCTAssertEqual(session.anchor.x, 0.25, accuracy: 1e-9)
        XCTAssertLessThan(session.anchor.y, 0.375, "the first line is centered on the click")

        let typingR = SnapshotEditorKeyEvent(keyCode: UInt16(kVK_ANSI_R), characters: "r", isTextInputActive: true)
        XCTAssertEqual(model.handleKey(typingR), .ignored, "typing must reach the field")
        XCTAssertEqual(model.state.tool, .text)
        let typingDelete = SnapshotEditorKeyEvent(keyCode: UInt16(kVK_Delete), isTextInputActive: true)
        XCTAssertEqual(model.handleKey(typingDelete), .ignored)
        let composing = SnapshotEditorKeyEvent(keyCode: UInt16(kVK_Return), isTextInputActive: true, hasMarkedText: true)
        XCTAssertEqual(model.handleKey(composing), .ignored, "Return confirms IME composition first")

        model.state.textSession?.text = "Bug here"
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_Return), isTextInputActive: true)), .handled)
        XCTAssertNil(model.state.textSession)
        let label = try XCTUnwrap(model.state.document.annotations.first)
        XCTAssertEqual(label.text, "Bug here")

        // Esc cancels a new label; an empty label is discarded.
        click(model, at: CGPoint(x: 600, y: 300))
        model.state.textSession?.text = "Nope"
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_Escape), isTextInputActive: true)), .handled)
        click(model, at: CGPoint(x: 600, y: 300))
        click(model, at: CGPoint(x: 700, y: 350))
        XCTAssertEqual(model.state.document.annotations.count, 1)

        // Clicking an existing label with the text tool edits it.
        let frame = try XCTUnwrap(MarkupGeometry.textFrame(for: label, in: space))
        click(model, at: CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertEqual(model.state.textSession?.id, label.id)
        XCTAssertEqual(model.hiddenAnnotationID, label.id, "the label hides while its field is open")
    }

    func testDoubleClickWithSelectEditsText() throws {
        let model = try makeModel()
        let label = MarkupAnnotation(kind: .text, points: [CGPoint(x: 0.25, y: 0.25)], text: "Hello")
        model.state.add(label)
        model.select(tool: .select)
        model.doubleClickInterval = 0.5
        let frame = try XCTUnwrap(MarkupGeometry.textFrame(for: label, in: space))
        let point = CGPoint(x: frame.midX, y: frame.midY)

        click(model, at: point, time: 10)
        XCTAssertEqual(model.state.selection, label.id)
        XCTAssertNil(model.state.textSession)
        click(model, at: point, time: 12)
        XCTAssertNil(model.state.textSession, "too slow for a double click")
        click(model, at: point, time: 12.3)
        XCTAssertEqual(model.state.textSession?.id, label.id)
        XCTAssertEqual(model.state.textSession?.text, "Hello")
    }

    // MARK: Crop

    func testCropHandlesMoveAndResizeWithOneUndoStepEach() throws {
        let model = try makeModel()
        model.select(tool: .crop)

        // With no crop, the handles sit on the image corners: drag top-left inward.
        drag(model, from: CGPoint(x: 100, y: 50), through: [CGPoint(x: 140, y: 70)], to: CGPoint(x: 180, y: 90))
        assertRect(model.state.document.crop, CGRect(x: 0.1, y: 0.1, width: 0.9, height: 0.9))
        XCTAssertFalse(model.isCropDragging)

        // Dragging inside moves it, clamped to the image.
        drag(model, from: CGPoint(x: 500, y: 250), to: CGPoint(x: 400, y: 250))
        assertRect(model.state.document.crop, CGRect(x: 0, y: 0.1, width: 0.9, height: 0.9))

        // Edges can't cross: a minimum size of 24 pt remains.
        drag(model, from: CGPoint(x: 820, y: 250), to: CGPoint(x: 0, y: 250))
        let squeezed = try XCTUnwrap(model.state.document.crop)
        XCTAssertEqual(squeezed.width * 800, 24, accuracy: 1e-9)

        model.undo()
        assertRect(model.state.document.crop, CGRect(x: 0, y: 0.1, width: 0.9, height: 0.9))
        model.undo()
        assertRect(model.state.document.crop, CGRect(x: 0.1, y: 0.1, width: 0.9, height: 0.9))

        // Output size follows the crop, rounded to whole pixels.
        XCTAssertEqual(model.outputPixelSize, CGSize(width: 1800, height: 900))
        model.resetCrop()
        XCTAssertNil(model.state.document.crop)
        XCTAssertEqual(model.outputPixelSize, CGSize(width: 2000, height: 1000))
    }

    func testDrawingANewCropAndCancellingADragWithEscape() throws {
        let model = try makeModel()
        model.select(tool: .crop)
        drag(model, from: CGPoint(x: 300, y: 150), through: [CGPoint(x: 400, y: 200)], to: CGPoint(x: 500, y: 250), finish: false)
        XCTAssertTrue(model.isCropDragging, "rule-of-thirds guides show while dragging")
        model.endDrag(at: CGPoint(x: 500, y: 250), in: space)
        assertRect(model.state.document.crop, CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25))

        drag(model, from: CGPoint(x: 400, y: 200), through: [CGPoint(x: 600, y: 300)], to: CGPoint(x: 600, y: 300), finish: false)
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_Escape))), .handled, "Esc cancels the drag, not the editor")
        assertRect(model.state.document.crop, CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25))
        model.updateDrag(to: CGPoint(x: 700, y: 400), in: space)
        model.endDrag(at: CGPoint(x: 700, y: 400), in: space)
        assertRect(model.state.document.crop, CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25), "a cancelled drag stays inert")
        model.undo()
        XCTAssertNil(model.state.document.crop)
    }

    // MARK: Keyboard

    func testKeyboardShortcuts() throws {
        let model = try makeModel()
        for tool in MarkupTool.allCases {
            let key = SnapshotEditorKeyEvent(keyCode: 0, characters: String(tool.shortcut))
            XCTAssertEqual(model.handleKey(key), .handled)
            XCTAssertEqual(model.state.tool, tool)
        }
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: 0, characters: "r", modifiers: .command)), .ignored, "⌘R isn't a tool shortcut")
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_Escape))), .cancel)
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_Return))), .done)
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_Return), modifiers: .command)), .done)
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_ANSI_KeypadEnter), modifiers: .command, isTextInputActive: true)), .done, "⌘↩ finishes even while typing")

        model.select(tool: .rectangle)
        drag(model, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 400, y: 250))
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_ANSI_Z), characters: "z", modifiers: .command)), .handled)
        XCTAssertTrue(model.state.document.annotations.isEmpty)
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_ANSI_Z), characters: "Z", modifiers: [.command, .shift])), .handled)
        XCTAssertEqual(model.state.document.annotations.count, 1)

        // Arrow keys nudge the selection by 1 pt (10 pt with Shift).
        model.viewSpace = space
        model.select(tool: .select)
        model.state.selection = model.state.document.annotations.first?.id
        let before = try XCTUnwrap(model.state.selectedAnnotation?.points.first)
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_RightArrow))), .handled)
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_DownArrow), modifiers: .shift)), .handled)
        let after = try XCTUnwrap(model.state.selectedAnnotation?.points.first)
        XCTAssertEqual((after.x - before.x) * 800, 1, accuracy: 1e-9)
        XCTAssertEqual((after.y - before.y) * 400, 10, accuracy: 1e-9)

        // Esc peels back one level: the selection first, then the editor.
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_Escape))), .handled)
        XCTAssertNil(model.state.selection)
        XCTAssertEqual(model.handleKey(SnapshotEditorKeyEvent(keyCode: UInt16(kVK_Escape))), .cancel)
    }

    func testKeyEventsReachTheEditorThroughItsWindow() throws {
        _ = NSApplication.shared
        let image = try makeImage(width: 400, height: 300)
        let model = SnapshotEditorModel(image: image)
        var cancelled = 0
        var delivered: CGImage?
        let editor = SnapshotEditorView(model: model) {
            cancelled += 1
        } onDone: { _, rendered in
            delivered = rendered
        }
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        defer {
            window.contentView = nil
            window.close()
        }

        send("a", keyCode: kVK_ANSI_A, to: window)
        XCTAssertEqual(model.state.tool, .arrow, "the window's key monitor routes shortcuts to the editor")

        // While a label is open, letters and Esc belong to the label, not the editor.
        model.select(tool: .text)
        model.state.beginTextEditing(at: CGPoint(x: 0.5, y: 0.5))
        send("r", keyCode: kVK_ANSI_R, to: window)
        XCTAssertEqual(model.state.tool, .text)
        send("\u{1b}", keyCode: kVK_Escape, to: window)
        XCTAssertNil(model.state.textSession)
        XCTAssertEqual(cancelled, 0)
        send("\u{1b}", keyCode: kVK_Escape, to: window)
        XCTAssertEqual(cancelled, 1)

        send("\r", keyCode: kVK_Return, modifiers: .command, to: window)
        XCTAssertTrue(delivered === image, "⌘↩ finishes; no markup passes the source through")
    }

    func testUndoWhileTypingDiscardsTheLabelAndRedoRestoresIt() {
        let state = MarkupEditorState()
        let box = MarkupAnnotation(kind: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)])
        state.add(box)
        state.tool = .text
        state.beginTextEditing(at: CGPoint(x: 0.5, y: 0.5))
        state.textSession?.text = "Typed"
        state.undo()
        XCTAssertNil(state.textSession)
        XCTAssertEqual(state.document.annotations, [box], "undo discards the open label, not the older box")
        state.redo()
        XCTAssertEqual(state.document.annotations.last?.text, "Typed")
    }

    // MARK: Export

    func testFinishRendersFullResolutionExactlyLikeTheRenderer() async throws {
        let image = try makeImage(width: 640, height: 400)
        let document = MarkupDocument(
            annotations: [
                MarkupAnnotation(kind: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.4, y: 0.5)], color: .green, lineWidth: .thick),
                MarkupAnnotation(kind: .redact, points: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.8, y: 0.9)]),
                MarkupAnnotation(kind: .text, points: [CGPoint(x: 0.2, y: 0.7)], color: .white, text: "Look")
            ],
            crop: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        )
        let model = SnapshotEditorModel(image: image, document: document)
        let result = try await finish(model)
        XCTAssertEqual(result.document, document)
        XCTAssertEqual(result.image.width, 576)
        XCTAssertEqual(result.image.height, 360)
        let expected = try XCTUnwrap(MarkupRenderer.render(image, document: document))
        XCTAssertEqual(try pixelBytes(result.image), try pixelBytes(expected))
        XCTAssertFalse(model.isExporting)
    }

    func testFinishWithoutMarkupPassesTheSourceImageThrough() async throws {
        let image = try makeImage(width: 64, height: 32)
        let model = SnapshotEditorModel(image: image)
        model.state.tool = .text
        model.state.beginTextEditing(at: CGPoint(x: 0.5, y: 0.5))
        let result = try await finish(model)
        XCTAssertTrue(result.document.isEmpty, "an empty label is discarded on Done")
        XCTAssertTrue(result.image === image)
    }

    // MARK: Hosting smoke tests

    func testEditorHostsInAWindowAndLaysOut() throws {
        _ = NSApplication.shared
        let image = try makeImage(width: 5120, height: 2880)
        let document = MarkupDocument(
            annotations: [
                MarkupAnnotation(kind: .rectangle, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.3, y: 0.3)]),
                MarkupAnnotation(kind: .highlight, points: [CGPoint(x: 0.4, y: 0.1), CGPoint(x: 0.7, y: 0.15)], color: .yellow),
                MarkupAnnotation(kind: .arrow, points: [CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.5, y: 0.5)], color: .blue),
                MarkupAnnotation(kind: .pen, points: [CGPoint(x: 0.6, y: 0.6), CGPoint(x: 0.65, y: 0.62), CGPoint(x: 0.7, y: 0.6)]),
                MarkupAnnotation(kind: .text, points: [CGPoint(x: 0.1, y: 0.5)], text: "Here"),
                MarkupAnnotation(kind: .redact, points: [CGPoint(x: 0.75, y: 0.75), CGPoint(x: 0.95, y: 0.95)])
            ],
            crop: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        )
        var events: [String] = []
        let editor = SnapshotEditorView(image: image, document: document) {
            events.append("cancel")
        } onDone: { _, _ in
            events.append("done")
        }
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(host.frame.size, CGSize(width: 1100, height: 760))
        XCTAssertGreaterThanOrEqual(host.fittingSize.width, 700, "the editor asks for room for its toolbar")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)

        window.setContentSize(NSSize(width: 820, height: 520))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(events.isEmpty, "nothing fires without user input")
        window.contentView = nil
        window.close()
    }

    func testEditorHostsWithoutAWindow() throws {
        let image = try makeImage(width: 300, height: 200)
        let host = NSHostingView(rootView: SnapshotEditorView(image: image, onCancel: {}, onDone: { _, _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(host.fittingSize.width, 700)
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, 440)
    }

    func testThumbnailBadgeHasCompactSize() {
        let host = NSHostingView(rootView: MarkupThumbnailBadge())
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        XCTAssertGreaterThan(size.width, 20)
        XCTAssertLessThan(size.width, 120)
        XCTAssertLessThan(size.height, 30)
    }

    // MARK: Helpers

    private func makeModel() throws -> SnapshotEditorModel {
        SnapshotEditorModel(image: try makeImage(width: 2000, height: 1000))
    }

    private func drag(
        _ model: SnapshotEditorModel,
        from start: CGPoint,
        through points: [CGPoint] = [],
        to end: CGPoint,
        constrain: Bool = false,
        finish: Bool = true
    ) {
        model.beginDrag(at: start, in: space, constrain: constrain)
        model.updateDrag(to: start, in: space, constrain: constrain)
        for point in points { model.updateDrag(to: point, in: space, constrain: constrain) }
        model.updateDrag(to: end, in: space, constrain: constrain)
        if finish { model.endDrag(at: end, in: space, constrain: constrain) }
    }

    private func click(_ model: SnapshotEditorModel, at point: CGPoint, time: TimeInterval? = nil) {
        if let time {
            model.beginDrag(at: point, in: space, time: time)
        } else {
            model.beginDrag(at: point, in: space)
        }
        model.updateDrag(to: point, in: space)
        model.endDrag(at: point, in: space)
    }

    private func send(_ characters: String, keyCode: Int, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: UInt16(keyCode)
        ) else { return XCTFail("couldn't synthesize key event") }
        NSApp.sendEvent(event)
    }

    private func finish(_ model: SnapshotEditorModel) async throws -> (document: MarkupDocument, image: CGImage) {
        var result: (MarkupDocument, CGImage)?
        let delivered = expectation(description: "finish delivers")
        model.finish { document, image in
            result = (document, image)
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 10)
        let (document, image) = try XCTUnwrap(result)
        return (document, image)
    }

    private func assertPoint(_ point: CGPoint, _ expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(point.x, expected.x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(point.y, expected.y, accuracy: 1e-9, file: file, line: line)
    }

    private func assertRect(_ rect: CGRect?, _ expected: CGRect, accuracy: CGFloat = 1e-9, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let rect else { return XCTFail("expected \(expected), got nil \(message)", file: file, line: line) }
        XCTAssertEqual(rect.minX, expected.minX, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: accuracy, message, file: file, line: line)
    }
}

// MARK: - Fixtures

private enum EditorFixtureError: Error { case context }

/// An opaque sRGB image with a diagonal gradient.
private func makeImage(width: Int, height: Int) throws -> CGImage {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { throw EditorFixtureError.context }
    let colors = [CGColor(srgbRed: 0.1, green: 0.2, blue: 0.5, alpha: 1), CGColor(srgbRed: 0.9, green: 0.8, blue: 0.3, alpha: 1)] as CFArray
    guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { throw EditorFixtureError.context }
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    guard let image = context.makeImage() else { throw EditorFixtureError.context }
    return image
}

/// The image's pixels as 8-bit premultiplied sRGB RGBA.
private func pixelBytes(_ image: CGImage) throws -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard drawn else { throw EditorFixtureError.context }
    return buffer
}
