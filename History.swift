import Foundation

/// Rolling temperature log the menu bar app writes and the CLI reads.
struct Sample: Codable {
    let t: Date
    let max: Double
    let avg: Double
}

enum History {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CPUTemp/history.json")

    static func save(_ samples: [Sample]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try? encoder.encode(samples).write(to: url, options: .atomic)
    }

    static func load() -> [Sample] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([Sample].self, from: data)) ?? []
    }
}
