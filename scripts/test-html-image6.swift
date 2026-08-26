#!/usr/bin/env swift
import AppKit
import Foundation

let html = "<p>test</p><img src='https://picsum.photos/800/600' width='800' height='600'><p>end</p>"
let data = html.data(using: .utf8)!
let attr = try! NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
let mutable = NSMutableAttributedString(attributedString: attr)
mutable.enumerateAttribute(.attachment, in: NSRange(location: 0, length: mutable.length), options: []) { value, range, _ in
    if let att = value as? NSTextAttachment {
        print("before bounds: \(att.bounds), image: \(att.image?.size ?? .zero)")
        att.bounds = NSRect(x: 0, y: 0, width: 236, height: 177)
        print("after bounds: \(att.bounds)")
    }
}

// 创建 text view 并测量
let textView = NSTextView()
textView.textStorage?.setAttributedString(mutable)
textView.layoutManager?.ensureLayout(for: textView.textContainer!)
let usedRect = textView.layoutManager!.usedRect(for: textView.textContainer!)
print("used rect: \(usedRect)")
print("textContainer size: \(textView.textContainer?.containerSize ?? .zero)")
