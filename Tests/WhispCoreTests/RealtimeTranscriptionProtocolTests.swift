import Foundation
import Testing
@testable import WhispCore

@Suite struct RealtimeTranscriptionProtocolTests {
    @Test func sessionUsesLiveModelMinimalDelayAndExplicitPushToTalk() throws {
        let data = try RealtimeTranscriptionProtocol.sessionUpdate(
            vocabulary: ["PyreOS", "pyreos", "Bad\n<keyword>\r", "  "])
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(json["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(json["type"] as? String == "session.update")
        #expect(session["type"] as? String == "transcription")
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        #expect(transcription["model"] as? String == "gpt-live-transcribe")
        #expect(transcription["delay"] as? String == "minimal")
        #expect(transcription["languages"] as? [String] == ["en"])
        #expect(transcription["language"] == nil)
        #expect(transcription["keywords"] as? [String] == ["PyreOS", "Bad keyword"])
        #expect(input["turn_detection"] is NSNull)
    }

    @Test func pcmPayloadPreservesEveryByte() throws {
        let pcm = Data([0, 0, 255, 127, 0, 128, 1, 0])
        let json = try #require(JSONSerialization.jsonObject(with: RealtimeTranscriptionProtocol.append(pcm)) as? [String: Any])
        #expect(json["type"] as? String == "input_audio_buffer.append")
        let base64 = try #require(json["audio"] as? String)
        #expect(Data(base64Encoded: base64) == pcm)
    }

    @Test func finalBeforeCommitAcknowledgementIsMatchedByItemID() throws {
        var turn = RealtimeTranscriptionProtocol.Turn()
        #expect(try turn.accept(.completed(itemID: "other", transcript: "Wrong turn")) == nil)
        #expect(try turn.accept(.completed(itemID: "ours", transcript: "Correct final")) == nil)
        #expect(try turn.accept(.committed("ours")) == "Correct final")
    }

    @Test func acknowledgementBeforeFinalNeverUsesAnotherItemOrDelta() throws {
        var turn = RealtimeTranscriptionProtocol.Turn()
        #expect(try turn.accept(.committed("ours")) == nil)
        let delta = try RealtimeTranscriptionProtocol.event(from: Data(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"ours","delta":"partial"}"#.utf8))
        #expect(try turn.accept(delta) == nil)
        #expect(try turn.accept(.completed(itemID: "other", transcript: "Wrong")) == nil)
        #expect(try turn.accept(.completed(itemID: "ours", transcript: "Final")) == "Final")
    }

    @Test func partialDeltasAccumulateExactlyButNeverCompleteTheTurn() throws {
        var turn = RealtimeTranscriptionProtocol.Turn()
        let first = try RealtimeTranscriptionProtocol.event(from: Data(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"ours","content_index":0,"delta":"I I"}"#.utf8))
        #expect(first == .delta(itemID: "ours", text: "I I"))
        #expect(try turn.accept(first) == nil)
        #expect(turn.partialTranscript == "I I")
        #expect(try turn.accept(.delta(itemID: "ours", text: " like this 👋")) == nil)
        #expect(turn.partialTranscript == "I I like this 👋")
        #expect(try turn.accept(.committed("ours")) == nil)
        // The final may revise a preview. It always remains authoritative.
        #expect(try turn.accept(.completed(itemID: "ours", transcript: "I like this.")) == "I like this.")
    }

    @Test func foreignItemsNeverConcatenateAndCommitSelectsTheMatchingPreview() throws {
        var turn = RealtimeTranscriptionProtocol.Turn()
        _ = try turn.accept(.delta(itemID: "provisional", text: "Unrelated"))
        _ = try turn.accept(.delta(itemID: "ours", text: "Hello"))
        _ = try turn.accept(.delta(itemID: "ours", text: ", world"))
        #expect(turn.partialTranscript == "Unrelated")
        #expect(try turn.accept(.committed("ours")) == nil)
        #expect(turn.partialTranscript == "Hello, world")
        _ = try turn.accept(.delta(itemID: "provisional", text: " words"))
        #expect(turn.partialTranscript == "Hello, world")
        #expect(try turn.accept(.completed(itemID: "provisional", transcript: "Wrong final")) == nil)
        #expect(try turn.accept(.completed(itemID: "ours", transcript: "Hello, world.")) == "Hello, world.")
    }

    @Test func commitBeforeDeltasOnlyExposesItsOwnPreview() throws {
        var turn = RealtimeTranscriptionProtocol.Turn()
        _ = try turn.accept(.committed("ours"))
        _ = try turn.accept(.delta(itemID: "other", text: "Wrong"))
        #expect(turn.partialTranscript == nil)
        _ = try turn.accept(.delta(itemID: "ours", text: "Right"))
        _ = try turn.accept(.delta(itemID: "ours", text: " now"))
        #expect(turn.partialTranscript == "Right now")
    }

    @Test func malformedOrDifferentContentPartPreviewsAreIgnored() throws {
        for json in [
            #"{"type":"conversation.item.input_audio_transcription.delta","delta":"missing item"}"#,
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"ours"}"#,
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"ours","delta":"wrong part","content_index":1}"#
        ] {
            #expect(try RealtimeTranscriptionProtocol.event(from: Data(json.utf8)) == .ignored)
        }
    }

    @Test func oversizedPreviewIsDiscardedWithoutLosingTheFinal() throws {
        var turn = RealtimeTranscriptionProtocol.Turn()
        _ = try turn.accept(.delta(itemID: "ours", text: "First"))
        _ = try turn.accept(.delta(itemID: "ours", text: String(repeating: "a", count: 65_536)))
        #expect(turn.partialTranscript == nil)
        _ = try turn.accept(.delta(itemID: "ours", text: "Only a suffix"))
        #expect(turn.partialTranscript == nil)
        #expect(try turn.accept(.committed("ours")) == nil)
        #expect(try turn.accept(.completed(itemID: "ours", transcript: "Complete final")) == "Complete final")
    }

    @Test func tooManyPreviewItemsStayBoundedWithoutBlockingTheFinal() throws {
        var turn = RealtimeTranscriptionProtocol.Turn()
        for index in 0..<100 {
            _ = try turn.accept(.delta(itemID: "item-\(index)", text: "Partial \(index)"))
        }
        _ = try turn.accept(.committed("item-99"))
        #expect(turn.partialTranscript == nil)
        #expect(try turn.accept(.completed(itemID: "item-99", transcript: "Authoritative final")) == "Authoritative final")
    }

    @Test func lateDeltasCannotChangeACompletedItemPreviewOrFinal() throws {
        var turn = RealtimeTranscriptionProtocol.Turn()
        _ = try turn.accept(.delta(itemID: "ours", text: "Early"))
        _ = try turn.accept(.completed(itemID: "ours", transcript: "Final"))
        _ = try turn.accept(.delta(itemID: "ours", text: " late"))
        #expect(turn.partialTranscript == "Early")
        #expect(try turn.accept(.committed("ours")) == "Final")
    }

    @Test func providerFailureAndMalformedFinalNeverProducePartialText() throws {
        let failed = try RealtimeTranscriptionProtocol.event(from: Data(#"{"type":"conversation.item.input_audio_transcription.failed","item_id":"ours","error":{"code":"invalid_api_key","message":"sensitive provider detail"}}"#.utf8))
        #expect(failed == .failed("OpenAI transcription failed (invalid_api_key)."))
        var turn = RealtimeTranscriptionProtocol.Turn()
        #expect(throws: RealtimeTranscriptionProtocol.Failure.self) { try turn.accept(failed) }
        #expect(throws: (any Error).self) {
            try RealtimeTranscriptionProtocol.event(from: Data(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"unmatched"}"#.utf8))
        }
    }

    @Test func extraCommittedTurnsFailClosed() throws {
        var turn = RealtimeTranscriptionProtocol.Turn()
        _ = try turn.accept(.committed("first"))
        #expect(throws: RealtimeTranscriptionProtocol.Failure.self) { try turn.accept(.committed("second")) }
    }
}
