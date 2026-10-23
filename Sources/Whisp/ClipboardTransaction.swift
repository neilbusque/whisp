import AppKit

/// A pasteboard transaction owns only the change it created. Used with a
/// unique pasteboard in tests so QA never touches the user's clipboard.
@MainActor
struct ClipboardTransaction {
    private let pasteboard: NSPasteboard
    private let snapshot: [[NSPasteboard.PasteboardType: Data]]
    private let ownChange: Int
    init(pasteboard: NSPasteboard = .general, text: String) {
        self.pasteboard = pasteboard
        snapshot = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ownChange = pasteboard.changeCount
    }
    func restoreIfUnchanged() {
        guard pasteboard.changeCount == ownChange else { return }
        pasteboard.clearContents()
        let items = snapshot.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
