#!/usr/bin/env swift
import AppKit
import Foundation

let testCases: [(name: String, html: String)] = [
    ("original width/height attrs", "<p>test</p><img src='https://picsum.photos/800/600' width='800' height='600'><p>end</p>"),
    ("css max-width", "<p>test</p><img src='https://picsum.photos/800/600' style='max-width:236px;height:auto;'><p>end</p>"),
    ("width=236 attr", "<p>test</p><img src='https://picsum.photos/800/600' width='236' height='177'><p>end</p>"),
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
    let rect = attr.boundingRect(with: NSSize(width: 236, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
    print("  bounding rect (w=236): \(rect)")
    print("  attr size: \(attr.size())")
}
