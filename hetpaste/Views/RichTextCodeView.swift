import SwiftUI
import AppKit
struct RichTextCodeView: View {
    let item: ClipboardItem
    let lineLimit: Int?
    var fontSize: CGFloat = 10
    /// The card preview has a light surface, so its fallback must be dark.
    var textColor: NSColor = NSColor(calibratedWhite: 0.22, alpha: 1)
    @State private var attributedText: AttributedString? = nil
    var body: some View {
        Group {
            if let attributedText = attributedText {
                Text(attributedText)
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
            } else {
                Text(item.contentText ?? "")
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(Color(nsColor: textColor))
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
            }
        }
        .task(id: item.updatedAt) {
            let currentItem = item
            let size = fontSize
            let textCol = textColor
            
            let newAttr = await Task.detached(priority: .userInitiated) {
                var nsAttr: NSAttributedString? = nil
                if let rtfd = currentItem.rtfdData {
                    nsAttr = try? NSAttributedString(data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
                } else if let rtf = currentItem.rtfData {
                    nsAttr = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                } else if let html = currentItem.htmlData {
                    nsAttr = try? NSAttributedString(data: html, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
                }

                // Plain-text code has no source presentation to preserve, so
                // give it a small, readable syntax-highlighted fallback.
                if nsAttr == nil, let language = currentItem.detectedLanguage {
                    nsAttr = await MainActor.run {
                        CodeSyntaxHighlighter.highlightedText(
                            currentItem.contentText ?? "",
                            language: language,
                            fontSize: size,
                            fallbackColor: textCol
                        )
                    }
                }
                
                guard let validNSAttr = nsAttr else { return nil as AttributedString? }
                
                let hasPortableRichText = currentItem.rtfData != nil || currentItem.htmlData != nil || currentItem.rtfdData != nil
                if currentItem.contentType == .richText || hasPortableRichText {
                    // RTF, HTML and RTFD are portable authored formatting,
                    // including syntax colours and code-block backgrounds.
                    // Render them without changing any source attributes.
                    return try? AttributedString(validNSAttr, including: \.appKit)
                }
                
                // For copied code, normalize fonts to a readable system default
                let mutableAttr = NSMutableAttributedString(attributedString: validNSAttr)
                let fullRange = NSRange(location: 0, length: mutableAttr.length)
                
                mutableAttr.enumerateAttribute(.font, in: fullRange, options: []) { font, range, _ in
                    let oldFont = font as? NSFont
                    let traits = oldFont?.fontDescriptor.symbolicTraits ?? []
                    let weight: NSFont.Weight = traits.contains(.bold) ? .semibold : .regular
                    var normalized = NSFont.systemFont(ofSize: size, weight: weight)
                    if traits.contains(.italic) {
                        let italicDescriptor = normalized.fontDescriptor.withSymbolicTraits(.italic)
                        normalized = NSFont(descriptor: italicDescriptor, size: size) ?? normalized
                    }
                    mutableAttr.addAttribute(.font, value: normalized, range: range)
                }
                mutableAttr.removeAttribute(.backgroundColor, range: fullRange)
                
                mutableAttr.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { color, range, _ in
                    guard let color = color as? NSColor else { return }
                    mutableAttr.addAttribute(.foregroundColor, value: Self.readableCodeColor(color, fallback: textCol), range: range)
                }
                
                return try? AttributedString(mutableAttr, including: \.appKit)
            }.value
            
            self.attributedText = newAttr
        }
    }

    private static func readableCodeColor(_ color: NSColor, fallback: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        guard 1.05 / (luminance + 0.05) < 3 else { return rgb }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

        if saturation < 0.12 { return fallback }
        return NSColor(
            calibratedHue: hue,
            saturation: max(saturation, 0.45),
            brightness: min(brightness, 0.58),
            alpha: max(rgb.alphaComponent, 0.88)
        )
    }


}
