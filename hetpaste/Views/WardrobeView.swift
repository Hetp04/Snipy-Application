import SwiftUI
import UniformTypeIdentifiers

struct WardrobeView: View {
    @ObservedObject var viewModel: WardrobeViewModel
    @ObservedObject var controller: QuickClipboardStripController
    
    private let cardWidth: CGFloat = 312
    @State private var isDropTargeted = false
    
    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if viewModel.items.isEmpty {
                    emptyState
                } else {
                    wardrobeGrid
                }
            }
            .onAppear {
                controller.syncFocus(itemCount: viewModel.items.count)
            }
            .onChange(of: viewModel.items.count) { _, newCount in
                controller.syncFocus(itemCount: newCount)
            }
            .onChange(of: controller.focusedIndex) { _, _ in
                scrollToFocusedCard(using: proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDropTargeted ? Color.purple.opacity(0.05) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDropTargeted ? Color.purple.opacity(0.5) : Color.clear, lineWidth: 2)
                .padding(4)
        )
        .onDrop(
            of: [.fileURL, .url, .image, .plainText, .rtf, UTType.hetpasteWardrobeItemID],
            isTargeted: $isDropTargeted
        ) { providers in
            handleDrop(providers: providers)
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "hanger")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(Color.purple.opacity(0.6))
            }
            
            VStack(spacing: 6) {
                Text("Drag anything here to save it for later")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                
                Text("Items never touch the clipboard — just a private staging shelf")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color.purple.opacity(0.7))
                    Text("Drag files, images, links, or text from anywhere")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
                
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color.purple.opacity(0.7))
                    Text("Drag out to use, or click copy when you need it")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
                
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 12))
                        .foregroundColor(Color.purple.opacity(0.7))
                    Text("Also drop on the menu bar icon anytime")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
    }
    
    private var wardrobeGrid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .center, spacing: 16) {
                ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                    wardrobeCard(for: item, index: index)
                        .id(item.id)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
    }
    
    private func wardrobeCard(for item: WardrobeItem, index: Int) -> some View {
        WardrobeItemCard(
            item: item,
            isSelected: controller.focusedIndex == index,
            onCopy: {
                copyWardrobeItem(item)
            },
            onDelete: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    viewModel.deleteItem(item)
                }
            },
            onRevealInFinder: {
                revealWardrobeItemInFinder(item)
            },
            onPrimaryTap: {
                controller.focusItem(at: index, itemCount: viewModel.items.count)
            },
            isAssetLoading: viewModel.assetLoadingIDs.contains(item.id),
            assetLoadError: viewModel.assetLoadError(for: item.id),
            onRetryAssetDownload: { viewModel.retryAssetDownload(for: item) }
        )
        .frame(width: cardWidth)
        .onAppear {
            if item.contentType == .image || item.contentType == .file || item.contentType == .video {
                viewModel.loadLocalDataIfNeeded(for: item)
            }
        }
    }
    
    private func copyWardrobeItem(_ item: WardrobeItem) {
        Task {
            let result = await viewModel.copyToClipboard(item)
            controller.showToast(result.message, isError: !result.didCopy)
        }
    }

    private func revealWardrobeItemInFinder(_ item: WardrobeItem) {
        let result = viewModel.revealInFinder(item)
        if !result.didReveal {
            controller.showToast(result.message, isError: true)
        }
    }
    
    private func scrollToFocusedCard(using proxy: ScrollViewProxy) {
        guard viewModel.items.indices.contains(controller.focusedIndex) else { return }
        let item = viewModel.items[controller.focusedIndex]
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(item.id, anchor: .center)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let internalProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.hetpasteWardrobeItemID.identifier)
        }
        let externalProviders = providers.filter {
            !$0.hasItemConformingToTypeIdentifier(UTType.hetpasteWardrobeItemID.identifier)
        }

        // Process every provider in a multi-selection, including mixed drops.
        for provider in internalProviders {
            handleInternalItemDrop(provider: provider)
        }
        if !externalProviders.isEmpty {
            Task {
                await viewModel.addFromDrop(providers: externalProviders)
                let count = externalProviders.count
                controller.showToast(
                    count == 1 ? "Added to Wardrobe" : "Added \(count) items to Wardrobe",
                    isError: false
                )
            }
        }
        return !providers.isEmpty
    }
    
    private func handleInternalItemDrop(provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.hetpasteWardrobeItemID.identifier, options: nil) { [weak viewModel, weak controller] item, error in
            guard error == nil else { return }
            
            let uuidString: String?
            if let data = item as? Data {
                uuidString = String(data: data, encoding: .utf8)
            } else if let string = item as? String {
                uuidString = string
            } else {
                uuidString = nil
            }
            
            guard let uuidStr = uuidString, let uuid = UUID(uuidString: uuidStr) else { return }
            
            // Get the clipboard item from the main view model
            // We'll need to pass this in or access it differently
            // For now, we'll trigger via a notification or callback
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("AddToWardrobeFromClipboard"),
                    object: nil,
                    userInfo: ["itemID": uuid]
                )
                controller?.showToast("Added to Wardrobe from History", isError: false)
            }
        }
    }
    
    private func handleExternalDrop(providers: [NSItemProvider]) -> Bool {
        Task {
            await viewModel.addFromDrop(providers: providers)
            controller.showToast("Added to Wardrobe", isError: false)
        }
        return true
    }
}

// MARK: - Wardrobe Item Card (Reuses ClipboardItemRow styling)

struct WardrobeItemCard: View {
    let item: WardrobeItem
    let isSelected: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onRevealInFinder: () -> Void
    let onPrimaryTap: () -> Void
    var isAssetLoading: Bool = false
    var assetLoadError: String? = nil
    var onRetryAssetDownload: () -> Void = {}
    
    @State private var isHovered = false
    @State private var isCopyHovered = false
    @State private var isStarHovered = false
    
    private var headerIcon: NSImage? {
        if let bid = item.sourceAppBundleID, !bid.isEmpty {
            if let img = IconCache.shared.cachedAppIcon(bundleID: bid) {
                return img
            }
            return IconCache.shared.resolveAppIcon(bundleID: bid)
        }
        return nil
    }
    
    private var appIconName: String {
        let appName = item.sourceAppName ?? "Unknown"
        switch appName.lowercased() {
        case "finder": return "folder"
        case "safari": return "safari"
        case "chrome": return "globe"
        case "terminal": return "terminal"
        default: return "app.fill"
        }
    }
    
    private var appIconColor: Color {
        let appName = item.sourceAppName ?? "Unknown"
        switch appName.lowercased() {
        case "finder": return Color(hex: "#48A7F8")
        case "safari": return Color(hex: "#006CFF")
        case "chrome": return Color(hex: "#4285F4")
        case "terminal": return Color(hex: "#1A1A1A")
        default: return Theme.textSecondary
        }
    }
    
    private var pasteHeaderColor: Color {
        if let iconColor = headerIcon?.dominantAccentColor() {
            return iconColor
        }
        return appIconColor
    }
    
    private var pasteTypeLabel: String {
        if item.mimeType == "inode/directory" {
            return "Folder"
        }
        if let ext = item.fileExtension, !ext.isEmpty {
            return ext.uppercased()
        }
        switch item.contentType {
        case .text: return "Text"
        case .richText: return "Rich Text"
        case .image: return "Image"
        case .video: return "Video"
        case .file: return "File"
        case .url: return "Link"
        }
    }
    
    private var pasteMetadata: String {
        if item.mimeType == "inode/directory" {
            return item.content ?? "Folder"
        }
        if let size = item.fileSize {
            return formatFileSize(size)
        }
        if let fileName = item.fileName {
            return fileName
        }
        return item.sourceAppName ?? "Unknown"
    }
    
    private var pasteSourceName: String {
        let source = (item.sourceAppName ?? "Unknown").trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? "Unknown App" : source
    }

    /// A card is revealable when it came from a real file system location,
    /// regardless of whether Wardrobe renders it as a file, image, or video.
    private var hasFinderReference: Bool {
        item.originalFilePath != nil || FileAccessStore.shared.resolve(for: item.id) != nil
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
    
    var body: some View {
        pasteStyleCard
    }
    
    @ViewBuilder
    private var pasteStyleCard: some View {
        ZStack {
            VStack(spacing: 0) {
                pasteHeader
                pasteContent
                pasteFooter
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.neoBase)
        .clipShape(Rectangle())
        .softOuterShadow(
            darkShadow: Color(hex: "#A3B1C6").opacity(0.35),
            lightShadow: Color.white,
            offset: 6,
            radius: 8
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onPrimaryTap()
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onDrag {
            let provider = NSItemProvider(object: item.id.uuidString as NSString)
            return provider
        }
        .contextMenu {
            if hasFinderReference {
                Button(action: onRevealInFinder) {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        }
    }
    
    private var pasteHeader: some View {
        let gradients = Theme.appHeaderGradient(for: pasteSourceName, fallbackColor: pasteHeaderColor)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            
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
    
    @ViewBuilder
    private var pasteContent: some View {
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
                if let data = item.localData, let nsImage = NSImage(data: data) {
                    PasteImagePreview(data: data)
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
        .frame(maxWidth: .infinity)
        .frame(height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if hasFinderReference {
                onRevealInFinder()
            }
        }
        .padding(.horizontal, 10)
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
            } else {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundColor(Theme.textSecondary)
                Text("Loading preview…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
    }
    
    @ViewBuilder
    private var pasteTextPreview: some View {
        Group {
            if let text = item.content {
                Text(text)
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            } else {
                emptyContentView
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
    
    @ViewBuilder
    private var pasteFilePreview: some View {
        HStack(spacing: 12) {
            // Use FileIconView for async QuickLook thumbnail
            FileIconView(item: item, iconSize: 44)
            
            VStack(alignment: .leading, spacing: 5) {
                Text(item.fileName ?? "File")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                Text(pasteMetadata)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
    }
    
    @ViewBuilder
    private var pasteURLPreview: some View {
        if let text = item.content, !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color.blue.opacity(0.7))
                    Text("URL")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
        } else {
            emptyContentView
        }
    }
    
    private var emptyContentView: some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(Theme.textTertiary)
            Text("No preview")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textTertiary)
        }
    }
    
    private var pasteFooter: some View {
        HStack(spacing: 8) {
            Text(pasteMetadata)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 10) {
                neoIconButton(
                    systemName: "doc.on.doc",
                    isHovered: isCopyHovered,
                    action: { onCopy() }
                )
                .onHover { isCopyHovered = $0 }
                .help("Copy")
                
                neoIconButton(
                    systemName: "trash",
                    isHovered: isStarHovered,
                    isAccent: false,
                    accentColor: .red,
                    action: { onDelete() }
                )
                .onHover { isStarHovered = $0 }
                .help("Remove from Wardrobe")
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
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - FileIconView (Async Icon/Thumbnail Loading)

private struct FileIconView: View {
    let item: WardrobeItem
    var iconSize: CGFloat = 48
    
    @State private var loadedIcon: NSImage?
    @State private var isLoading = false
    
    var body: some View {
        VStack(spacing: 8) {
            if let icon = loadedIcon {
                // Show loaded icon/thumbnail
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: iconSize, height: iconSize)
            } else {
                // Show placeholder while loading
                if item.mimeType == "inode/directory" {
                    Image(nsImage: FileIconCache.shared.folderIcon())
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: iconSize, height: iconSize)
                } else {
                    Image(systemName: genericIconName(for: item))
                        .font(.system(size: iconSize * 0.67, weight: .light))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            
            if iconSize >= 48 {
                if let fileName = item.fileName {
                    Text(fileName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                
                // Show folder item count or file size
                if item.mimeType == "inode/directory" {
                    if let content = item.content {
                        Text(content)  // e.g., "Folder: 12 items"
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                } else if let fileSize = item.fileSize {
                    Text(formatFileSize(fileSize))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
            }
        }
        .onAppear {
            loadIcon()
        }
    }
    
    private func loadIcon() {
        guard !isLoading else { return }
        isLoading = true
        
        let thumbnailSize = CGSize(width: iconSize * 2, height: iconSize * 2)
        
        // Priority: original path (QuickLook thumbnail) > extension > MIME type > fallback
        if let path = item.originalFilePath {
            // Use QuickLook for content-aware thumbnails (PDF pages, image previews, etc.)
            FileIconCache.shared.icon(forFileAtPath: path, size: thumbnailSize) { icon in
                self.loadedIcon = icon
            }
        } else if item.mimeType == "inode/directory" {
            loadedIcon = FileIconCache.shared.folderIcon()
        } else if let ext = item.fileExtension, !ext.isEmpty {
            loadedIcon = FileIconCache.shared.icon(forFileType: ext)
        } else if let mimeType = item.mimeType {
            loadedIcon = FileIconCache.shared.icon(forFileType: mimeType)
        } else {
            // Final fallback stays as generic icon
            loadedIcon = NSWorkspace.shared.icon(for: .item)
        }
    }
    
    private func genericIconName(for item: WardrobeItem) -> String {
        if item.contentType == .image {
            return "photo"
        } else if item.contentType == .video {
            return "play.rectangle.fill"
        } else {
            return "doc.fill"
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
