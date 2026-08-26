#!/usr/bin/env swift
import AppKit
import Foundation

let pb = NSPasteboard.general
print("=== Pasteboard changeCount: \(pb.changeCount) ===")
print("Types:")
for type in pb.types ?? [] {
    print("  - \(type.rawValue)")
}
print("")

let interestingTypes: [NSPasteboard.PasteboardType] = [
    .string,
    .rtf,
    .rtfd,
    .html,
    .tiff,
    .png,
    .fileURL,
    NSPasteboard.PasteboardType("public.url"),
    NSPasteboard.PasteboardType("public.file-url"),
    NSPasteboard.PasteboardType("com.apple.webarchive"),
    NSPasteboard.PasteboardType("com.apple.flat-rtfd"),
]

for type in interestingTypes {
    if let data = pb.data(forType: type) {
        print("[\(type.rawValue)] size: \(data.count) bytes")
        if type == .string, let s = String(data: data, encoding: .utf8) {
            print("  text: \(s.prefix(500))")
        } else if type == .tiff || type == .png,
                  let img = NSImage(data: data) {
            print("  image: \(img.size.width)x\(img.size.height)")
        } else if type == .rtf || type == .rtfd,
                  let attr = NSAttributedString(rtfd: data, documentAttributes: nil)
                    ?? NSAttributedString(rtf: data, documentAttributes: nil) {
            print("  attributed length: \(attr.length)")
            print("  string preview: \(attr.string.prefix(300))")
            attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length), options: []) { value, range, _ in
                if let att = value as? NSTextAttachment,
                   let image = att.image ?? (att.fileWrapper?.regularFileContents).flatMap({ NSImage(data: $0) }) {
                    print("  attachment image: \(image.size.width)x\(image.size.height) at range \(range.location)-\(range.location+range.length)")
                }
            }
        } else if type == .html, let s = String(data: data, encoding: .utf8) {
            print("  html length: \(s.count)")
            print("  html preview: \(s.prefix(500))")
            // 找出所有 <img> 标签并报告
            let imgRegex = try? NSRegularExpression(pattern: "<img[^>]+src=\"([^\"]+)\"", options: .caseInsensitive)
            let matches = imgRegex?.matches(in: s, options: [], range: NSRange(location: 0, length: s.utf16.count)) ?? []
            print("  img count: \(matches.count)")
            for (i, match) in matches.enumerated() {
                if let range = Range(match.range(at: 1), in: s) {
                    let src = String(s[range])
                    print("  img#\(i+1) src: \(src.prefix(200))\(src.count > 200 ? "..." : "")")
                    if src.hasPrefix("data:image") {
                        print("    -> base64 embedded image")
                    } else if src.hasPrefix("http://") || src.hasPrefix("https://") {
                        print("    -> remote URL")
                    }
                }
            }
        }
    }
}
