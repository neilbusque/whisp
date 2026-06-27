import Foundation

/// Lightweight append-only logger to ~/.whisp/whisp.log. GUI apps don't reliably
/// surface NSLog to the console, so we keep a readable file for diagnosing the
/// launch path (permissions, tap creation, pipeline init, recording flow).
enum Diag {
    static let path = NSString(string: "~/.whisp/whisp.log").expandingTildeInPath

    static func log(_ message: String) {
        let line = "[\(stamp())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: path), let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
