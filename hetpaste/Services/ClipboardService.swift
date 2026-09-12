import AppKit
import Combine
import UniformTypeIdentifiers
final class ClipboardService: ObservableObject {
    private static let capturePausedDefaultsKey = "clipboard-capture-paused"
    private struct AppSource {
        let name: String
        let bundleID: String?
        let icon: NSImage?
        let observedAt: Date
    }
    var onNewItems: (([ClipboardItem]) -> Void)?
    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var captureGeneration: UInt = 0
    @Published private(set) var isCapturePaused: Bool
    private let pollInterval: TimeInterval = 0.25
    private let captureQueue = DispatchQueue(label: "com.hetpaste.clipboard-capture", qos: .userInitiated)
    private static let codeFileExtensions: Set<String> = [
        "ts","tsx","js","jsx","json","md","txt","yaml","yml","toml","ini","csv",
        "swift","m","mm","h","hpp","c","cc","cpp","rs","go","java","kt","kts",
        "py","rb","php","html","htm","css","scss","less","xml"
    ]
    private var ignoreNextChangeCount: Int?
    private var workspaceObserver: NSObjectProtocol?
    private var recentExternalApps: [AppSource] = []
    private var ownBundleID: String? {
        Bundle.main.bundleIdentifier
    }
    var captureRawTypes: Bool = false

    init() {
        isCapturePaused = UserDefaults.standard.bool(forKey: Self.capturePausedDefaultsKey)
    }

    func start() {
        // A paused monitor deliberately has no timer.  Always establish a
        // fresh baseline so content copied before launch/resume is ignored.
        lastChangeCount = NSPasteboard.general.changeCount
        guard !isCapturePaused, timer == nil else { return }
        updateLastExternalApp(from: NSWorkspace.shared.frontmostApplication)
        installWorkspaceObserver()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    func pauseCapture() {
        guard !isCapturePaused else { return }
        isCapturePaused = true
        UserDefaults.standard.set(true, forKey: Self.capturePausedDefaultsKey)

        // Invalidate any in-flight capture work before stopping the poller.
        captureGeneration &+= 1
        lastChangeCount = NSPasteboard.general.changeCount
        stop()
    }

    func resumeCapture() {
        guard isCapturePaused else { return }
        isCapturePaused = false
        UserDefaults.standard.set(false, forKey: Self.capturePausedDefaultsKey)

        // Do not import the pasteboard contents copied while monitoring was
        // paused.  Only changes occurring after this baseline are captured.
        lastChangeCount = NSPasteboard.general.changeCount
        start()
    }

    func toggleCapturePaused() {
        isCapturePaused ? resumeCapture() : pauseCapture()
    }
    func markSelfCopy() {
        ignoreNextChangeCount = NSPasteboard.general.changeCount
    }
    private func poll() {
        guard !isCapturePaused else {
            lastChangeCount = NSPasteboard.general.changeCount
            return
        }
        let pasteboard = NSPasteboard.general
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        if let ignore = ignoreNextChangeCount, ignore == current {
            ignoreNextChangeCount = nil
            return
        }
        let shouldCaptureRaw = captureRawTypes
        let sourceApp = detectedSourceApp()
        let generation = captureGeneration
        // NSPasteboard is mutable global state. Capture it on the poller's
        // thread before doing any expensive decoding, otherwise a fast second
        // copy can be recorded as the first change.
        let snapshot = PasteboardSnapshot(from: pasteboard)
        captureQueue.async { [weak self] in
            guard let self else { return }
            let items = self.captureFromSnapshot(snapshot, sourceApp: sourceApp, captureRaw: shouldCaptureRaw)
            DispatchQueue.main.async {
                guard !self.isCapturePaused, self.captureGeneration == generation else { return }
                self.onNewItems?(items.reversed())
            }
        }
    }
    private struct PasteboardSnapshot {
        let fileURLs: [URL]
        let pngData: Data?
        let tiffData: Data?
        let rtfdData: Data?
        let rtfData: Data?
        let htmlData: Data?
        let plainString: String?
        let allTypes: [NSPasteboard.PasteboardType]
        let allRawData: [NSPasteboard.PasteboardType: Data]
        init(from pasteboard: NSPasteboard) {
            fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            pngData  = pasteboard.data(forType: .png)
            tiffData = pasteboard.data(forType: .tiff)
            rtfdData = pasteboard.data(forType: .rtfd)
            rtfData  = pasteboard.data(forType: .rtf)
            htmlData = pasteboard.data(forType: .html)
            plainString = pasteboard.string(forType: .string)
            let types = pasteboard.types ?? []
            allTypes = types
            var raw: [NSPasteboard.PasteboardType: Data] = [:]
            for t in types { if let d = pasteboard.data(forType: t) { raw[t] = d } }
            allRawData = raw
        }
    }
    private func captureFromSnapshot(
        _ snapshot: PasteboardSnapshot,
        sourceApp: (name: String, bundleID: String?, icon: NSImage?),
        captureRaw: Bool
    ) -> [ClipboardItem] {
        let appName  = sourceApp.name
        let bundleID = sourceApp.bundleID
        if let bundleID, let icon = sourceApp.icon {
            IconCache.shared.prime(bundleID: bundleID, runningIcon: icon)
        }
        let iconData: Data? = {
            if let bundleID, !bundleID.isEmpty,
               let data = IconCache.shared.appIconPNGData(bundleID: bundleID) {
                return data
            }
            // Frontmost-app monitoring supplies the NSRunningApplication icon
            // even when a bundle identifier is unavailable (Finder aliases,
            // helper processes, older apps). Persist that concrete image.
            return sourceApp.icon.flatMap { IconCache.shared.appIconPNGData(image: $0) }
        }()
        if !snapshot.fileURLs.isEmpty {
            return snapshot.fileURLs.compactMap { fileURL in
                guard var item = captureFile(at: fileURL, appName: appName, bundleID: bundleID) else { return nil }
                item.appIconData = iconData
                return item
            }
        }
        if let imageData = resolvedImageData(png: snapshot.pngData, tiff: snapshot.tiffData) {
            var item = ClipboardItem(
                contentType: .image,
                contentText: nil,
                sourceAppName: appName,
                sourceAppBundleID: bundleID,
                appIconData: iconData,
                syncStatus: .pending,
                fileName: "image-\(Int(Date().timeIntervalSince1970)).png",
                fileSize: Int64(imageData.count),
                mimeType: "image/png",
                localData: imageData
            )
            if captureRaw { item.rawPasteboardData = nonEmptyDict(snapshot.allRawData) }
            return [item]
        }
        let plainText = resolvedPlainText(
            string: snapshot.plainString,
            rtfdData: snapshot.rtfdData,
            rtfData: snapshot.rtfData,
            htmlData: snapshot.htmlData
        )
        if var richText = captureRichTextFromSnapshot(snapshot, plainText: plainText, appName: appName, bundleID: bundleID) {
            richText.appIconData = iconData
            richText.detectedLanguage = CodeLanguageDetector.detectLanguage(in: richText.contentText ?? "")
            if captureRaw { richText.rawPasteboardData = nonEmptyDict(snapshot.allRawData) }
            return [richText]
        }
        if let text = plainText {
            let type: ContentType = isURL(text) ? .url : .text
            var item = ClipboardItem(
                contentType: type,
                contentText: text,
                sourceAppName: appName,
                sourceAppBundleID: bundleID,
                appIconData: iconData,
                syncStatus: .pending
            )
            if type == .text {
                item.detectedLanguage = CodeLanguageDetector.detectLanguage(in: text)
            }
            if captureRaw { item.rawPasteboardData = nonEmptyDict(snapshot.allRawData) }
            return [item]
        }
        return []
    }
    private func nonEmptyDict(_ dict: [NSPasteboard.PasteboardType: Data]) -> [String: Data]? {
        guard !dict.isEmpty else { return nil }
        return Dictionary(uniqueKeysWithValues: dict.map { ($0.key.rawValue, $0.value) })
    }
    func captureAllRawTypes(from pasteboard: NSPasteboard) -> [String: Data]? {
        guard let types = pasteboard.types, !types.isEmpty else { return nil }
        var result: [String: Data] = [:]
        for pbType in types {
            if let data = pasteboard.data(forType: pbType) {
                result[pbType.rawValue] = data
            }
        }
        return result.isEmpty ? nil : result
    }
    private func captureFile(at inputURL: URL, appName: String, bundleID: String?) -> ClipboardItem? {
        let resolvedURL = (try? URL(resolvingAliasFileAt: inputURL, options: [])) ?? inputURL
        let resourceValues = try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = resourceValues?.isDirectory == true
        // Preserve the exact Finder item the user copied. In particular, a
        // folder is a folder, not an implicitly-created ZIP archive.
        let url = resolvedURL
        // A file URL copied from Finder can carry a security-scoped grant when
        // the app is sandboxed. Hold that scope for the exact read/bookmark
        // operation, then persist the bookmark for later user actions.
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }
        let ext = isDirectory ? "" : url.pathExtension.lowercased()
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let utType = isDirectory ? UTType.folder : (values?.contentType ?? UTType(filenameExtension: ext))
        let mime = isDirectory ? "inode/directory" : (utType?.preferredMIMEType ?? "application/octet-stream")
        let type = classifyFileType(utType: utType, extension: ext, codeExtensions: Self.codeFileExtensions)
        let size: Int64
        let data: Data?
        if isDirectory {
            // Keep the folder URL and name for local Finder behaviour, but
            // retain an internal archive payload for iCloud transport.
            // The archive is never presented as the copied item.
            guard let archiveData = folderArchiveData(for: url) else { return nil }
            size = Int64(archiveData.count)
            data = archiveData
        } else {
            // Do not create a deceptively usable cloud card if a file cannot
            // be read. A security bookmark remains for local Finder actions,
            // but cross-device transfer requires real bytes.
            guard let fileSize = values?.fileSize.map({ Int64($0) }) ?? (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) else { return nil }
            size = fileSize
            data = size <= 48 * 1024 * 1024 ? try? Data(contentsOf: url) : nil
            guard size > 48 * 1024 * 1024 || data != nil else { return nil }
        }
        let displayName = url.lastPathComponent
        let item = ClipboardItem(
            contentType: type,
            contentText: displayName,
            sourceAppName: appName,
            sourceAppBundleID: bundleID,
            syncStatus: .pending,
            fileName: displayName,
            fileSize: size,
            mimeType: mime,
            originalFileURL: url,
            localData: data
        )
        try? FileAccessStore.shared.save(url: url, for: item.id)
        let icon = IconCache.shared.fileIcon(for: url)
        IconCache.shared.saveFileIcon(icon, forItemId: item.id)
        return item
    }

    private func folderArchiveData(for directory: URL) -> Data? {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("hetpaste-folder-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        defer { try? FileManager.default.removeItem(at: archive) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", directory.path, archive.path]
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return try? Data(contentsOf: archive)
        } catch {
            return nil
        }
    }

    private func captureRichTextFromSnapshot(
        _ snapshot: PasteboardSnapshot,
        plainText: String?,
        appName: String,
        bundleID: String?
    ) -> ClipboardItem? {
        let formats: [(data: Data?, type: NSPasteboard.PasteboardType, docType: NSAttributedString.DocumentType)] = [
            (snapshot.rtfdData, .rtfd, .rtfd),
            (snapshot.rtfData,  .rtf,  .rtf),
            (snapshot.htmlData, .html, .html)
        ]
        for format in formats {
            guard let data = format.data else { continue }
            let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: format.docType],
                documentAttributes: nil
            )
            guard let attributed, isMeaningfullyRichText(attributed, plainText: plainText) else { continue }
            let cleanedText = stripLeadingBrowserChrome(from: attributed.string)
            let fullRange = NSRange(location: 0, length: attributed.length)
            // RTF is the portable editing baseline. Browsers often provide
            // only HTML; canonicalising it here on macOS means iOS never has
            // to invoke Foundation's crash-prone HTML importer just to retain
            // underline, font, colour or paragraph attributes.
            let canonicalRTF = snapshot.rtfData
                ?? (format.type == .rtf ? data : nil)
                ?? (try? attributed.data(from: fullRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
            let canonicalHTML = snapshot.htmlData
                ?? (format.type == .html ? data : nil)
                ?? (try? attributed.data(from: fullRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]))
            return ClipboardItem(
                contentType: .richText,
                contentText: cleanedText,
                sourceAppName: appName,
                sourceAppBundleID: bundleID,
                syncStatus: .pending,
                rtfData: canonicalRTF,
                htmlData: canonicalHTML,
                rtfdData: snapshot.rtfdData ?? (format.type == .rtfd ? data : nil)
            )
        }
        return nil
    }
    private func resolvedPlainText(
        string: String?,
        rtfdData: Data?,
        rtfData: Data?,
        htmlData: Data?
    ) -> String? {
        if let text = string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return stripLeadingBrowserChrome(from: text)
        }
        let pairs: [(Data?, NSAttributedString.DocumentType)] = [
            (rtfdData, .rtfd), (rtfData, .rtf), (htmlData, .html)
        ]
        for (data, docType) in pairs {
            guard let data else { continue }
            if let text = (try? NSAttributedString(data: data,
                options: [.documentType: docType],
                documentAttributes: nil))?.string
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty { return stripLeadingBrowserChrome(from: text) }
        }
        return nil
    }

    /// Browsers sometimes put accessibility links and navigation controls in the
    /// plain-text clipboard representation ahead of the content the user copied.
    /// Remove only a leading run after a strong accessibility marker; normal text
    /// that happens to mention one of these words is left untouched.
    private func stripLeadingBrowserChrome(from text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        let chromeLines: Set<String> = [
            "skip to main content", "accessibility help", "accessibility feedback",
            "sign in", "ai mode", "all", "images", "videos", "shopping", "news",
            "short videos", "more", "tools"
        ]
        guard let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              first == "skip to main content" || first == "accessibility help"
        else { return text }

        while let first = lines.first {
            let normalized = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty || chromeLines.contains(normalized) {
                lines.removeFirst()
            } else {
                break
            }
        }
        let cleaned = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
    }
    private func resolvedImageData(png: Data?, tiff: Data?) -> Data? {
        if let png { return png }
        if let tiff,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { return png }
        return nil
    }
    private func isMeaningfullyRichText(_ attributed: NSAttributedString, plainText: String?) -> Bool {
        guard attributed.length > 0 else { return false }
        let candidate = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        if let plainText,
           candidate == plainText.trimmingCharacters(in: .whitespacesAndNewlines) {
            // Terminal and some editor pasteboards split a visually uniform
            // selection into many RTF runs. A fixed-pitch font with one shared
            // foreground/background palette is presentation chrome, not
            // authored rich text. Keeping it made ordinary pasted text appear
            // as selected text on a dark background in Snipy.
            if isSinglePlainLookingRun(attributed) || isUniformMonospacedPresentation(attributed) {
                return false
            }
        }
        var score = 0
        var highConfidenceFormatting = false
        var runCount = 0
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length), options: []) { attributes, _, stop in
            runCount += 1
            let result = meaningfulFormattingResult(attributes)
            score += result.score
            highConfidenceFormatting = highConfidenceFormatting || result.highConfidence
            if highConfidenceFormatting || score >= 2 {
                stop.pointee = true
            }
        }
        return highConfidenceFormatting || score >= 2 || (runCount > 1 && score > 0)
    }

    private func isUniformMonospacedPresentation(_ attributed: NSAttributedString) -> Bool {
        var referenceForeground: NSColor?
        var referenceBackground: NSColor?
        var sawFixedPitchFont = false
        var isUniform = true

        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length), options: []) { attributes, _, stop in
            // These attributes convey actual document structure or styling and
            // must always remain rich text, even in a monospaced font.
            if attributes[.attachment] != nil || attributes[.link] != nil ||
                attributes[.underlineStyle] != nil || attributes[.strikethroughStyle] != nil ||
                attributes[.baselineOffset] != nil || attributes[.kern] != nil ||
                attributes[.shadow] != nil || attributes[.strokeWidth] != nil ||
                attributes[.strokeColor] != nil {
                isUniform = false
                stop.pointee = true
                return
            }

            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                guard font.isFixedPitch,
                      !traits.contains(.boldFontMask),
                      !traits.contains(.italicFontMask) else {
                    isUniform = false
                    stop.pointee = true
                    return
                }
                sawFixedPitchFont = true
            }

            let foreground = attributes[.foregroundColor] as? NSColor
            let background = attributes[.backgroundColor] as? NSColor
            if let referenceForeground, !colorsMatch(referenceForeground, foreground) {
                isUniform = false
                stop.pointee = true
                return
            }
            if let referenceBackground, !colorsMatch(referenceBackground, background) {
                isUniform = false
                stop.pointee = true
                return
            }
            if referenceForeground == nil { referenceForeground = foreground }
            if referenceBackground == nil { referenceBackground = background }
        }
        return isUniform && sawFixedPitchFont
    }

    private func colorsMatch(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs?.usingColorSpace(.deviceRGB), rhs?.usingColorSpace(.deviceRGB)) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return colorDistance(lhs, rhs) < 0.01
        default: return false
        }
    }
    private func isSinglePlainLookingRun(_ attributed: NSAttributedString) -> Bool {
        var runCount = 0
        var hasFormatting = false
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length), options: []) { attributes, _, stop in
            runCount += 1
            let result = meaningfulFormattingResult(attributes)
            if result.highConfidence || result.score > 0 {
                hasFormatting = true
            }
            if runCount > 1 || hasFormatting {
                stop.pointee = true
            }
        }
        return runCount <= 1 && !hasFormatting
    }
    private func meaningfulFormattingResult(_ attributes: [NSAttributedString.Key: Any]) -> (score: Int, highConfidence: Bool) {
        if attributes[.attachment] != nil {
            return (3, true)
        }
        if attributes[.link] != nil {
            return (3, true)
        }
        if attributes[.underlineStyle] != nil || attributes[.strikethroughStyle] != nil {
            return (2, true)
        }
        if attributes[.baselineOffset] != nil || attributes[.kern] != nil {
            return (1, false)
        }
        if let foreground = attributes[.foregroundColor] as? NSColor,
           isMeaningfulForegroundColor(foreground) {
            return (2, true)
        }
        if let background = attributes[.backgroundColor] as? NSColor,
           isMeaningfulBackgroundColor(background) {
            return (2, true)
        }
        if attributes[.shadow] != nil || attributes[.strokeWidth] != nil || attributes[.strokeColor] != nil {
            return (2, true)
        }
        if attributes[.obliqueness] != nil || attributes[.expansion] != nil || attributes[.textEffect] != nil {
            return (1, false)
        }
        if attributes[.writingDirection] != nil ||
           attributes[.superscript] != nil ||
           attributes[.verticalGlyphForm] != nil {
            return (1, false)
        }
        if let font = attributes[.font] as? NSFont {
            if font.isFixedPitch {
                return (1, false)
            }
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) || traits.contains(.italicFontMask) {
                return (2, true)
            }
        }
        if let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle {
            if paragraphStyle.alignment != .natural && paragraphStyle.alignment != .left ||
               paragraphStyle.firstLineHeadIndent != 0 ||
               paragraphStyle.headIndent != 0 ||
               paragraphStyle.tailIndent != 0 ||
               paragraphStyle.lineSpacing != 0 ||
               paragraphStyle.paragraphSpacing != 0 ||
               paragraphStyle.paragraphSpacingBefore != 0 ||
               paragraphStyle.minimumLineHeight != 0 ||
               paragraphStyle.maximumLineHeight != 0 ||
               paragraphStyle.lineHeightMultiple != 0 ||
               paragraphStyle.hyphenationFactor != 0 {
                return (1, false)
            }
            if paragraphStyle.baseWritingDirection != .natural {
                return (1, false)
            }
        }
        return (0, false)
    }
    private func isMeaningfulForegroundColor(_ color: NSColor) -> Bool {
        guard let normalized = color.usingColorSpace(.deviceRGB) else { return true }
        guard let defaultColor = NSColor.labelColor.usingColorSpace(.deviceRGB) else { return true }
        return colorDistance(normalized, defaultColor) > 0.08
    }
    private func isMeaningfulBackgroundColor(_ color: NSColor) -> Bool {
        guard let normalized = color.usingColorSpace(.deviceRGB) else { return true }
        guard normalized.alphaComponent > 0.05 else { return false }
        guard let white = NSColor.white.usingColorSpace(.deviceRGB) else { return true }
        let whiteDistance = colorDistance(normalized, white)
        return whiteDistance > 0.08
    }
    private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let redDelta = lhs.redComponent - rhs.redComponent
        let greenDelta = lhs.greenComponent - rhs.greenComponent
        let blueDelta = lhs.blueComponent - rhs.blueComponent
        let alphaDelta = lhs.alphaComponent - rhs.alphaComponent
        return sqrt((redDelta * redDelta) + (greenDelta * greenDelta) + (blueDelta * blueDelta) + (alphaDelta * alphaDelta))
    }
    private func classifyFileType(utType: UTType?, extension ext: String, codeExtensions: Set<String>) -> ContentType {
        if utType?.conforms(to: .image) == true {
            return .image
        }
        if (utType?.conforms(to: .movie) == true || utType?.conforms(to: .audiovisualContent) == true),
           !codeExtensions.contains(ext) {
            return .video
        }
        return .file
    }
    private func imageData(from pasteboard: NSPasteboard) -> Data? {
        resolvedImageData(png: pasteboard.data(forType: .png), tiff: pasteboard.data(forType: .tiff))
    }
    private func isURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), trimmed.count < 2048 else { return false }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }
    private func installWorkspaceObserver() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.updateLastExternalApp(from: app)
        }
    }
    private func updateLastExternalApp(from app: NSRunningApplication?) {
        guard let app else { return }
        let bundleID = app.bundleIdentifier
        guard !isOwnApp(bundleID: bundleID) else { return }
        let source = AppSource(
            name: app.localizedName ?? "Unknown",
            bundleID: bundleID,
            icon: app.icon,
            observedAt: Date()
        )
        recentExternalApps.removeAll { $0.bundleID == bundleID }
        recentExternalApps.insert(source, at: 0)
        if recentExternalApps.count > 8 {
            recentExternalApps.removeLast(recentExternalApps.count - 8)
        }
    }
    private func detectedSourceApp() -> (name: String, bundleID: String?, icon: NSImage?) {
        if let recent = recentExternalApps.first {
            return (recent.name, recent.bundleID, recent.icon)
        }
        return ("Unknown", nil, nil)
    }
    private func isOwnApp(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if bundleID == ownBundleID { return true }
        return bundleID.localizedCaseInsensitiveContains("hetpaste")
    }
}
