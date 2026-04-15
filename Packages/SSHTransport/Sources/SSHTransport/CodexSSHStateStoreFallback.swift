import CodexRPC
import Foundation

enum CodexSSHStateStoreFallback {
    static func decodeThreadListPage(
        from rawJSON: String,
        limit: Int,
        offset: Int
    ) throws -> CodexThreadListPage {
        let data = Data(rawJSON.utf8)
        guard !data.isEmpty else {
            return CodexThreadListPage(threads: [], nextCursor: nil)
        }

        let rows = try JSONDecoder().decode([CodexStateStoreThreadRow].self, from: data)
        let visibleRows = Array(rows.prefix(limit))
        let nextCursor = rows.count > limit ? encodeCursor(offset + limit) : nil

        return CodexThreadListPage(
            threads: visibleRows.map { row in
                let name = compactText(row.title)
                let previewSource = row.firstUserMessage.isEmpty ? row.title : row.firstUserMessage
                return CodexThreadSummary(
                    id: row.id,
                    cwd: row.cwd,
                    preview: compactText(previewSource),
                    modelProvider: row.modelProvider,
                    name: name.isEmpty ? nil : name,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(row.createdAt)),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(row.updatedAt)),
                    status: .idle
                )
            },
            nextCursor: nextCursor
        )
    }

    static func decodeCursor(_ cursor: String?) throws -> Int {
        guard let cursor, !cursor.isEmpty else {
            return 0
        }

        guard let offset = Int(cursor.replacingOccurrences(of: "offset:", with: "")),
              offset >= 0 else {
            throw CodexSSHError.invalidRequest("Invalid state-store cursor: \(cursor)")
        }
        return offset
    }

    static func encodeCursor(_ offset: Int) -> String {
        "offset:\(offset)"
    }

    static func compactText(_ raw: String, maxLength: Int = 140) -> String {
        let firstLine = raw
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let collapsed = firstLine.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        guard collapsed.count > maxLength else {
            return collapsed
        }

        return String(collapsed.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
