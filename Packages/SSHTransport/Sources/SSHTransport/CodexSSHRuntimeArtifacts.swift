import Foundation

struct CodexSSHRuntimeArtifactPaths: Hashable, Sendable {
    let rootDirectory: String
    let attachmentsDirectory: String
    let loopbackPIDFile: String
    let loopbackLogFile: String
}

enum CodexSSHRuntimeArtifacts {
    static func paths(for configuration: CodexSSHConfiguration?) -> CodexSSHRuntimeArtifactPaths {
        let rootDirectory: String
        if let codexHome = configuration?.codexHome {
            rootDirectory = URL(fileURLWithPath: codexHome)
                .appendingPathComponent("cotg-runtime", isDirectory: true)
                .path
        } else {
            rootDirectory = "/tmp/cotg-runtime"
        }

        return CodexSSHRuntimeArtifactPaths(
            rootDirectory: rootDirectory,
            attachmentsDirectory: rootDirectory + "/attachments",
            loopbackPIDFile: rootDirectory + "/localhost-listener.pid",
            loopbackLogFile: rootDirectory + "/localhost-listener.log"
        )
    }

    static func sanitizedAttachmentFilename(from suggestedFilename: String) -> String {
        let source = suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: source.isEmpty ? "attachment" : source)
        let stem = url.deletingPathExtension().lastPathComponent
        let sanitizedStem = stem
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = sanitizedStem.isEmpty ? "attachment" : sanitizedStem
        let ext = url.pathExtension
            .replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression)
            .lowercased()
        let suffix = UUID().uuidString.lowercased()

        if ext.isEmpty {
            return "\(base)-\(suffix)"
        }

        return "\(base)-\(suffix).\(ext)"
    }
}
