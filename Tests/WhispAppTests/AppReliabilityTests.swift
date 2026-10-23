import AppKit
import Foundation
import Testing
import WhispCore
@testable import Whisp

@Suite @MainActor struct AppReliabilityTests {
    @Test func rapidFnReleaseCannotLeaveRecordingStuck() {
        @MainActor final class Events { var values: [Bool] = [] }
        let events = Events()
        let monitor = HotkeyMonitor(
            onPress: { MainActor.assumeIsolated { events.values.append(true) } },
            onRelease: { MainActor.assumeIsolated { events.values.append(false) } })
        monitor.setFn(true); monitor.setFn(true)
        monitor.setFn(false); monitor.setFn(false)
        monitor.setFn(true); monitor.setFn(false)
        #expect(events.values == [true, false, true, false])
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WhispTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func correctionsPersistAcrossReopenAndSupportUndo() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = LearningModel(directory: dir)
        let rule = CorrectionRule(heard: "pyre o s", intended: "PyreOS")
        #expect(model.saveRule(rule))
        #expect(LearningModel(directory: dir).data.rules == [rule])
        model.deleteRule(rule.id)
        #expect(model.data.rules.isEmpty)
        model.undo()
        #expect(LearningModel(directory: dir).data.rules == [rule])
    }
    @Test func brokenLearningFileIsPreservedAndBlocksWrites() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("learning.json")
        let original = Data("not valid json".utf8)
        try original.write(to: file)
        let model = LearningModel(directory: dir)
        #expect(!model.isLoaded)
        #expect(!model.saveRule(.init(heard: "clod", intended: "Claude")))
        #expect(try Data(contentsOf: file) == original)
    }
    @Test func historyAudioIsOptInAndReferencesPersist() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = LearningModel(directory: dir)
        let samples = [Float](repeating: 0.1, count: 1600)
        await model.remember(.init(raw: "hello", output: "Hello."), samples: samples,
            model: "small", seconds: 1, saveAudio: false)
        let first = try #require(model.data.entries.first)
        #expect(!FileManager.default.fileExists(atPath: model.audioURL(first).path))
        await model.remember(.init(raw: "yes", output: "Yes."), samples: samples,
            model: "small", seconds: 1, saveAudio: true)
        let second = try #require(model.data.entries.first)
        #expect(FileManager.default.fileExists(atPath: model.audioURL(second).path))
        model.saveReference(id: second.id, text: "Yes")
        #expect(LearningModel(directory: dir).data.entries.first?.reference == "Yes")
    }
}
