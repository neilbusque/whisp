import CoreGraphics
import Testing
@testable import Whisp

@Suite struct SyntheticKeypressTests {
    @Test func pasteReleasesItsSyntheticCommandAndAllowsPhysicalInput() throws {
        let keypress = try #require(SyntheticKeypress(keyCode: 9, command: true, physicalFlags: []))
        #expect(keypress.down.flags == .maskCommand)
        #expect(keypress.up.flags.isEmpty)
        #expect(keypress.down.type == .keyDown)
        #expect(keypress.up.type == .keyUp)
        #expect(keypress.source.sourceStateID != .combinedSessionState)
        #expect(keypress.source.sourceStateID != .hidSystemState)
        #expect(keypress.source.localEventsSuppressionInterval == 0)
        #expect(keypress.source.getLocalEventsFilterDuringSuppressionState(
            .eventSuppressionStateSuppressionInterval) == [.permitLocalMouseEvents,
                .permitLocalKeyboardEvents, .permitSystemDefinedEvents])
        #expect(keypress.source.getLocalEventsFilterDuringSuppressionState(
            .eventSuppressionStateRemoteMouseDrag) == [.permitLocalMouseEvents,
                .permitLocalKeyboardEvents, .permitSystemDefinedEvents])
        #expect(SyntheticKeypress.isWhispEvent(keypress.down))
        #expect(SyntheticKeypress.isWhispEvent(keypress.up))
    }

    @Test func releasePreservesOnlyTheActualHardwareModifiers() throws {
        let physical: CGEventFlags = [.maskShift, .maskSecondaryFn]
        let keypress = try #require(SyntheticKeypress(keyCode: 9, command: true, physicalFlags: physical))
        #expect(keypress.down.flags == .maskCommand)
        #expect(keypress.up.flags == physical)
        #expect(!keypress.up.flags.contains(.maskCommand))
        let heldCommand = try #require(SyntheticKeypress(keyCode: 9, command: true,
            physicalFlags: .maskCommand))
        #expect(heldCommand.up.flags == .maskCommand)
    }

    @Test func deletionDoesNotIntroduceCommandAndOrdinaryEventsAreNotTagged() throws {
        let keypress = try #require(SyntheticKeypress(keyCode: 51, command: false, physicalFlags: []))
        #expect(keypress.down.flags.isEmpty)
        #expect(keypress.up.flags.isEmpty)
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true))
        #expect(!SyntheticKeypress.isWhispEvent(event))
        #expect(!SyntheticKeypress.isWhispEvent(nil))
    }
}
