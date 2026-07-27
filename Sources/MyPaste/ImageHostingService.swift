import AppKit
import Foundation
import CryptoKit
import CommonCrypto

struct ImageHostingResult {
    let success: Bool
    let url: String?
    let markdownUrl: String?
    let error: String?

    init(success: Bool, url: String? = nil, markdownUrl: String? = nil, error: String? = nil) {
        self.success = success
        self.url = url
        self.markdownUrl = markdownUrl
        self.error = error
    }
}

@MainActor
final class ImageHostingService {
    static let shared = ImageHostingService()

    func upload(_ data: Data, fileName: String, config: ImageHostingConfig) async -> ImageHostingResult {
        let decrypted = ImageHostingCrypto.decryptedCopy(of: config)
        switch config.provider {
        case .aliyun:
            return await AliyunOSSUploader.upload(data, fileName: fileName, config: decrypted)
        case .qiniu:
            return await QiniuUploader.upload(data, fileName: fileName, config: decrypted)
        case .tencent:
            return await TencentCOSUploader.upload(data, fileName: fileName, config: decrypted)
        case .upyun:
            return await UpyunUploader.upload(data, fileName: fileName, config: decrypted)
        case .aws:
            return await AWSS3Uploader.upload(data, fileName: fileName, config: decrypted)
        case .github:
            return ImageHostingResult(success: false, error: String(format: NSLocalizedString("%@ 上传暂未实现", comment: "Provider upload not implemented"), config.provider.displayName))
        }
    }

    func uploadToDefault(data: Data, fileName: String, settings: AppSettings) async -> ImageHostingResult {
        guard settings.imageHostingEnabled else {
            return ImageHostingResult(success: false, error: NSLocalizedString("图床功能未启用", comment: "Image hosting disabled"))
        }
        let configs = settings.imageHostingConfigs.filter { $0.isEnabled }
        guard !configs.isEmpty else {
            return ImageHostingResult(success: false, error: NSLocalizedString("未配置启用的图床", comment: "No enabled image hosting configs"))
        }
        let defaultConfig: ImageHostingConfig?
        if let defaultID = settings.imageHostingDefaultID,
           let id = UUID(uuidString: defaultID),
           let config = configs.first(where: { $0.id == id }) {
            defaultConfig = config
        } else {
            defaultConfig = configs.first
        }
        guard let config = defaultConfig else {
            return ImageHostingResult(success: false, error: NSLocalizedString("未找到默认图床", comment: "Default image hosting not found"))
        }
        return await upload(data, fileName: fileName, config: config)
    }

    static func generateFileName(originalName: String, settings: AppSettings) -> String {
        let ext = (originalName as NSString).pathExtension.lowercased().nilIfEmpty ?? "png"
        guard settings.imageHostingRenameEnabled else {
            return originalName
        }
        switch settings.imageHostingRenameRule {
        case .timestamp:
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let random = String(UUID().uuidString.prefix(8))
            return "clip_\(timestamp)_\(random).\(ext)"
        case .original:
            return originalName
        case .customPrefix:
            let prefix = settings.imageHostingCustomPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            return prefix.isEmpty ? "clip_\(timestamp).\(ext)" : "\(prefix)_\(timestamp).\(ext)"
        }
    }

    static func readFileFromPasteboard() -> (data: Data, fileName: String)? {
        let pasteboard = NSPasteboard.general
        guard let urlData = pasteboard.data(forType: .fileURL),
              let url = URL(dataRepresentation: urlData, relativeTo: nil),
              let data = try? Data(contentsOf: url) else { return nil }
        return (data, url.lastPathComponent)
    }

    static func readImageFromPasteboard() -> (data: Data, fileName: String)? {
        let pasteboard = NSPasteboard.general

        // 优先读取文件 URL（如截图文件）
        if let urlData = pasteboard.data(forType: .fileURL),
           let url = URL(dataRepresentation: urlData, relativeTo: nil),
           let data = try? Data(contentsOf: url),
           data.isImageData {
            return (data, url.lastPathComponent)
        }

        // 其次读取图片数据
        if let tiffData = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiffData),
           let data = image.pngRepresentation {
            return (data, "clipboard_\(Int(Date().timeIntervalSince1970)).png")
        }

        if let data = pasteboard.data(forType: .png), data.isImageData {
            return (data, "clipboard_\(Int(Date().timeIntervalSince1970)).png")
        }

        return nil
    }
}

// MARK: - 阿里云 OSS

private enum AliyunOSSUploader {
    static func upload(_ imageData: Data, fileName: String, config: ImageHostingConfig) async -> ImageHostingResult {
        let objectKey = buildKey(fileName: fileName, prefix: config.effectivePathPrefix)
        let contentType = MIMEType.forFileName(fileName)
        let date = formattedGMTDate()
        let contentMD5 = md5(imageData).base64EncodedString()
        let canonicalizedResource = "/\(config.bucket)/\(objectKey)"
        let stringToSign = "PUT\n\(contentMD5)\n\(contentType)\n\(date)\n\(canonicalizedResource)"
        let signature = hmacSHA1(key: config.secretKey, message: stringToSign).base64EncodedString()
        let authorization = "OSS \(config.accessKey):\(signature)"
        let endpoint = endpoint(for: config)
        let url = URL(string: "https://\(endpoint)/\(objectKey)")!

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(contentMD5, forHTTPHeaderField: "Content-MD5")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(date, forHTTPHeaderField: "Date")
        request.httpBody = imageData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return ImageHostingResult(success: false, error: NSLocalizedString("无效响应", comment: "Invalid upload response"))
            }
            if (200..<300).contains(httpResponse.statusCode) {
                let accessURL = accessURL(for: config, objectKey: objectKey, defaultURL: url.absoluteString)
                return ImageHostingResult(success: true, url: accessURL, markdownUrl: "![image](\(accessURL))")
            } else {
                return ImageHostingResult(success: false, error: String(format: NSLocalizedString("上传失败 (HTTP %d)", comment: "Upload failed with HTTP status"), httpResponse.statusCode))
            }
        } catch {
            return ImageHostingResult(success: false, error: String(format: NSLocalizedString("请求失败: %@", comment: "Upload request failed"), error.localizedDescription))
        }
    }

    private static func endpoint(for config: ImageHostingConfig) -> String {
        if let endpoint = config.endpoint?.trimmingCharacters(in: .whitespaces), !endpoint.isEmpty {
            return endpoint
        }
        let region = config.region.starts(with: "oss-") ? config.region : "oss-\(config.region)"
        return "\(config.bucket).\(region).aliyuncs.com"
    }

    private static func buildKey(fileName: String, prefix: String?) -> String {
        guard let prefix = prefix?.trimmingCharacters(in: .whitespaces), !prefix.isEmpty else {
            return fileName
        }
        return "\(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(fileName)"
    }

    private static func accessURL(for config: ImageHostingConfig, objectKey: String, defaultURL: String) -> String {
        if let domain = config.customDomain?.trimmingCharacters(in: .whitespaces), !domain.isEmpty {
            return "\(domain.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(objectKey)"
        }
        return defaultURL
    }

    private static func formattedGMTDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }
}

// MARK: - 七牛云

private enum QiniuUploader {
    static func upload(_ imageData: Data, fileName: String, config: ImageHostingConfig) async -> ImageHostingResult {
        let key = buildKey(fileName: fileName, prefix: config.effectivePathPrefix)
        let uploadToken = generateUploadToken(config: config, key: key)
        let uploadURL = uploadURL(for: config)

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(formField(name: "token", value: uploadToken, boundary: boundary))
        body.append(formField(name: "key", value: key, boundary: boundary))
        body.append(fileField(name: "file", fileName: key, data: imageData, boundary: boundary))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return ImageHostingResult(success: false, error: NSLocalizedString("无效响应", comment: "Invalid upload response"))
            }
            if (200..<300).contains(httpResponse.statusCode) {
                let accessURL = downloadURL(for: config, key: key)
                return ImageHostingResult(success: true, url: accessURL, markdownUrl: "![image](\(accessURL))")
            } else {
                return ImageHostingResult(success: false, error: String(format: NSLocalizedString("上传失败 (HTTP %d)", comment: "Upload failed with HTTP status"), httpResponse.statusCode))
            }
        } catch {
            return ImageHostingResult(success: false, error: String(format: NSLocalizedString("请求失败: %@", comment: "Upload request failed"), error.localizedDescription))
        }
    }

    private static func generateUploadToken(config: ImageHostingConfig, key: String) -> String {
        let deadline = Int(Date().timeIntervalSince1970) + 3600
        let putPolicy = """
        {"scope":"\(config.bucket):\(key)","deadline":\(deadline),"returnBody":"{\\"key\\":\\"$(key)\\",\\"hash\\":\\"$(etag)\\",\\"url\\":\\"$(url)\\"}"}
        """
        let encodedPutPolicy = base64URLSafe(Data(putPolicy.utf8))
        let sign = hmacSHA1(key: config.secretKey, message: encodedPutPolicy)
        let encodedSign = base64URLSafe(sign)
        return "\(config.accessKey):\(encodedSign):\(encodedPutPolicy)"
    }

    private static func uploadURL(for config: ImageHostingConfig) -> URL {
        let urlString: String
        if let endpoint = config.endpoint?.trimmingCharacters(in: .whitespaces), !endpoint.isEmpty {
            urlString = endpoint
        } else {
            switch config.region {
            case "z0", "cn-east-1": urlString = "https://upload.qiniup.com"
            case "z1", "cn-north-1": urlString = "https://upload-z1.qiniup.com"
            case "z2", "cn-south-1": urlString = "https://upload-z2.qiniup.com"
            case "na0", "us-north-1": urlString = "https://upload-na0.qiniup.com"
            case "as0", "ap-southeast-1": urlString = "https://upload-as0.qiniup.com"
            default: urlString = "https://upload.qiniup.com"
            }
        }
        return URL(string: urlString)!
    }

    private static func downloadURL(for config: ImageHostingConfig, key: String) -> String {
        if let domain = config.customDomain?.trimmingCharacters(in: .whitespaces), !domain.isEmpty {
            return "\(domain.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(key)"
        }
        return "https://\(config.bucket)/\(key)"
    }

    private static func buildKey(fileName: String, prefix: String?) -> String {
        guard let prefix = prefix?.trimmingCharacters(in: .whitespaces), !prefix.isEmpty else {
            return fileName
        }
        return "\(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(fileName)"
    }

    private static func formField(name: String, value: String, boundary: String) -> Data {
        var data = Data()
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        data.append("\(value)\r\n".data(using: .utf8)!)
        return data
    }

    private static func fileField(name: String, fileName: String, data: Data, boundary: String) -> Data {
        var field = Data()
        field.append("--\(boundary)\r\n".data(using: .utf8)!)
        field.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        field.append("Content-Type: \(MIMEType.forFileName(fileName))\r\n\r\n".data(using: .utf8)!)
        field.append(data)
        field.append("\r\n".data(using: .utf8)!)
        return field
    }
}

// MARK: - 腾讯云 COS

private enum TencentCOSUploader {
    static func upload(_ imageData: Data, fileName: String, config: ImageHostingConfig) async -> ImageHostingResult {
        let key = buildKey(fileName: fileName, prefix: config.effectivePathPrefix)
        let contentType = MIMEType.forFileName(fileName)
        let endpoint = endpoint(for: config)
        guard let url = url(endpoint: endpoint, key: key) else {
            return ImageHostingResult(success: false, error: NSLocalizedString("无效响应", comment: "Invalid upload response"))
        }

        let request = AWSSignatureV4.signedRequest(
            method: "PUT",
            url: url,
            headers: ["Content-Type": contentType],
            payload: imageData,
            accessKey: config.accessKey,
            secretKey: config.secretKey,
            region: config.region,
            service: "cos"
        )

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return ImageHostingResult(success: false, error: NSLocalizedString("无效响应", comment: "Invalid upload response"))
            }
            if (200..<300).contains(httpResponse.statusCode) {
                let accessURL = accessURL(for: config, objectKey: key, defaultURL: url.absoluteString)
                return ImageHostingResult(success: true, url: accessURL, markdownUrl: "![image](\(accessURL))")
            } else {
                return ImageHostingResult(success: false, error: String(format: NSLocalizedString("上传失败 (HTTP %d)", comment: "Upload failed with HTTP status"), httpResponse.statusCode))
            }
        } catch {
            return ImageHostingResult(success: false, error: String(format: NSLocalizedString("请求失败: %@", comment: "Upload request failed"), error.localizedDescription))
        }
    }

    private static func endpoint(for config: ImageHostingConfig) -> String {
        if let endpoint = config.endpoint?.trimmingCharacters(in: .whitespaces), !endpoint.isEmpty {
            return endpoint
        }
        return "\(config.bucket).cos.\(config.region).myqcloud.com"
    }

    private static func url(endpoint: String, key: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint
        components.path = "/\(key)"
        return components.url
    }

    private static func buildKey(fileName: String, prefix: String?) -> String {
        guard let prefix = prefix?.trimmingCharacters(in: .whitespaces), !prefix.isEmpty else {
            return fileName
        }
        return "\(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(fileName)"
    }

    private static func accessURL(for config: ImageHostingConfig, objectKey: String, defaultURL: String) -> String {
        if let domain = config.customDomain?.trimmingCharacters(in: .whitespaces), !domain.isEmpty {
            return "\(domain.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(objectKey)"
        }
        return defaultURL
    }
}

// MARK: - AWS S3

private enum AWSS3Uploader {
    static func upload(_ imageData: Data, fileName: String, config: ImageHostingConfig) async -> ImageHostingResult {
        let key = buildKey(fileName: fileName, prefix: config.effectivePathPrefix)
        let contentType = MIMEType.forFileName(fileName)
        let endpoint = endpoint(for: config)
        guard let url = url(endpoint: endpoint, key: key) else {
            return ImageHostingResult(success: false, error: NSLocalizedString("无效响应", comment: "Invalid upload response"))
        }

        let request = AWSSignatureV4.signedRequest(
            method: "PUT",
            url: url,
            headers: ["Content-Type": contentType],
            payload: imageData,
            accessKey: config.accessKey,
            secretKey: config.secretKey,
            region: config.region,
            service: "s3"
        )

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return ImageHostingResult(success: false, error: NSLocalizedString("无效响应", comment: "Invalid upload response"))
            }
            if (200..<300).contains(httpResponse.statusCode) {
                let accessURL = accessURL(for: config, objectKey: key, defaultURL: url.absoluteString)
                return ImageHostingResult(success: true, url: accessURL, markdownUrl: "![image](\(accessURL))")
            } else {
                return ImageHostingResult(success: false, error: String(format: NSLocalizedString("上传失败 (HTTP %d)", comment: "Upload failed with HTTP status"), httpResponse.statusCode))
            }
        } catch {
            return ImageHostingResult(success: false, error: String(format: NSLocalizedString("请求失败: %@", comment: "Upload request failed"), error.localizedDescription))
        }
    }

    private static func endpoint(for config: ImageHostingConfig) -> String {
        if let endpoint = config.endpoint?.trimmingCharacters(in: .whitespaces), !endpoint.isEmpty {
            return endpoint
        }
        return "\(config.bucket).s3.\(config.region).amazonaws.com"
    }

    private static func url(endpoint: String, key: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint
        components.path = "/\(key)"
        return components.url
    }

    private static func buildKey(fileName: String, prefix: String?) -> String {
        guard let prefix = prefix?.trimmingCharacters(in: .whitespaces), !prefix.isEmpty else {
            return fileName
        }
        return "\(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(fileName)"
    }

    private static func accessURL(for config: ImageHostingConfig, objectKey: String, defaultURL: String) -> String {
        if let domain = config.customDomain?.trimmingCharacters(in: .whitespaces), !domain.isEmpty {
            return "\(domain.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(objectKey)"
        }
        return defaultURL
    }
}

// MARK: - 又拍云

private enum UpyunUploader {
    static func upload(_ imageData: Data, fileName: String, config: ImageHostingConfig) async -> ImageHostingResult {
        let key = buildKey(fileName: fileName, prefix: config.effectivePathPrefix)
        let contentType = MIMEType.forFileName(fileName)
        let contentMD5 = md5(imageData).base64EncodedString()
        let endpoint = endpoint(for: config)
        guard let url = url(endpoint: endpoint, key: key) else {
            return ImageHostingResult(success: false, error: NSLocalizedString("无效响应", comment: "Invalid upload response"))
        }

        let auth = "Basic " + Data("\(config.accessKey):\(config.secretKey)".utf8).base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(contentMD5, forHTTPHeaderField: "Content-MD5")
        request.httpBody = imageData

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return ImageHostingResult(success: false, error: NSLocalizedString("无效响应", comment: "Invalid upload response"))
            }
            if (200..<300).contains(httpResponse.statusCode) {
                let defaultURL = "https://\(config.bucket).b0.upaiyun.com/\(key)"
                let accessURL = accessURL(for: config, objectKey: key, defaultURL: defaultURL)
                return ImageHostingResult(success: true, url: accessURL, markdownUrl: "![image](\(accessURL))")
            } else {
                return ImageHostingResult(success: false, error: String(format: NSLocalizedString("上传失败 (HTTP %d)", comment: "Upload failed with HTTP status"), httpResponse.statusCode))
            }
        } catch {
            return ImageHostingResult(success: false, error: String(format: NSLocalizedString("请求失败: %@", comment: "Upload request failed"), error.localizedDescription))
        }
    }

    private static func endpoint(for config: ImageHostingConfig) -> String {
        if let endpoint = config.endpoint?.trimmingCharacters(in: .whitespaces), !endpoint.isEmpty {
            return endpoint
        }
        return "v0.api.upyun.com/\(config.bucket)"
    }

    private static func url(endpoint: String, key: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint
        components.path = "/\(key)"
        return components.url
    }

    private static func buildKey(fileName: String, prefix: String?) -> String {
        guard let prefix = prefix?.trimmingCharacters(in: .whitespaces), !prefix.isEmpty else {
            return fileName
        }
        return "\(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(fileName)"
    }

    private static func accessURL(for config: ImageHostingConfig, objectKey: String, defaultURL: String) -> String {
        if let domain = config.customDomain?.trimmingCharacters(in: .whitespaces), !domain.isEmpty {
            return "\(domain.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(objectKey)"
        }
        return defaultURL
    }
}

// MARK: - AWS Signature V4

private enum AWSSignatureV4 {
    static func signedRequest(
        method: String,
        url: URL,
        headers: [String: String],
        payload: Data,
        accessKey: String,
        secretKey: String,
        region: String,
        service: String
    ) -> URLRequest {
        let now = Date()
        let dateStamp = formatDate(now)
        let amzDate = formatDateTime(now)
        let payloadHash = hex(sha256(payload))

        var allHeaders = headers
        allHeaders["host"] = url.host?.lowercased() ?? ""
        allHeaders["x-amz-content-sha256"] = payloadHash
        allHeaders["x-amz-date"] = amzDate

        let canonicalHeaders = allHeaders
            .map { (key: $0.key.lowercased(), value: $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)\n" }
            .joined()
        let signedHeaders = allHeaders.keys.map { $0.lowercased() }.sorted().joined(separator: ";")

        let canonicalURI = url.path.isEmpty ? "/" : url.path
        let canonicalQueryString = canonicalQuery(from: url)

        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQueryString,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            hex(sha256(Data(canonicalRequest.utf8)))
        ].joined(separator: "\n")

        let signingKey = getSignatureKey(secretKey: secretKey, dateStamp: dateStamp, regionName: region, serviceName: service)
        let signature = hex(hmacSHA256(key: signingKey, message: Data(stringToSign.utf8)))
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (key, value) in allHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = payload
        return request
    }

    private static func getSignatureKey(secretKey: String, dateStamp: String, regionName: String, serviceName: String) -> Data {
        let kDate = hmacSHA256(key: Data(("AWS4" + secretKey).utf8), message: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, message: Data(regionName.utf8))
        let kService = hmacSHA256(key: kRegion, message: Data(serviceName.utf8))
        let kSigning = hmacSHA256(key: kService, message: Data("aws4_request".utf8))
        return kSigning
    }

    private static func canonicalQuery(from url: URL) -> String {
        guard let query = url.query, !query.isEmpty else { return "" }
        let pairs = query.components(separatedBy: "&")
            .compactMap { item -> (name: String, value: String)? in
                let parts = item.components(separatedBy: "=")
                let name = parts.first?.removingPercentEncoding ?? ""
                let value = parts.count > 1 ? parts.dropFirst().joined(separator: "=").removingPercentEncoding ?? "" : ""
                return (name, value)
            }
            .map { (name: percentEncode($0.name), value: percentEncode($0.value)) }
            .sorted { $0.name < $1.name }
        return pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    private static func percentEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-_.~"))) ?? string
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

// MARK: - 通用工具

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Data {
    var isImageData: Bool {
        guard count >= 8 else { return false }
        let header = prefix(8)
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        let gif: [UInt8] = [0x47, 0x49, 0x46]
        let webp: [UInt8] = [0x52, 0x49, 0x46, 0x46]
        let bmp: [UInt8] = [0x42, 0x4D]
        return Array(header).starts(with: png)
            || Array(header).starts(with: jpeg)
            || Array(header).starts(with: gif)
            || Array(header).starts(with: webp)
            || Array(header).starts(with: bmp)
    }
}

private extension Array where Element == UInt8 {
    func starts(with prefix: [UInt8]) -> Bool {
        guard count >= prefix.count else { return false }
        for i in 0..<prefix.count {
            if self[i] != prefix[i] { return false }
        }
        return true
    }
}

extension NSImage {
    var pngRepresentation: Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }
}

private enum MIMEType {
    static func forFileName(_ fileName: String) -> String {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") { return "image/jpeg" }
        if lower.hasSuffix(".png") { return "image/png" }
        if lower.hasSuffix(".gif") { return "image/gif" }
        if lower.hasSuffix(".webp") { return "image/webp" }
        if lower.hasSuffix(".bmp") { return "image/bmp" }
        if lower.hasSuffix(".svg") { return "image/svg+xml" }
        return "application/octet-stream"
    }
}

private func hmacSHA1(key: String, message: String) -> Data {
    hmacSHA1(key: Data(key.utf8), message: Data(message.utf8))
}

private func hmacSHA1(key: Data, message: Data) -> Data {
    var result = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    key.withUnsafeBytes { keyBytes in
        message.withUnsafeBytes { msgBytes in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
                   keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                   key.count,
                   msgBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                   message.count,
                   &result)
        }
    }
    return Data(result)
}

private func hmacSHA256(key: Data, message: Data) -> Data {
    var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    key.withUnsafeBytes { keyBytes in
        message.withUnsafeBytes { msgBytes in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                   keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                   key.count,
                   msgBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                   message.count,
                   &result)
        }
    }
    return Data(result)
}

private func sha256(_ data: Data) -> Data {
    var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    _ = data.withUnsafeBytes { bytes in
        CC_SHA256(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), CC_LONG(data.count), &result)
    }
    return Data(result)
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func md5(_ data: Data) -> Data {
    Data(Insecure.MD5.hash(data: data))
}

private func base64URLSafe(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .trimmingCharacters(in: CharacterSet(charactersIn: "="))
}
