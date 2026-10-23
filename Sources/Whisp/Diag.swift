import Foundation

/// Serialized, bounded diagnostics. Never log transcript text or credentials.
enum Diag {
    static let path = Paths.dir + "/whisp.log"
    private static let queue = DispatchQueue(label: "com.busqueneil.whisp.diagnostics", qos: .utility)
    static func log(_ message: String) {
        queue.async {
            let formatter = ISO8601DateFormatter()
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: path)[.size]) as? Int, size > 1_000_000 {
                try? fm.removeItem(atPath: path + ".previous")
                try? fm.moveItem(atPath: path, toPath: path + ".previous")
            }
            if fm.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
                do { try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close() }
                catch { try? handle.close() }
            } else { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
        }
    }
}
