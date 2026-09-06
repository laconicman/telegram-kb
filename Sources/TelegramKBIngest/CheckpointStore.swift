import Foundation

/// Persists per-channel crawl watermarks so an interrupted run resumes instead of restarting.
///
/// **Writes atomically — temp file, then rename.** `Scripts/resolve_urls.py` appends and flushes,
/// which is *not* atomic: a kill mid-write can leave a truncated final line. It survived two
/// session deaths by luck rather than design, and a truncated checkpoint is worse than none
/// because it reads as valid (`research/skills-landscape.md`).
///
/// `FileManager.replaceItem` performs the rename, which is atomic on the same volume — hence
/// writing the temp file into the destination's own directory rather than `/tmp`.
public struct CheckpointStore: Sendable {
    let url: URL
    public init(at url: URL) { self.url = url }

    public func load() throws -> [String: WebPreviewSource.Watermark] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: WebPreviewSource.Watermark].self, from: data)
    }

    public func save(_ marks: [String: WebPreviewSource.Watermark]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(marks)

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Same directory as the destination, so the replace is a rename rather than a copy.
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }

    public func update(_ mark: WebPreviewSource.Watermark) throws {
        var marks = try load()
        marks[mark.channelUsername] = mark
        try save(marks)
    }
}
