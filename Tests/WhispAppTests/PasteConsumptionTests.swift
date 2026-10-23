import Foundation
import Testing
import WhispCore
@testable import Whisp

@Suite @MainActor struct PasteConsumptionTests {
    @Test func acknowledgementRequiresEntireDocumentAndUTF16Caret() throws {
        let expected = try #require(PasteConsumption.ExpectedChange(
            text: "👋 hello", replacing: .init(location: 7, length: 3), in: "Before old after"))
        #expect(expected.matches(value: "Before 👋 hello after", selection: .init(location: 15, length: 0)))
        #expect(!expected.matches(value: "Before 👋 hello after", selection: .init(location: 14, length: 0)))
        #expect(!expected.matches(value: "Before 👋 hello after", selection: .init(location: 7, length: 8)))
        #expect(!expected.matches(value: "Before 👋 hello changed", selection: .init(location: 15, length: 0)))
        #expect(!expected.matches(value: "Before old after", selection: .init(location: 10, length: 0)))
    }

    @Test func deletionRequiresCollapsedCaretAtDeletedRange() throws {
        let expected = try #require(PasteConsumption.ExpectedChange(
            text: "", replacing: .init(location: 5, length: 7), in: "Keep remove ending"))
        #expect(expected.matches(value: "Keep ending", selection: .init(location: 5, length: 0)))
        #expect(!expected.matches(value: "Keep ending", selection: .init(location: 12, length: 0)))
    }

    @Test func verifiedConsumptionEndsBeforeFallback() async {
        var elapsed: TimeInterval = 0
        var pauses: [TimeInterval] = []
        let verified = await PasteConsumption.wait(
            verify: { elapsed >= 0.03 },
            now: { elapsed },
            pause: { delay in pauses.append(delay); elapsed += delay })
        #expect(verified)
        #expect(pauses.count == 2)
        #expect(elapsed == 0.03)
    }

    @Test func unverifiedOrChangedDocumentKeepsFullConsumptionWindow() async {
        var elapsed: TimeInterval = 0
        var checks = 0
        var pauses: [TimeInterval] = []
        let verified = await PasteConsumption.wait(
            verify: { checks += 1; return false },
            now: { elapsed },
            pause: { delay in pauses.append(delay); elapsed += delay })
        #expect(!verified)
        #expect(elapsed == 0.35)
        #expect(checks > 1)
        #expect(pauses.allSatisfy { $0 > 0 && $0 <= 0.015 })
    }

    @Test func unsupportedFieldUsesOneFullFallbackPause() async {
        var pauses: [TimeInterval] = []
        let verified = await PasteConsumption.wait(verify: nil, pause: { pauses.append($0) })
        #expect(!verified)
        #expect(pauses == [0.35])
    }

    @Test func cancellationCannotSkipInsertionVerificationWindow() async {
        let task = Task { @MainActor in
            let start = ProcessInfo.processInfo.systemUptime
            let verified = await PasteConsumption.wait(verify: nil, timeout: 0.03)
            return (verified, ProcessInfo.processInfo.systemUptime - start)
        }
        task.cancel()
        let (verified, elapsed) = await task.value
        #expect(!verified)
        #expect(elapsed >= 0.025)
    }
}
