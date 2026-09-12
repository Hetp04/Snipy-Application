import SwiftUI
import AppKit
import LinkPresentation
import UniformTypeIdentifiers
struct ClipboardItemRow: View {
    private let collapsedCardHeight: CGFloat = 204
    let item: ClipboardItem
    var isSelected: Bool = false
    var isMostRecent: Bool = false
    var stripMode: Bool = false
    var onToggleFavorite: () -> Void = {}
    var onRetrySync: () -> Void = {}
    var onCopy: () -> Void = {}
    var onDelete: () -> Void = {}   
    var onTrash: () -> Void = {}    
    var isTrashMode: Bool = false
    var isExpanded: Bool = false
    var onRestore: () -> Void = {}
    var onPermanentDelete: () -> Void = {}
    var onExpand: () -> Void = {}
    var onPrimaryTap: (() -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    var isAssetLoading: Bool = false
    var assetLoadError: String? = nil
    var onRetryAssetDownload: () -> Void = {}
    /// Opens the OCR live-text viewer. If nil falls back to QuickLook.
    var onOpenOCRViewer: (() -> Void)? = nil
    var onSaveContent: ((UUID, String?, Data?, Data?, Data?) -> Void)? = nil
    @State private var isHovered: Bool = false
    @State private var isCopyHovered: Bool = false
    @State private var isStarHovered: Bool = false
    @State private var isTrashHovered: Bool = false
    @State private var isExpandedTextPresented: Bool = false
    private var headerIcon: NSImage? {
        if let bid = item.sourceAppBundleID, !bid.isEmpty {
            if let img = IconCache.shared.cachedAppIcon(bundleID: bid) {
                return img
            }
            return IconCache.shared.resolveAppIcon(bundleID: bid)
        }
        return nil
    }
    @ViewBuilder
    private var appBadge: some View {
        SoftNeumorphicIconCompact(
            image: headerIcon,
            fallbackSystemName: appIconName,
            fallbackColor: appIconColor,
            size: 20
        )
    }
    private var appIconName: String {
        switch item.sourceAppName.lowercased() {
        case "terminal": return "terminal"
        case "safari": return "safari"
        case "slack": return "number.square"
        case "xcode": return "hammer"
        case "tableplus": return "cylinder.split.1x2"
        case "figma": return "paintbrush.pointed"
        case "chrome": return "globe"
        case "notes": return "note.text"
        case "screenshot": return "camera"
        case "design spec.pdf": return "doc.text"
        case "image": return "photo"
        default: return "app.fill"
        }
    }
    private var appIconColor: Color {
        switch item.sourceAppName.lowercased() {
        case "terminal": return Color(hex: "#1A1A1A")
        case "safari": return Color(hex: "#006CFF")
        case "slack": return Color(hex: "#E01E5A")
        case "xcode": return Color(hex: "#147EFB")
        case "tableplus": return Color(hex: "#F5A623")
        case "figma": return Color(hex: "#A259FF")
        case "chrome": return Color(hex: "#4285F4")
        case "notes": return Color(hex: "#FFCC02")
        case "screenshot": return Color(hex: "#6C7A89")
        case "design spec.pdf": return Color(hex: "#D32F2F")
        case "image": return Color(hex: "#05C46B")
        default: return Theme.textSecondary
        }
    }
    private var isCodeContent: Bool {
        return item.detectedLanguage != nil
    }
    private var resolvedFileURL: URL? {
        item.revealableFileURL
    }
    private func quickViewFile() {
        guard let url = resolvedFileURL else { return }
        QuickLookPreviewer.shared.preview(url: url)
    }
    private func quickViewImage() {
        guard let data = item.localData else { return }
        QuickLookPreviewer.shared.previewImage(data: data, fileName: item.fileName)
    }
    /// Opens the OCR viewer if wired, otherwise falls back to QuickLook.
    private func openOCRViewer() {
        if let onOpenOCRViewer {
            onOpenOCRViewer()
        } else {
            quickViewImage()
        }
    }
    private func openFileInDefaultApp() {
        FileAccessStore.shared.openFile(for: item.id, fallback: item.originalFileURL)
    }
    private func revealFileInFinder() {
        FileAccessStore.shared.revealInFinder(for: item.id, fallback: item.originalFileURL)
    }
    private func defaultFileExtension() -> String {
        if let lang = item.detectedLanguage?.lowercased() {
            switch lang {
            case "swift": return "swift"
            case "python", "py": return "py"
            case "javascript", "js": return "js"
            case "typescript", "ts": return "ts"
            case "json": return "json"
            case "html": return "html"
            case "css": return "css"
            case "sql": return "sql"
            case "shell", "bash", "zsh", "sh": return "sh"
            case "rust", "rs": return "rs"
            case "go", "golang": return "go"
            case "c++", "cpp": return "cpp"
            case "c": return "c"
            case "java": return "java"
            case "ruby", "rb": return "rb"
            case "php": return "php"
            case "kotlin", "kt": return "kt"
            case "markdown", "md": return "md"
            default: break
            }
        }
        if item.contentType == .richText, item.rtfData != nil {
            return "rtf"
        }
        return "txt"
    }
    private func saveItemToDisk() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = true
        
        let dateSuffix: String = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HHmmss"
            return formatter.string(from: item.createdAt)
        }()
        
        switch item.contentType {
        case .image:
            panel.title = "Save Image As…"
            panel.prompt = "Save"
            let base = item.fileName?.components(separatedBy: ".").first ?? "Image_\(dateSuffix)"
            panel.nameFieldStringValue = "\(base).png"
            panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
            
            panel.begin { response in
                guard response == .OK, let targetURL = panel.url else { return }
                if let data = item.localData {
                    try? data.write(to: targetURL, options: .atomic)
                } else if let text = item.contentText, let data = Data(base64Encoded: text) {
                    try? data.write(to: targetURL, options: .atomic)
                }
            }
            
        case .file:
            panel.title = "Save File As…"
            panel.prompt = "Save"
            let defaultName = item.fileName ?? item.originalFileURL?.lastPathComponent ?? "File_\(dateSuffix)"
            panel.nameFieldStringValue = defaultName
            
            panel.begin { response in
                guard response == .OK, let targetURL = panel.url else { return }
                if let sourceURL = resolvedFileURL ?? item.originalFileURL {
                    try? FileManager.default.copyItem(at: sourceURL, to: targetURL)
                } else if let data = item.localData {
                    try? data.write(to: targetURL, options: .atomic)
                }
            }
            
        case .url:
            panel.title = "Save Internet Shortcut As…"
            panel.prompt = "Save"
            let host = item.contentText.flatMap { URL(string: $0)?.host }?.replacingOccurrences(of: "www.", with: "") ?? "Link"
            panel.nameFieldStringValue = "\(item.fileName ?? host).webloc"
            panel.allowedContentTypes = [UTType(filenameExtension: "webloc") ?? .data]
            
            panel.begin { response in
                guard response == .OK, let targetURL = panel.url, let urlString = item.contentText else { return }
                let plist: [String: Any] = ["URL": urlString]
                if let plistData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                    try? plistData.write(to: targetURL, options: .atomic)
                }
            }
            
        case .text, .richText:
            let ext = defaultFileExtension()
            panel.title = "Save Snippet As…"
            panel.prompt = "Save"
            let name = item.fileName ?? "snippet_\(dateSuffix).\(ext)"
            panel.nameFieldStringValue = name
            
            panel.begin { response in
                guard response == .OK, let targetURL = panel.url else { return }
                if ext == "rtf", let rtf = item.rtfData {
                    try? rtf.write(to: targetURL, options: .atomic)
                } else if let text = item.contentText, let data = text.data(using: .utf8) {
                    try? data.write(to: targetURL, options: .atomic)
                }
            }
            
        case .video:
            panel.title = "Save Video As…"
            panel.prompt = "Save"
            panel.nameFieldStringValue = item.fileName ?? "Video_\(dateSuffix).mov"
            panel.begin { response in
                guard response == .OK, let targetURL = panel.url else { return }
                if let data = item.localData {
                    try? data.write(to: targetURL, options: .atomic)
                } else if let sourceURL = resolvedFileURL ?? item.originalFileURL {
                    try? FileManager.default.copyItem(at: sourceURL, to: targetURL)
                }
            }
        }
    }
    @ViewBuilder
    private var fileActionsContextMenu: some View {
        Button(action: onCopy) {
            Label("Copy", systemImage: "doc.on.doc")
        }
        
        Button(action: onToggleFavorite) {
            Label(item.isPinned ? "Unfavorite" : "Favorite", systemImage: item.isPinned ? "star.fill" : "star")
        }
        
        Divider()
        
        if resolvedFileURL != nil {
            Button(action: openFileInDefaultApp) {
                Label("Open in Default App", systemImage: "arrow.up.forward.app")
            }
            Button(action: quickViewFile) {
                Label("Quick Look", systemImage: "eye")
            }
            Button(action: revealFileInFinder) {
                Label("Reveal in Finder", systemImage: "folder")
            }
        } else if item.contentType == .image {
            Button(action: quickViewImage) {
                Label("Quick Look", systemImage: "eye")
            }
            .disabled(item.localData == nil)
        } else if item.contentType == .url, let text = item.contentText, let url = URL(string: text) {
            Button(action: { NSWorkspace.shared.open(url) }) {
                Label("Open in Browser", systemImage: "safari")
            }
        }
        
        Button(action: saveItemToDisk) {
            switch item.contentType {
            case .image:
                Label("Save Image As…", systemImage: "square.and.arrow.down")
            case .file:
                Label("Save File As…", systemImage: "square.and.arrow.down")
            case .url:
                Label("Save Shortcut As…", systemImage: "square.and.arrow.down")
            case .text, .richText:
                Label("Save Snippet As…", systemImage: "square.and.arrow.down")
            case .video:
                Label("Save Video As…", systemImage: "square.and.arrow.down")
            }
        }
        
        Divider()
        
        if isTrashMode {
            Button(action: onRestore) {
                Label("Restore", systemImage: "arrow.uturn.left")
            }
            Button(role: .destructive, action: onPermanentDelete) {
                Label("Delete Permanently", systemImage: "trash")
            }
        } else {
            Button(role: .destructive, action: onTrash) {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }
    private var borderColor: Color {
        if isSelected { return Theme.accent }
        if isHovered { return Theme.accent.opacity(0.65) }
        return Theme.border
    }
    private var borderWidth: CGFloat {
        if stripMode { return isSelected || isHovered ? 1 : 0.75 }
        return isSelected || isHovered ? 1.5 : 1
    }
    private var cardFill: Color {
        Theme.card
    }
    private var pasteTypeLabel: String {
        if let lang = item.detectedLanguage { return lang }
        if item.contentType == .file, isPDFFile { return "PDF" }
        switch item.contentType {
        case .text: return "Text"
        case .richText: return "Rich Text"
        case .image: return "Image"
        case .video: return "Video"
        case .file: return "File"
        case .url: return "Link"
        }
    }
    private var pasteHeaderColor: Color {
        if let iconColor = headerIcon?.dominantAccentColor() {
            return iconColor
        }
        return appIconColor
    }
    private var isPDFFile: Bool {
        let name = (item.fileName ?? item.contentText ?? "").lowercased()
        return name.hasSuffix(".pdf") || item.mimeType == "application/pdf"
    }
    private var pasteMetadata: String {
        if item.contentType == .image {
            if let data = item.localData, let image = NSImage(data: data) {
                return "\(Int(image.size.width)) x \(Int(image.size.height))"
            }
            return item.fileSize.map(Formatters.fileSize) ?? "Image"
        }
        if item.contentType == .file || item.contentType == .video {
            // Finder cards intentionally stay minimal: the icon and filename
            // are enough to identify a file or folder.
            return ""
        }
        if let text = item.contentText {
            if item.detectedLanguage != nil {
                return "Code"
            }
            return "\(text.count) characters"
        }
        return item.sourceAppName
    }
    private var pasteFooterMetadata: String {
        pasteMetadata
    }
    private var pasteSourceName: String {
        let source = item.sourceAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? "Unknown App" : source
    }
    private var parsedColor: Color? {
        guard item.contentType == .text || item.contentType == .richText, let text = item.contentText else { return nil }
        return Color.parseColor(from: text)
    }
    @ViewBuilder
    private var largeHeaderAppIcon: some View {
        SoftNeumorphicIcon(
            image: headerIcon,
            fallbackSystemName: appIconName,
            fallbackColor: appIconColor,
            size: 52,
            elevation: .medium
        )
    }
    @ViewBuilder
    private var pasteStyleCard: some View {
        ZStack {
            if let color = parsedColor {
                Theme.card
                VStack(spacing: 0) {
                    ZStack {
                        color
                        Text(item.contentText ?? "")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(color.isLight ? Color.black.opacity(0.75) : Color.white.opacity(0.88))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1.5)
                    )
                    .padding(14)
                    // Match the standard non-expanded grid-card proportions.
                    .frame(height: isExpanded ? 388 : 170)
                    HStack {
                        Text("Colors")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                        if isTrashMode {
                            Button(action: { onRestore() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.uturn.left")
                                        .font(.system(size: 10, weight: .medium))
                                    Text("Restore")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundColor(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            .help("Restore to history")
                            Button(action: { onPermanentDelete() }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .help("Delete permanently")
                        } else {
                            Button(action: { onCopy() }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textSecondary)
                                    .opacity(isCopyHovered ? 1.0 : 0.4)
                            }
                            .buttonStyle(.plain)
                            .onHover { isCopyHovered = $0 }
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Theme.card)
                }
            } else {
                VStack(spacing: 0) {
                    pasteHeader
                    pasteContent
                    pasteFooter
                }
            }
        }
        // Keep a card inside the width assigned by its grid column. Without a
        // zero minimum, a wide image or attributed text can report its ideal
        // width and visually spill into an adjacent column.
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(maxWidth: isExpanded ? 800 : .infinity)
        .frame(height: isExpanded ? 600 : collapsedCardHeight)
        .background(Theme.neoBase)
        // One shared outer silhouette for cards everywhere: main grid, strip,
        // previews, and Trash. Internal media remains clipped by its own shape.
        .clipShape(Rectangle())
        .contentShape(Rectangle())
        // Double-tap MUST come before single-tap so SwiftUI waits for a possible 2nd tap
        .onTapGesture(count: 2) {
            if let onDoubleTap {
                onDoubleTap()
            } else if resolvedFileURL != nil {
                revealFileInFinder()
            } else if item.contentType == .image {
                openOCRViewer()
            } else if item.contentType == .text || item.contentType == .richText {
                isExpandedTextPresented = true
            }
        }
        .popover(isPresented: $isExpandedTextPresented, arrowEdge: .trailing) {
            ExpandedTextSnippetView(item: item, onSave: onSaveContent)
        }
        .onTapGesture {
            onPrimaryTap?()
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            fileActionsContextMenu
        }
    }
    private var pasteHeader: some View {
        let gradients = Theme.appHeaderGradient(for: item.sourceAppName, fallbackColor: pasteHeaderColor)
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pasteSourceName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text("\(pasteTypeLabel) · \(item.createdAt.relativeString())")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            // Grid tiles can become narrow beside the sidebar. Give the text
            // column a real zero-width compression limit so it truncates inside
            // its own card instead of expanding the card's layout offscreen.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
            
            largeHeaderAppIcon
                .allowsHitTesting(false)
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .frame(minWidth: 0, maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [gradients.0, gradients.1],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
    private var isRichMediaItem: Bool {
        guard let text = item.contentText?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text),
              let host = url.host?.lowercased() else {
            return false
        }
        let path = url.path.lowercased()
        return host.contains("music.apple.com") ||
            host.contains("itunes.apple.com") ||
            host.contains("podcasts.apple.com") ||
            host.contains("spotify.com") ||
            host.contains("soundcloud.com") ||
            host.contains("tidal.com") ||
            host.contains("bandcamp.com") ||
            host.contains("books.apple.com") ||
            host.contains("audible.com") ||
            host.contains("youtube.com") ||
            host.contains("youtu.be") ||
            host.contains("vimeo.com") ||
            path.contains("/album/") ||
            path.contains("/track/") ||
            path.contains("/playlist/") ||
            path.contains("/podcast/") ||
            path.contains("/episode/") ||
            path.contains("/book/")
    }
    private var isMapItem: Bool {
        item.sourceAppName.caseInsensitiveCompare("Maps") == .orderedSame ||
            item.sourceAppBundleID?.lowercased() == "com.apple.maps"
    }
    private var isBrowserSource: Bool {
        // This is intentionally a source-app classification, not a list of
        // website or media domains. Every native app can keep its own richer
        // link preview without special-casing News, Podcasts, Music, etc.
        let browserBundleIDs: Set<String> = [
            "com.apple.safari", "com.google.chrome", "org.mozilla.firefox",
            "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser.browser",
            "com.operasoftware.opera", "com.vivaldi.vivaldi"
        ]
        return item.sourceAppBundleID.map { browserBundleIDs.contains($0.lowercased()) } ?? false
    }
    @ViewBuilder
    private var pasteContent: some View {
        Group {
            if item.contentType == .url && !isMapItem {
                // Ordinary links render directly on the card background.
                // Maps use the image-style preview panel below.
                pasteURLPreview
                    .frame(height: isExpanded ? nil : 92)
            } else {
                ZStack {
                    Theme.neoContent
                        .softInnerShadow(
                            RoundedRectangle(cornerRadius: 14),
                            darkShadow: Color(hex: "#A3B1C6").opacity(0.35),
                            lightShadow: Color.white,
                            spread: 0.04,
                            radius: 4
                        )
                    switch item.contentType {
                    case .image:
                        if item.localData != nil {
                            PasteImagePreview(data: item.localData)
                        } else if let thumbnail = ThumbnailCache.shared.data(for: item.id) {
                            PasteImagePreview(data: thumbnail)
                        } else {
                            assetPlaceholder
                        }
                    case .video:
                        MiniVideoMockup()
                            .padding(10)
                    case .file:
                        pasteFilePreview
                    case .url:
                        pasteURLPreview
                    case .text, .richText:
                        pasteTextPreview
                    }
                }
                .frame(height: isExpanded ? nil : 92)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minWidth: 0)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var assetPlaceholder: some View {
        VStack(spacing: 7) {
            if isAssetLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading from iCloud…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            } else if let assetLoadError {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundColor(.orange)
                Text(assetLoadError)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Button("Retry", action: onRetryAssetDownload)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .semibold))
            } else if item.storagePath == nil {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundColor(.orange)
                Text("Original is unavailable")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Text("It was not synced before its local cache was cleared.")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundColor(Theme.textSecondary)
                Text("Preview not stored locally")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                Button("Download image", action: onRetryAssetDownload)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
    }
    @ViewBuilder
    private var pasteTextPreview: some View {
        Group {
            if item.contentType == .richText || isCodeContent || item.rtfData != nil || item.htmlData != nil || item.rtfdData != nil {
                RichTextCodeView(
                    item: item,
                    lineLimit: isExpanded ? nil : 5,
                    fontSize: 12,
                    textColor: NSColor(calibratedRed: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 1)
                )
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            } else {
                Text(item.contentText ?? "")
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(isExpanded ? nil : 4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .modifier(OptionalScrollModifier(isScrollable: isExpanded))
    }
    @ViewBuilder
    private var pasteFilePreview: some View {
        HStack(spacing: 12) {
            if let url = resolvedFileURL ?? item.originalFileURL {
                Image(nsImage: IconCache.shared.fileIcon(for: url))
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
            } else {
                Image(systemName: isPDFFile ? "doc.richtext.fill" : "doc.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundColor(pasteHeaderColor)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.fileName ?? item.contentText ?? "File")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
            if !pasteMetadata.isEmpty {
                Text(pasteMetadata)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            }
            Spacer()
        }
        .padding(10)
    }
    @ViewBuilder
    private var pasteURLPreview: some View {
        if let text = item.contentText, let url = URL(string: text), let host = url.host {
            LinkCardPreview(
                url: url,
                host: host,
                accentColor: pasteHeaderColor,
                forceMapLayout: isMapItem,
                usesNativePreview: !isBrowserSource
            )
        } else {
            Text(item.contentText ?? "")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
        }
    }
    private var pasteFooter: some View {
        HStack(spacing: 8) {
            if !pasteFooterMetadata.isEmpty {
                Text(pasteFooterMetadata)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            syncBadge
            HStack(spacing: 10) {
                if isTrashMode {
                    Button(action: { onRestore() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.left")
                                .font(.system(size: 10, weight: .light))
                            Text("Restore")
                                .font(.system(size: 10, weight: .light))
                        }
                        .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Restore to history")
                    Button(action: { onPermanentDelete() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .light))
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Delete permanently")
                } else {
                    neoIconButton(
                        systemName: "doc.on.doc",
                        isHovered: isCopyHovered,
                        action: { onCopy() }
                    )
                    .onHover { isCopyHovered = $0 }
                    .help("Copy")
                }
                if !isTrashMode {
                    neoIconButton(
                        systemName: item.isPinned ? "star.fill" : "star",
                        isHovered: isStarHovered,
                        isAccent: item.isPinned,
                        accentColor: Theme.starActive,
                        action: { onToggleFavorite() }
                    )
                    .onHover { isStarHovered = $0 }
                    .help("Favorite")
                    if stripMode {
                        neoIconButton(
                            systemName: "trash",
                            isHovered: isTrashHovered,
                            accentColor: .red,
                            action: onTrash
                        )
                        .onHover { isTrashHovered = $0 }
                        .help("Move to Trash")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .background(Theme.neoBase)
    }

    @ViewBuilder
    private func neoIconButton(
        systemName: String,
        isHovered: Bool,
        isAccent: Bool = false,
        accentColor: Color = Theme.accent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.neoBase)
                    .softInnerShadow(
                        RoundedRectangle(cornerRadius: 8),
                        darkShadow: Color(hex: "#A0AED0").opacity(isHovered ? 0.62 : 0.48),
                        lightShadow: Color.white.opacity(0.92),
                        spread: 0.16,
                        radius: isHovered ? 4.0 : 3.8
                    )
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isAccent ? accentColor : (isHovered ? Theme.textPrimary : Theme.textSecondary))
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
    @ViewBuilder
    private var tappableCardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, 10)
                .padding(.top, 12)
            Spacer(minLength: 4)
            contentPreviewSection
                .padding(.horizontal, 14)
                .onTapGesture(count: 2) {
                    if let onDoubleTap {
                        onDoubleTap()
                    } else if resolvedFileURL != nil {
                        revealFileInFinder()
                    } else if item.contentType == .image {
                        quickViewImage()
                    }
                }
                .onAppear {
                    if resolvedFileURL != nil || item.originalFileURL != nil,
                       IconCache.shared.cachedFileIcon(forItemId: item.id) == nil,
                       let url = resolvedFileURL ?? item.originalFileURL {
                        let icon = IconCache.shared.fileIcon(for: url)
                        IconCache.shared.saveFileIcon(icon, forItemId: item.id)
                    }
                }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onPrimaryTap?()
        }
    }
    @ViewBuilder
    private var headerRow: some View {
        HStack(alignment: .center, spacing: 6) {
            appBadge
            HStack(spacing: 5) {
                Text(item.sourceAppName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isMostRecent {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                        .help("Currently Active Clipboard")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(item.createdAt.relativeString())
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: "#F7F7F5"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border.opacity(0.65), lineWidth: 0.5)
        )
    }
    @ViewBuilder
    private var contentPreviewSection: some View {
        if item.contentType == .image || item.contentType == .video {
            ZStack {
                if item.contentType == .video {
                    MiniVideoMockup()
                } else {
                    MiniImagePreview(data: item.localData, fitImage: stripMode)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 0.5)
            )
        } else if item.contentType == .file {
            let name = item.fileName ?? item.contentText ?? "File"
            let rawExt = URL(fileURLWithPath: name).pathExtension
            let extUpper = rawExt.uppercased()
            let isFolder = item.mimeType == "inode/directory"
            let badge = isFolder ? "FOLDER" : (extUpper.isEmpty ? "FILE" : extUpper)
            MiniFileMockup(
                name: name,
                size: isFolder ? "" : Formatters.fileSize(item.fileSize),
                badge: badge,
                fileTypeExt: rawExt.lowercased(),
                fileURL: resolvedFileURL ?? item.originalFileURL
            )
        } else if item.contentType == .url {
            HStack(alignment: .top, spacing: 6) {
                if let t = item.contentText, let u = URL(string: t), let host = u.host {
                    if let icon = IconCache.shared.cachedFavicon(host: host) {
                        Image(nsImage: icon)
                            .resizable()
                            .renderingMode(.original)
                            .interpolation(.high)
                            .frame(width: 14, height: 14)
                            .cornerRadius(3)
                            .padding(.top, 1)
                    } else {
                        Image(systemName: "link")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.accent)
                            .padding(.top, 2)
                            .onAppear {
                                if let t = item.contentText, let u = URL(string: t), let host = u.host {
                                    IconCache.shared.fetchFavicon(forHost: host) { _ in }
                                }
                            }
                    }
                } else {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.accent)
                        .padding(.top, 2)
                }
                Text(item.contentText ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.accent)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
        } else {
            Group {
                if item.contentType == .richText || isCodeContent || item.rtfData != nil || item.htmlData != nil || item.rtfdData != nil {
                    VStack(alignment: .leading, spacing: 0) {
                        RichTextCodeView(item: item, lineLimit: isExpanded ? nil : 6)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.codeBlock)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 0.5)
                    )
                } else {
                    Text(item.contentText ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(isExpanded ? nil : 4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .modifier(OptionalScrollModifier(isScrollable: isExpanded))
        }
    }
    @ViewBuilder
    private var footerRow: some View {
        HStack {
            if item.contentType == .image || item.contentType == .video {
                HStack(spacing: 4) {
                    if item.contentType == .video {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                        Text("0:12")
                            .font(.system(size: 9, weight: .bold))
                    } else {
                        Text("PNG")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(hex: "#F1F1EF"))
                .foregroundColor(Theme.textPrimary)
                .cornerRadius(4)
            } else if let lang = item.detectedLanguage {
                HStack(spacing: 6) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 9, weight: .bold))
                    Text(lang)
                        .font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(hex: "#F1F1EF"))
                .foregroundColor(Theme.accent)
                .cornerRadius(4)
            } else if item.contentType == .richText {
                HStack(spacing: 6) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 9))
                    Text("Rich Text")
                        .font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(hex: "#F1F1EF"))
                .foregroundColor(Theme.textPrimary)
                .cornerRadius(4)
            }
            syncBadge
            Spacer()
            HStack(spacing: 9) {
                if isTrashMode {
                    Button(action: { onRestore() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.left")
                                .font(.system(size: 10, weight: .medium))
                            Text("Restore")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Restore to history")
                    Button(action: { onPermanentDelete() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Delete permanently")
                } else {
                    neoIconButton(
                        systemName: "doc.on.doc",
                        isHovered: isCopyHovered,
                        action: { onCopy() }
                    )
                    .onHover { isCopyHovered = $0 }
                    .help("Copy")
                }
                if !isTrashMode {
                    neoIconButton(
                        systemName: item.isPinned ? "star.fill" : "star",
                        isHovered: isStarHovered,
                        isAccent: item.isPinned,
                        accentColor: Theme.starActive,
                        action: { onToggleFavorite() }
                    )
                    .onHover { isStarHovered = $0 }
                    .help("Favorite")
                }
            }
        }
    }
    var body: some View {
        pasteStyleCard
    }
    @ViewBuilder
    private var syncBadge: some View {
        switch item.syncStatus {
        case .pending:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                Text("Syncing")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
            }
        case .failed:
            Button(action: { onRetrySync() }) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .font(.system(size: 9, weight: .bold))
                    Text("Retry")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(Color(hex: "#D32F2F"))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(hex: "#FFEBEB"))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("Sync failed — tap to retry")
        case .synced:
            EmptyView()
        }
    }
}
struct MiniImagePreview: View {
    let data: Data?
    var fitImage: Bool = false
    var body: some View {
        if let data, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.original)
                .interpolation(.high)
                .aspectRatio(contentMode: fitImage ? .fit : .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .clipped()
        } else {
            ZStack {
                Theme.codeBlock
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
        }
    }
}
struct PasteImagePreview: View {
    let data: Data?
    var body: some View {
        ZStack {
            Color(hex: "#F7F7F5")
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}
private struct LinkCardPreview: View {
    let url: URL
    let host: String
    let accentColor: Color
    let forceMapLayout: Bool
    let usesNativePreview: Bool
    @State private var title: String?
    @State private var image: NSImage?
    @State private var iconImage: NSImage?
    @State private var openGraphImage: NSImage?
    @State private var faviconImage: NSImage?
    @State private var didRequestMetadata: Bool

    init(
        url: URL,
        host: String,
        accentColor: Color,
        forceMapLayout: Bool = false,
        usesNativePreview: Bool = false
    ) {
        self.url = url
        self.host = host
        self.accentColor = accentColor
        self.forceMapLayout = forceMapLayout
        self.usesNativePreview = usesNativePreview
        let cached = LinkPreviewCache.shared.cachedMetadata(for: url)
        _title = State(initialValue: cached?.title)
        _openGraphImage = State(initialValue: cached?.image)
        _iconImage = State(initialValue: cached?.icon)
        _faviconImage = State(initialValue: IconCache.shared.cachedFavicon(host: host))
        _didRequestMetadata = State(initialValue: cached != nil && (cached?.image != nil || cached?.title != nil))
    }
    private var displayHost: String {
        host.replacingOccurrences(of: "www.", with: "")
    }
    private var visualImage: NSImage? {
        if let openGraphImage { return openGraphImage }
        if let image { return image }
        if let iconImage, isSquare(iconImage) { return iconImage }
        return nil
    }
    private func isSquare(_ image: NSImage) -> Bool {
        guard image.size.width > 0, image.size.height > 0 else { return false }
        let aspect = image.size.width / image.size.height
        return (0.75...1.35).contains(aspect)
    }
    var body: some View {
        Group {
            if forceMapLayout, let artwork = visualImage {
                // A map thumbnail is geographic content, not app artwork.
                // Let it occupy the whole preview like a copied image.
                mapHeroLayout(artwork: artwork)
            } else if usesNativePreview, let artwork = visualImage {
                nativeAppHeroLayout(artwork: artwork)
            } else {
                // Link metadata is inconsistent: some sites expose an Open
                // Graph image while others supply only an icon. Keep ordinary
                // links in one stable favicon-and-text layout either way.
                linkFallback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            await loadMetadataIfNeeded()
        }
    }

    @ViewBuilder
    private func mapHeroLayout(artwork: NSImage) -> some View {
        ZStack(alignment: .bottomLeading) {
            Image(nsImage: artwork)
                .resizable()
                .renderingMode(.original)
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            LinearGradient(
                colors: [.clear, .black.opacity(0.52)],
                startPoint: .center,
                endPoint: .bottom
            )

            Text(title ?? displayHost)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
                .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func nativeAppHeroLayout(artwork: NSImage) -> some View {
        VStack(spacing: 5) {
            Image(nsImage: artwork)
                .resizable()
                .renderingMode(.original)
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 68, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(title ?? displayHost)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    
    @ViewBuilder
    private var linkFallback: some View {
        // One unified fallback for all link types — no image available yet
        HStack(spacing: 12) {
            // Favicon or service icon
            Group {
                if let icon = faviconImage ?? iconImage ?? IconCache.shared.cachedFavicon(host: host) {
                    Image(nsImage: icon)
                        .resizable()
                        .renderingMode(.original)
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(accentColor.opacity(0.15))
                        Image(systemName: "link")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(accentColor.opacity(0.7))
                    }
                    .frame(width: 36, height: 36)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? displayHost)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(displayHost)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    @ViewBuilder
    private var favicon: some View {
        if let icon = faviconImage ?? IconCache.shared.cachedFavicon(host: host) {
            Image(nsImage: icon)
                .resizable()
                .renderingMode(.original)
                .frame(width: 28, height: 28)
                .cornerRadius(6)
        } else {
            Image(systemName: "link")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.18)))
        }
    }
    @MainActor
    private func loadMetadataIfNeeded() async {
        if didRequestMetadata && (visualImage != nil || title != nil) {
            return
        }
        didRequestMetadata = true
        IconCache.shared.fetchFavicon(forHost: host) { icon in
            self.faviconImage = icon
        }
        
        await LinkPreviewCache.shared.fetchMetadataIfNeeded(for: url, host: host)
        
        if let cached = LinkPreviewCache.shared.cachedMetadata(for: url) {
            if let t = cached.title { self.title = t }
            if let img = cached.image { self.openGraphImage = img }
            if let icon = cached.icon { self.iconImage = icon }
        }
    }
}
struct MiniWindowMockup: View {
    var body: some View {
        HStack(spacing: 3) {
            VStack(spacing: 2) {
                Spacer().frame(height: 3)
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color(hex: "#E8E8E5"))
                    .frame(width: 8, height: 1.5)
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color(hex: "#E8E8E5"))
                    .frame(width: 8, height: 1.5)
                Spacer()
            }
            .frame(width: 14)
            .background(Color(hex: "#F7F7F5"))
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white)
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white)
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white)
                    .frame(height: 6)
            }
            .padding(2)
            .background(Color(hex: "#F1F1EF"))
            VStack(spacing: 1.5) {
                Spacer().frame(height: 3)
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color(hex: "#E8E8E5"))
                    .frame(width: 12, height: 1.5)
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color(hex: "#E8E8E5"))
                    .frame(width: 12, height: 1.5)
                Spacer()
            }
            .frame(width: 18)
            .background(Color.white)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.border, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 1, y: 1)
    }
}
struct MiniLandscapeMockup: View {
    var body: some View {
        LinearGradient(
            colors: [Color(hex: "#FF7B90"), Color(hex: "#7B90FF"), Color(hex: "#50BFFF")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }
}
struct MiniVideoMockup: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "#191919"), Color(hex: "#37352F")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "play.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .cornerRadius(6)
    }
}
struct MiniFileMockup: View {
    let name: String
    let size: String
    let badge: String
    let fileTypeExt: String?
    var fileURL: URL? = nil
    var body: some View {
        HStack(spacing: 8) {
            if let url = fileURL {
                Image(nsImage: IconCache.shared.fileIcon(for: url))
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .cornerRadius(4)
            } else if let ext = fileTypeExt, !ext.isEmpty {
                Image(nsImage: NSWorkspace.shared.icon(forFileType: ext))
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .cornerRadius(4)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !badge.isEmpty {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: "#F1F1EF"))
                            .cornerRadius(3)
                    }
                    if !size.isEmpty {
                        Text(size)
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.codeBlock)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }
}
#Preview {
    VStack(spacing: 8) {
        ClipboardItemRow(
            item: ClipboardItem(
                contentType: .text,
                contentText: "git commit -m \"feat: add cloud sync\"",
                sourceAppName: "Terminal"
            ),
            isMostRecent: true
        )
        ClipboardItemRow(
            item: ClipboardItem(
                contentType: .url,
                contentText: "https://notion.so/workspace/design-system",
                sourceAppName: "Safari"
            )
        )
        ClipboardItemRow(
            item: ClipboardItem(
                contentType: .file,
                contentText: "Design Spec.pdf",
                sourceAppName: "Design Spec.pdf"
            )
        )
    }
    .padding(16)
    .background(Theme.bg)
    .frame(width: 340)
}
