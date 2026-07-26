import Foundation

/// 读取 ~/.config/CloseTicketTagger/tags.json 中的归因类型配置。
struct CloseTicketTagConfig: Codable {
    let prefix: String
    let suffix: String
    let tags: [String]
}

enum CloseTicketTagger {
    static let pinboardName = "归因类型"

    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/CloseTicketTagger/tags.json", isDirectory: false)
    }

    static func loadConfig() -> CloseTicketTagConfig? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(CloseTicketTagConfig.self, from: data)
    }
}
