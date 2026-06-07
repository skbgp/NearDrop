import Foundation

class Logger {
    static let shared = Logger()
    let fileURL = URL(fileURLWithPath: "/tmp/neardrop_debug.log")
    let handle: FileHandle?
    
    init() {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }
    
    func log(_ message: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] \(message)\n"
        if let data = line.data(using: .utf8) {
            handle?.write(data)
        }
    }
}
