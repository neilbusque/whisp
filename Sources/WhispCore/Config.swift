import Foundation

public struct WhispConfig: Codable, Equatable {
    public var deepseekKey: String
    public var hotkey: String
    public var whisperModel: String
    public var snippetsPath: String

    public init(deepseekKey: String, hotkey: String, whisperModel: String, snippetsPath: String) {
        self.deepseekKey = deepseekKey
        self.hotkey = hotkey
        self.whisperModel = whisperModel
        self.snippetsPath = snippetsPath
    }

    public static var defaults: WhispConfig {
        WhispConfig(deepseekKey: "", hotkey: "fn",
                    whisperModel: "ggml-base.en",
                    snippetsPath: NSString(string: "~/.whisp/snippets.json").expandingTildeInPath)
    }

    public static func load(from data: Data) throws -> WhispConfig {
        try JSONDecoder().decode(WhispConfig.self, from: data)
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public func validated() throws -> WhispConfig {
        if deepseekKey.isEmpty { throw WhispConfigError.missingKey("deepseekKey") }
        return self
    }
}

public enum WhispConfigError: Error, Equatable {
    case missingKey(String)
}
