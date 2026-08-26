#!/usr/bin/env swift
import AppKit
import Foundation

final class ScaledTextAttachment: NSTextAttachment {
    let maxWidth: CGFloat
    
    init(fileWrapper: FileWrapper?, maxWidth: CGFloat) {
        self.maxWidth = maxWidth
        super.init(fileWrapper: fileWrapper)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        if let image = self.image, image.size.width > 0 {
            let scale = min(1.0, maxWidth / image.size.width)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            return NSRect(origin: .zero, size: size)
        }
        return super.attachmentBounds(for: textContainer, proposedLineFragment: lineFrag, glyphPosition: position, characterIndex: charIndex)
    }
}

let html = "<p>test</p><img src='https://picsum.photos/800/600' width='800' height='600'><p>end</p>"
let data = html.data(using: .utf8)!
let attr = try! NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
let mutable = NSMutableAttributedString(attributedString: attr)
mutable.enumerateAttribute(.attachment, in: NSRange(location: 0, length: mutable.length), options: []) { value, range, _ in
    if let oldAtt = value as? NSTextAttachment {
        let newAtt = ScaledTextAttachment(fileWrapper: oldAtt.fileWrapper, maxWidth: 236)
        newAtt.fileType = oldAtt.fileType
        newAtt.image = oldAtt.image
        mutable.addAttribute(.attachment, value: newAtt, range: range)
    }
}
let rect = mutable.boundingRect(with: NSSize(width: 236, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
print("bounding rect: \(rect)")
print("attr size: \(mutable.size())")
