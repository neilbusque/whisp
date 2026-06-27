import Testing
@testable import WhispCore

@Suite struct ClipboardPlanTests {
    @Test func snapshotCapturesCurrentString() {
        let snap = ClipboardPlan.snapshot(currentString: "old clip")
        #expect(snap == ClipboardSnapshot(string: "old clip"))
    }

    @Test func restoreReturnsOriginalString() {
        let snap = ClipboardPlan.snapshot(currentString: "old clip")
        #expect(ClipboardPlan.restoreString(from: snap) == "old clip")
    }

    @Test func restoreOfEmptyClipboardIsNil() {
        let snap = ClipboardPlan.snapshot(currentString: nil)
        #expect(ClipboardPlan.restoreString(from: snap) == nil)
    }
}
