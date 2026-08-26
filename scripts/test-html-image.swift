#!/usr/bin/env swift
import AppKit
import Foundation

let testCases: [(name: String, html: String)] = [
    ("original width/height attrs", "<p>test</p><img src='https://picsum.photos/800/600' width='800' height='600'><p>end</p>"),
    ("css max-width", "<p>test</p><img src='https://picsum.photos/800/600' style='max-width:100%;height:auto;'><p>end</p>"),
    ("width=100%", "<p>test</p><img src='https://picsum.photos/800/600' width='100%'><p>end</p>"),
    ("width=236 only", "<p>test</p><img src='https://picsum.photos/800/600' width='236'><p>end</p>"),
    ("no dims", "<p>test</p><img src='https://picsum.photos/800/600'><p>end</p>"),
]

let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
    .documentType: NSAttributedString.DocumentType.html,
    .characterEncoding: String.Encoding.utf8.rawValue
]

for tc in testCases {
    print("=== \(tc.name) ===")
    guard let data = tc.html.data(using: .utf8),
          let attr = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
        print("  failed to parse")
        continue
    }
    print("  attr size: \(attr.size())")
    attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length), options: []) { value, range, _ in
        if let att = value as? NSTextAttachment {
            print("  attachment bounds: \(att.bounds), image size: \(att.image?.size ?? .zero)")
        }
    }
}
