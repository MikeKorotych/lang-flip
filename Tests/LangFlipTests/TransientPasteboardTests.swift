import AppKit
import XCTest
@testable import LangFlip

final class TransientPasteboardTests: XCTestCase {
    func testTransientPasteRestoresPreviousClipboard() {
        let pb = NSPasteboard(name: NSPasteboard.Name("lang-flip-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("previous clipboard", forType: .string)

        let restored = expectation(description: "clipboard restored")
        TransientPasteboard.pasteString("private transcript", to: pb, restoreAfter: 0.01) {
            XCTAssertEqual(pb.string(forType: .string), "private transcript")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(pb.string(forType: .string), "previous clipboard")
            restored.fulfill()
        }
        wait(for: [restored], timeout: 1)
    }

    func testTransientPasteDoesNotClobberNewClipboardContent() {
        let pb = NSPasteboard(name: NSPasteboard.Name("lang-flip-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("previous clipboard", forType: .string)

        let checked = expectation(description: "new clipboard preserved")
        TransientPasteboard.pasteString("private transcript", to: pb, restoreAfter: 0.02) {
            pb.clearContents()
            pb.setString("new user copy", forType: .string)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            XCTAssertEqual(pb.string(forType: .string), "new user copy")
            checked.fulfill()
        }
        wait(for: [checked], timeout: 1)
    }

    func testTransientPasteRestoresWhenPasteboardWasTouchedButStillContainsTranscript() {
        let pb = NSPasteboard(name: NSPasteboard.Name("lang-flip-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("previous clipboard", forType: .string)

        let restored = expectation(description: "clipboard restored after same transcript rewrite")
        TransientPasteboard.pasteString("private transcript", to: pb, restoreAfter: 0.02) {
            pb.clearContents()
            pb.setString("private transcript", forType: .string)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            XCTAssertEqual(pb.string(forType: .string), "previous clipboard")
            restored.fulfill()
        }
        wait(for: [restored], timeout: 1)
    }

    func testTransientPasteCanRemainAsClipboardFallback() {
        let pb = NSPasteboard(name: NSPasteboard.Name("lang-flip-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("previous clipboard", forType: .string)

        let checked = expectation(description: "transient text remains")
        TransientPasteboard.pasteString(
            "private transcript",
            to: pb,
            restoreAfter: 0.01,
            restoreOriginalClipboard: false
        ) {}

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(pb.string(forType: .string), "private transcript")
            checked.fulfill()
        }
        wait(for: [checked], timeout: 1)
    }
}
