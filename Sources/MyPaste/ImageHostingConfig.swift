import Foundation

private func currentDatePath(_ format: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = format
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    return formatter.string(from: Date())
}

enum ImageHostingRenameRule: String, Codable, CaseIterable, Identifiable {
    case timestamp
    case original
    case customPrefix

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .timestamp: return NSLocalizedString("时间戳", comment: "Rename rule: timestamp")
        case .original: return NSLocalizedString("原始文件名", comment: "Rename rule: original filename")
        case .customPrefix: return NSLocalizedString("自定义前缀", comment: "Rename rule: custom prefix")
        }
    }
}

enum ImageHostingPathRule: String, Codable, CaseIterable, Identifiable {
    case none
    case custom
    case dateYearMonthDay
    case dateYearMonth
    case dateYear

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return NSLocalizedString("无", comment: "Path rule: none")
        case .custom: return NSLocalizedString("指定路径", comment: "Path rule: custom")
        case .dateYearMonthDay: return NSLocalizedString("按日期（年/月/日）", comment: "Path rule: by year/month/day")
        case .dateYearMonth: return NSLocalizedString("按日期（年/月）", comment: "Path rule: by year/month")
        case .dateYear: return NSLocalizedString("按日期（年）", comment: "Path rule: by year")
        }
    }
}

enum ImageHostingProvider: String, Codable, CaseIterable, Identifiable {
    case aliyun
    case tencent
    case qiniu
    case upyun
    case aws
    case github

    var id: String { rawValue }

    /// 当前已实现上传逻辑的厂商，UI 中仅展示这些选项。
    static var implementedCases: [ImageHostingProvider] { [.aliyun, .tencent, .qiniu, .upyun, .aws] }

    var displayName: String {
        switch self {
        case .aliyun: return NSLocalizedString("阿里云 OSS", comment: "Image hosting provider: Aliyun OSS")
        case .tencent: return NSLocalizedString("腾讯云 COS", comment: "Image hosting provider: Tencent COS")
        case .qiniu: return NSLocalizedString("七牛云", comment: "Image hosting provider: Qiniu")
        case .upyun: return NSLocalizedString("又拍云", comment: "Image hosting provider: Upyun")
        case .aws: return NSLocalizedString("AWS S3", comment: "Image hosting provider: AWS S3")
        case .github: return NSLocalizedString("GitHub", comment: "Image hosting provider: GitHub")
        }
    }

    var iconName: String {
        switch self {
        case .github: return "number.circle"
        default: return "cloud"
        }
    }
}

struct ImageHostingConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var provider: ImageHostingProvider
    var accessKey: String
    var secretKey: String
    var bucket: String
    var region: String
    var customDomain: String?
    var pathRule: ImageHostingPathRule
    var pathPrefix: String?
    var endpoint: String?
    var isEnabled: Bool
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         provider: ImageHostingProvider,
         accessKey: String = "",
         secretKey: String = "",
         bucket: String = "",
         region: String = "",
         customDomain: String? = nil,
         pathRule: ImageHostingPathRule = .none,
         pathPrefix: String? = nil,
         endpoint: String? = nil,
         isEnabled: Bool = true,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.provider = provider
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.bucket = bucket
        self.region = region
        self.customDomain = customDomain
        self.pathRule = pathRule
        self.pathPrefix = pathPrefix
        self.endpoint = endpoint
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

extension ImageHostingConfig {
    /// 根据 pathRule 计算实际使用的路径前缀
    var effectivePathPrefix: String? {
        switch pathRule {
        case .none:
            return nil
        case .custom:
            return pathPrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .dateYearMonthDay:
            return currentDatePath("yyyy/MM/dd")
        case .dateYearMonth:
            return currentDatePath("yyyy/MM")
        case .dateYear:
            return currentDatePath("yyyy")
        }
    }
}
