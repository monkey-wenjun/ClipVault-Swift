import AppKit

/// 把 HTML 中的远程图片下载并缩放为 base64 内嵌图，使卡片/预览能离线、等比展示。
enum HTMLImageScaler {
    static let maxDisplayWidth: CGFloat = 400

    /// 异步下载 HTML 中所有远程图片，缩放到 maxDisplayWidth 后转为 base64。
    /// 下载失败或超时的图片保持原 src 不变。
    static func scaleImages(in html: String, maxWidth: CGFloat = maxDisplayWidth) async -> String {
        let imgRegex = try! NSRegularExpression(pattern: "<img\\b[^>]*>", options: .caseInsensitive)
        let srcRegex = try! NSRegularExpression(pattern: "\\bsrc=[\"']([^\"']+)[\"']", options: .caseInsensitive)
        let dimAttrRegex = try! NSRegularExpression(pattern: "\\s+(width|height)=[\"'][^\"']*[\"']", options: .caseInsensitive)
        let whInStyleRegex = try! NSRegularExpression(pattern: "\\b(width|height)\\s*:\\s*[^;]+;?\\s*", options: .caseInsensitive)
        let styleRegex = try! NSRegularExpression(pattern: "\\bstyle=[\"']([^\"']*)[\"']", options: .caseInsensitive)

        var result = ""
        var lastIndex = html.startIndex
        let matches = imgRegex.matches(in: html, options: [], range: NSRange(location: 0, length: html.utf16.count))

        await withTaskGroup(of: (Range<String.Index>, String)?.self) { group in
            for match in matches {
                let matchRange = Range(match.range, in: html)!
                let tag = String(html[matchRange])
                guard let srcMatch = srcRegex.firstMatch(in: tag, options: [],
                                                         range: NSRange(location: 0, length: tag.utf16.count)),
                      let srcRange = Range(srcMatch.range(at: 1), in: tag) else { continue }
                let src = String(tag[srcRange])
                guard src.hasPrefix("http://") || src.hasPrefix("https://") else { continue }

                group.addTask {
                    if let data = try? await downloadImage(src),
                       let scaled = scaleImage(data, maxWidth: maxWidth),
                       let base64 = scaled.base64EncodedString() {
                        let mime = mimeType(for: data)
                        return (matchRange, "data:\(mime);base64,\(base64)")
                    }
                    return nil
                }
            }

            var replacements: [Range<String.Index>: String] = [:]
            for await replacement in group {
                if let (range, base64) = replacement {
                    replacements[range] = base64
                }
            }

            // 按原 HTML 顺序替换 src，并移除原 width/height，避免 base64 缩略图被再次放大。
            for match in matches {
                let matchRange = Range(match.range, in: html)!
                result += String(html[lastIndex..<matchRange.lowerBound])
                var tag = String(html[matchRange])
                if let base64 = replacements[matchRange] {
                    if let srcMatch = srcRegex.firstMatch(in: tag, options: [],
                                                          range: NSRange(location: 0, length: tag.utf16.count)),
                       let srcRange = Range(srcMatch.range(at: 1), in: tag) {
                        tag.replaceSubrange(srcRange, with: base64)
                    }
                }
                tag = dimAttrRegex.stringByReplacingMatches(in: tag, options: [],
                                                            range: NSRange(location: 0, length: tag.utf16.count),
                                                            withTemplate: "")
                if let styleMatch = styleRegex.firstMatch(in: tag, options: [],
                                                          range: NSRange(location: 0, length: tag.utf16.count)),
                   let styleValueRange = Range(styleMatch.range(at: 1), in: tag) {
                    var style = String(tag[styleValueRange])
                    style = whInStyleRegex.stringByReplacingMatches(in: style, options: [],
                                                                    range: NSRange(location: 0, length: style.utf16.count),
                                                                    withTemplate: "")
                    tag.replaceSubrange(styleValueRange, with: style)
                }
                result += tag
                lastIndex = matchRange.upperBound
            }
        }
        result += String(html[lastIndex...])
        return result
    }

    private static func downloadImage(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let (data, response) = try await URLSession(configuration: config).data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func scaleImage(_ data: Data, maxWidth: CGFloat) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0 else { return nil }
        let scale = min(1.0, maxWidth / image.size.width)
        guard scale < 1.0 else { return data }
        let newSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(newSize.width),
                                            pixelsHigh: Int(newSize.height),
                                            bitsPerSample: 8,
                                            samplesPerPixel: 4,
                                            hasAlpha: true,
                                            isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0,
                                            bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private static func mimeType(for data: Data) -> String {
        guard let image = NSImage(data: data),
              let rep = image.representations.first else { return "image/png" }
        if rep is NSBitmapImageRep {
            // 统一用 jpeg 输出
            return "image/jpeg"
        }
        return "image/png"
    }
}

private extension Data {
    func base64EncodedString() -> String? {
        guard !isEmpty else { return nil }
        return base64EncodedString()
    }
}
