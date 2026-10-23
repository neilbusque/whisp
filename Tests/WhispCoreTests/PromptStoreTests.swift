import Testing
import Foundation
@testable import WhispCore

@Suite struct PromptStoreTests {
    func makeStore() -> PromptStore {
        PromptStore(prompts: [
            PracticePrompt(title: "Why hire you", text: "Answer in 90 seconds."),
            PracticePrompt(title: "Pitch an idea", text: "Pitch the offer."),
        ])
    }

    @Test func roundTripsThroughJSON() throws {
        let store = makeStore()
        let decoded = try PromptStore.load(from: store.encoded())
        #expect(decoded.all.count == 2)
        #expect(decoded.all[0].title == "Why hire you")
    }

    @Test func upsertAddsThenUpdatesInPlace() {
        let store = makeStore()
        var p = PracticePrompt(title: "Cold open", text: "30 seconds.")
        store.upsert(p)
        #expect(store.all.count == 3)

        p.title = "Cold open v2"
        store.upsert(p)
        #expect(store.all.count == 3)
        #expect(store.prompt(id: p.id)?.title == "Cold open v2")
    }

    @Test func deleteRemovesOnlyTheTarget() {
        let store = makeStore()
        let target = store.all[0].id
        store.delete(id: target)
        #expect(store.all.count == 1)
        #expect(store.prompt(id: target) == nil)
    }

    @Test func deletingAnUnknownIDIsANoOp() {
        let store = makeStore()
        store.delete(id: UUID())
        #expect(store.all.count == 2)
    }

    @Test func seedIsNonEmptyAndUnique() {
        let ids = Set(PromptStore.seed.map(\.id))
        #expect(!PromptStore.seed.isEmpty)
        #expect(ids.count == PromptStore.seed.count)
    }
}
