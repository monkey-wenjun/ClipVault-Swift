#!/usr/bin/env swift
import AppKit
import Foundation

let html = "<p>test</p><img src='https://picsum.photos/800/600' width='800' height='600'><p>end</p>"
let data = html.data(using: .utf8)!
let attr = try! NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
let mutable = NSMutableAttributedString(attributedString: attr)
mutable.enumerateAttribute(.attachment, in: NSRange(location: 0, length: mutable.length), options: []) { value, range, _ in
    if let att = value as? NSTextAttachment {
        print("bounds: \(att.bounds)")
        print("fileWrapper: \(String(describing: att.fileWrapper))")
        print("fileType: \(att.fileType ?? "nil")")
        print("image: \(att.image?.size ?? .zero)")
        print("attachmentCell: \(String(describing: att.attachmentCell))")
        let cellBounds = att.attachmentCell?.cellSize() ?? .zero
        print("cellSize: \(cellBounds)")
    }
}
