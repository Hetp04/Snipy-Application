import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers
private enum StripFolderEditor: Equatable {
    case creating
    case renaming(UUID)
}
@MainActor
final class QuickClipboardStripController: ObservableObject {
    @Published var focusedIndex: Int = 0
    @Published var selectedFolderID: UUID?
    @Published var selectedContentType: ContentType?
    @Published var isWardrobeSelected: Bool = false
    @Published var toastMessage: String?
    @Published var isToastError: Bool = false
    @Published var previewItem: ClipboardItem?
    @Published private(set) var isDraggingCard = false
    @Published private(set) var draggingItemID: UUID?
    private var toastTask: Task<Void, Never>?
    private var dragResetTask: Task<Void, Never>?
    func beginCardDrag(itemID: UUID) {
        dragResetTask?.cancel()
        draggingItemID = itemID
        isDraggingCard = true
        dragResetTask = Task { [weak self] in
            // SwiftUI does not expose native-drag completion. Polling the
            // button state lets us restore the source on the actual release,
            // including a cancelled drag outside of our views.
            while !Task.isCancelled && (NSEvent.pressedMouseButtons & 1) != 0 {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.isDraggingCard = false
            self?.draggingItemID = nil
        }
    }
    func endCardDrag() {
        dragResetTask?.cancel()
        isDraggingCard = false
        draggingItemID = nil
    }
    func syncFocus(itemCount: Int) {
        guard itemCount > 0 else {
            focusedIndex = 0
            return
        }
        focusedIndex = min(max(focusedIndex, 0), itemCount - 1)
    }
    func moveLeft(itemCount: Int) {
        guard itemCount > 0 else { return }
        focusedIndex = max(focusedIndex - 1, 0)
    }
    func moveRight(itemCount: Int) {
        guard itemCount > 0 else { return }
        focusedIndex = min(focusedIndex + 1, itemCount - 1)
    }
    func focusItem(at index: Int, itemCount: Int) {
        guard itemCount > 0 else { return }
        focusedIndex = min(max(index, 0), itemCount - 1)
    }
    func showToast(_ message: String, isError: Bool = false) {
        toastTask?.cancel()
        previewItem = nil
        isToastError = isError
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            toastMessage = message
        }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            await MainActor.run {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    self?.toastMessage = nil
                }
            }
        }
    }
    func showPreview(_ item: ClipboardItem) {
        toastTask?.cancel()
        toastMessage = nil
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            previewItem = item
        }
    }
    func hidePreview() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            previewItem = nil
        }
    }
}
struct QuickClipboardStripView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @ObservedObject var controller: QuickClipboardStripController
    @ObservedObject var wardrobeViewModel: WardrobeViewModel
    let onClose: () -> Void
    let onOpenFullApp: (ClipboardItem) -> Void
    let onExpandFullApp: (ClipboardItem) -> Void
    private let cardWidth: CGFloat = 312
    @State private var folderDraft: String = ""
    @State private var folderEditor: StripFolderEditor?
    @State private var targetedFolderID: UUID?
    @State private var confirmedFolderID: UUID?
    @FocusState private var isFolderFieldFocused: Bool
    private var filteredItems: [ClipboardItem] {
        var result = viewModel.activeItems
        if let folderID = controller.selectedFolderID {
            result = result.filter { $0.folderIDs.contains(folderID) }
        }
        if let type = controller.selectedContentType {
            result = result.filter { $0.contentType == type }
        }
        return result
    }
    private var availableContentTypes: [ContentType] {
        let base = controller.selectedFolderID == nil
            ? viewModel.items
            : viewModel.items.filter { item in
                controller.selectedFolderID.map(item.folderIDs.contains) ?? true
            }
        return ContentType.allCases.filter { type in
            base.contains { $0.contentType == type }
        }
    }
    private func itemCount(of type: ContentType) -> Int {
        let base = controller.selectedFolderID == nil
            ? viewModel.items
            : viewModel.items.filter { item in
                controller.selectedFolderID.map(item.folderIDs.contains) ?? true
            }
        return base.filter { $0.contentType == type }.count
    }
    private var selectedFolder: ClipboardFolder? {
        guard let folderID = controller.selectedFolderID else { return nil }
        return viewModel.folders.first(where: { $0.id == folderID })
    }
    private var focusedVisibleItem: ClipboardItem? {
        guard filteredItems.indices.contains(controller.focusedIndex) else { return nil }
        return filteredItems[controller.focusedIndex]
    }
    var body: some View {
        VStack(spacing: 0) {
            folderBar
            if viewModel.psychoCopyManager.isMultiCopyModeActive {
                MultiCopyModeIndicator(
                    manager: viewModel.psychoCopyManager,
                    onPasteNext: {
                        viewModel.performSequentialPaste()
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            ZStack(alignment: .bottom) {
                stripContent
                toastView
                previewView
            }
            .frame(height: 260)
            Divider()
                .background(Theme.divider)
            shortcutBar
        }
        .frame(maxWidth: .infinity)
        .frame(height: viewModel.psychoCopyManager.isMultiCopyModeActive ? 436 : 380)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: viewModel.psychoCopyManager.isMultiCopyModeActive)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    viewModel.psychoCopyManager.isMultiCopyModeActive
                        ? Theme.accent.opacity(0.6)
                        : Theme.border,
                    lineWidth: viewModel.psychoCopyManager.isMultiCopyModeActive ? 1.5 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(
            color: viewModel.psychoCopyManager.isMultiCopyModeActive
                ? Theme.accent.opacity(0.15)
                : Color.black.opacity(0.12),
            radius: viewModel.psychoCopyManager.isMultiCopyModeActive ? 24 : 18,
            y: 8
        )
        .onExitCommand {
            onClose()
        }
        .onChange(of: viewModel.loadError) { _, error in
            guard let error, !error.isEmpty else { return }
            controller.showToast(error, isError: true)
        }
        .onChange(of: viewModel.folders) { _, folders in
            if let selectedFolderID = controller.selectedFolderID,
               !folders.contains(where: { $0.id == selectedFolderID }) {
                controller.selectedFolderID = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AddToWardrobeFromClipboard"))) { notification in
            if let itemID = notification.userInfo?["itemID"] as? UUID,
               let item = viewModel.activeItems.first(where: { $0.id == itemID }) {
                Task {
                    await wardrobeViewModel.addFromClipboardItem(item)
                }
            }
        }
    }
    private var stripContent: some View {
        ScrollViewReader { proxy in
            Group {
                if controller.isWardrobeSelected {
                    WardrobeView(viewModel: wardrobeViewModel, controller: controller)
                } else if filteredItems.isEmpty {
                    emptyState
                } else {
                    stripCardsScroll
                }
            }
            .onAppear {
                let itemCount = controller.isWardrobeSelected ? wardrobeViewModel.items.count : filteredItems.count
                controller.syncFocus(itemCount: itemCount)
                prewarmStripResources()
            }
            .onChange(of: filteredItems.count) { _, newCount in
                if !controller.isWardrobeSelected {
                    controller.syncFocus(itemCount: newCount)
                }
            }
            .onChange(of: wardrobeViewModel.items.count) { _, newCount in
                if controller.isWardrobeSelected {
                    controller.syncFocus(itemCount: newCount)
                }
            }
            .onChange(of: controller.isWardrobeSelected) { _, isWardrobe in
                let itemCount = isWardrobe ? wardrobeViewModel.items.count : filteredItems.count
                controller.syncFocus(itemCount: itemCount)
            }
            .onChange(of: controller.selectedFolderID) { _, _ in
                if !controller.isWardrobeSelected {
                    controller.syncFocus(itemCount: filteredItems.count)
                    prewarmStripResources()
                }
            }
            .onChange(of: controller.selectedContentType) { _, _ in
                if !controller.isWardrobeSelected {
                    controller.syncFocus(itemCount: filteredItems.count)
                    prewarmStripResources()
                }
            }
            .onChange(of: controller.focusedIndex) { _, _ in
                scrollToFocusedCard(using: proxy)
            }
        }
    }
    /// Load the resources most likely to enter the viewport next. The cards
    /// themselves remain unchanged; this only removes icon disk I/O from the
    /// middle of a horizontal trackpad swipe.
    private func prewarmStripResources() {
        let candidates = Array(filteredItems.prefix(18))
        IconCache.shared.prewarmCachedAppIcons(
            bundleIDs: candidates.compactMap(\.sourceAppBundleID)
        )

    }
    private var stripCardsScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .center, spacing: 16) {
                ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                    stripCard(for: item, index: index)
                        .id(item.id)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        // Dropping back in the strip is a cancelled move, not a removal. Consume
        // the internal payload and immediately restore the source card.
        .onDrop(of: [UTType.hetpasteFolderItemIDs], isTargeted: .constant(false)) { providers in
            let isInternalCardDrag = providers.contains {
                $0.hasItemConformingToTypeIdentifier(UTType.hetpasteFolderItemIDs.identifier)
            }
            if isInternalCardDrag {
                controller.endCardDrag()
            }
            return isInternalCardDrag
        }
    }
    private var folderBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                folderChip(
                    title: "All",
                    count: viewModel.activeItems.count,
                    isSelected: controller.selectedFolderID == nil,
                    action: {
                        controller.selectedFolderID = nil
                        controller.hidePreview()
                    }
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.folders) { folder in
                            folderChip(
                                title: folder.name,
                                count: viewModel.itemCount(in: folder),
                                isSelected: controller.selectedFolderID == folder.id,
                                isDropTarget: targetedFolderID == folder.id,
                                confirmsDrop: confirmedFolderID == folder.id,
                                action: {
                                    controller.selectedFolderID = folder.id
                                    controller.hidePreview()
                                }
                            )
                            .onDrop(
                                of: [UTType.hetpasteFolderItemIDs],
                                isTargeted: Binding(
                                    get: { targetedFolderID == folder.id },
                                    set: { targetedFolderID = $0 ? folder.id : nil }
                                )
                            ) { providers in
                                handleFolderDrop(providers: providers, into: folder)
                            }
                            .contextMenu {
                                Button("Rename Folder") {
                                    folderEditor = .renaming(folder.id)
                                    folderDraft = folder.name
                                    isFolderFieldFocused = true
                                }
                                Button("Delete Folder", role: .destructive) {
                                    if controller.selectedFolderID == folder.id {
                                        controller.selectedFolderID = nil
                                    }
                                    viewModel.deleteFolder(folder)
                                    controller.showToast("Deleted folder", isError: false)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                Menu {
                    Button("New Folder") {
                        folderEditor = .creating
                        folderDraft = ""
                        isFolderFieldFocused = true
                    }
                    if let selectedFolder {
                        Divider()
                        Button("Rename Selected Folder") {
                            folderEditor = .renaming(selectedFolder.id)
                            folderDraft = selectedFolder.name
                            isFolderFieldFocused = true
                        }
                        Button("Delete Selected Folder", role: .destructive) {
                            controller.selectedFolderID = nil
                            viewModel.deleteFolder(selectedFolder)
                            controller.showToast("Deleted folder", isError: false)
                        }
                    }
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 0.75)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                typeFilterDropdown
                
                // Wardrobe tab
                wardrobeChip
                
                Divider()
                    .frame(height: 20)
                HStack(spacing: 6) {
                    Text("Sequential Paste")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Toggle("", isOn: Binding(
                        get: { viewModel.psychoCopyManager.isMultiCopyModeActive },
                        set: { newValue in
                            if newValue {
                                viewModel.psychoCopyManager.activateMultiCopyMode()
                            } else {
                                viewModel.psychoCopyManager.deactivateMultiCopyMode()
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .scaleEffect(0.8)
                }
                .help("Enable Sequential Paste")
            }
            if folderEditor != nil {
                HStack(spacing: 8) {
                    TextField(
                        isRenamingSelectedFolder ? "Rename folder" : "Folder name",
                        text: $folderDraft
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 0.75)
                    )
                    .focused($isFolderFieldFocused)
                    .onSubmit(commitFolderEdit)
                    Button("Save") {
                        commitFolderEdit()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.accent)
                    )
                    Button("Cancel") {
                        folderEditor = nil
                        folderDraft = ""
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                }
                .padding(.leading, 2)
            }
            if let error = viewModel.loadError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.red.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(.thinMaterial)
    }
    private func stripCard(for item: ClipboardItem, index: Int) -> some View {
        VStack(spacing: 8) {
            ClipboardItemRow(
                item: item,
                isSelected: controller.focusedIndex == index,
                isMostRecent: item.id == viewModel.activeItems.first?.id,
                stripMode: true,
                onToggleFavorite: { viewModel.toggleFavorite(item) },
                onRetrySync: { viewModel.retrySync(item) },
                onCopy: {
                    restore(item, closesStrip: false)
                },
                onDelete: {
                    viewModel.moveToTrash(item)
                },
                onTrash: {
                    viewModel.moveToTrash(item)
                },
                onExpand: {
                    onExpandFullApp(item)
                },
                onPrimaryTap: {
                    restore(item, closesStrip: true)
                },
                onDoubleTap: {
                    onOpenFullApp(item)
                }
            )
            .frame(width: cardWidth, height: 194)
            .contentShape(Rectangle())
            // Keep the card's slot while it is being dragged, but do not leave a
            // faded duplicate behind. The native drag preview is the card the
            // user is holding.
            .opacity(controller.draggingItemID == item.id ? 0 : 1)
            // Keep the source-card handoff and return in one smooth visual
            // transition instead of a frame-by-frame snap.
            .animation(.easeOut(duration: 0.16), value: controller.draggingItemID)
            .onDrag {
                controller.beginCardDrag(itemID: item.id)
                return viewModel.stripDragItemProvider(for: item)
            } preview: {
                // Use the same card, at the same size, as the strip. Do not add
                // padding, shadows, scaling, or blur to the lifted card.
                ClipboardItemRow(
                    item: item,
                    isSelected: controller.focusedIndex == index,
                    isMostRecent: item.id == viewModel.activeItems.first?.id,
                    stripMode: true,
                    onToggleFavorite: {},
                    onRetrySync: {},
                    onCopy: {},
                    onDelete: {},
                    onExpand: {},
                    onPrimaryTap: {},
                    onDoubleTap: {}
                )
                    // The strip lays this card into a compact 194pt slot, while
                    // the card itself has a taller natural render size. Keep
                    // that natural height in the drag image so none of its
                    // content gets cropped.
                    .frame(width: cardWidth)
                    // NSDragging renders the preview into its layout bounds;
                    // preserve the row's own 24pt outer-card silhouette rather
                    // than letting that snapshot become a rectangle.
                    .clipShape(Rectangle())
            }
            .onAppear {
                if item.contentType == .image || item.contentType == .file || item.contentType == .video {
                    viewModel.loadLocalDataIfNeeded(for: item)
                }
            }
        }
    }
    private var shortcutBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if viewModel.psychoCopyManager.isMultiCopyModeActive {
                    shortcutHint(
                        keys: ["P"],
                        label: "Paste Next",
                        accent: true
                    )
                    shortcutHint(
                        keys: ["⌥", "⌘", "⇧X"],
                        label: "Clear Queue",
                        accent: false
                    )
                    Divider().frame(height: 18)
                }
                shortcutHint(keys: ["1-9"], label: "Copy")
                shortcutHint(keys: ["Option", "1-9"], label: "Plain")
                shortcutHint(keys: ["Return"], label: "Copy")
                shortcutHint(keys: ["Space"], label: "Preview")
                shortcutHint(keys: ["Delete"], label: "Remove")
                shortcutHint(keys: ["F"], label: "Favorite")
                shortcutHint(keys: ["Esc"], label: "Close")
            }
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 22)
        }
        .frame(height: 64)
        .background(.thinMaterial)
    }
    private func shortcutHint(keys: [String], label: String, accent: Bool = false) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(accent ? Theme.accent : Theme.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(accent ? Theme.accent.opacity(0.1) : Theme.card)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(accent ? Theme.accent.opacity(0.4) : Theme.border, lineWidth: 0.5)
                        )
                }
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(accent ? Theme.accent : Theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(accent ? Theme.accent.opacity(0.06) : Theme.bg.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accent ? Theme.accent.opacity(0.3) : Theme.border.opacity(0.7), lineWidth: 0.5)
        )
    }
    private func folderChip(
        title: String,
        count: Int,
        isSelected: Bool,
        isDropTarget: Bool = false,
        confirmsDrop: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .foregroundColor(isSelected ? .white : Theme.textPrimary)
            if title != "All" {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isSelected ? .white : Theme.textSecondary)
            }
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isSelected ? .white.opacity(0.9) : Theme.textSecondary)
                .scaleEffect(confirmsDrop ? 1.15 : 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 32)
        .background(
            Capsule()
                .fill(isSelected || confirmsDrop ? Theme.accent : (isDropTarget ? Theme.accent.opacity(0.16) : Theme.card))
        )
        .overlay(
            Capsule()
                .stroke(isSelected || isDropTarget || confirmsDrop ? Theme.accent : Theme.border, lineWidth: isDropTarget ? 1.5 : 0.75)
        )
        .scaleEffect(isDropTarget ? 1.08 : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.75), value: isDropTarget)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: confirmsDrop)
        .contentShape(Capsule())
        .padding(.vertical, 3)
        .onTapGesture(perform: action)
    }
    @ViewBuilder
    private var typeFilterDropdown: some View {
        if !availableContentTypes.isEmpty {
            Menu {
                Button {
                    controller.selectedContentType = nil
                    controller.hidePreview()
                } label: {
                    Label("All Types", systemImage: "line.3.horizontal.decrease")
                }
                Divider()
                ForEach(availableContentTypes, id: \.self) { type in
                    Button {
                        controller.selectedContentType = type
                        controller.hidePreview()
                    } label: {
                        Label(
                            "\(previewTitle(for: type)) (\(itemCount(of: type)))",
                            systemImage: previewIcon(for: type)
                        )
                    }
                }
            } label: {
                let currentType = controller.selectedContentType
                HStack(spacing: 6) {
                    Image(systemName: currentType.map { previewIcon(for: $0) } ?? "line.3.horizontal.decrease")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(currentType.map { previewTitle(for: $0) } ?? "All Types")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(Theme.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(minHeight: 32)
                .background(
                    Capsule()
                        .fill(Theme.card)
                )
                .overlay(
                    Capsule()
                        .stroke(Theme.border, lineWidth: 0.75)
                )
                .contentShape(Capsule())
                .padding(.vertical, 3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Filter by content type")
        }
    }
    private func previewIcon(for type: ContentType) -> String {
        switch type {
        case .url: return "link"
        case .richText: return "doc.richtext"
        case .file: return "doc"
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .text: return "text.alignleft"
        }
    }
    private func previewTitle(for type: ContentType) -> String {
        switch type {
        case .url: return "Link"
        case .richText: return "Rich Text"
        case .file: return "File"
        case .image: return "Image"
        case .video: return "Video"
        case .text: return "Text"
        }
    }
    
    // MARK: - Wardrobe
    
    private var wardrobeChip: some View {
        Button(action: {
            controller.isWardrobeSelected.toggle()
            if controller.isWardrobeSelected {
                controller.selectedFolderID = nil
                controller.selectedContentType = nil
            }
            controller.hidePreview()
        }) {
            HStack(spacing: 7) {
                Image(systemName: "hanger")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(controller.isWardrobeSelected ? .white : Theme.textPrimary)
                Text("My Wardrobe")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(controller.isWardrobeSelected ? .white : Theme.textPrimary)
                Text("\(wardrobeViewModel.items.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(controller.isWardrobeSelected ? .white.opacity(0.9) : Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .background(
                Capsule()
                    .fill(controller.isWardrobeSelected ? Color.purple : Theme.card)
            )
            .overlay(
                Capsule()
                    .stroke(controller.isWardrobeSelected ? Color.purple : Theme.border, lineWidth: 0.75)
            )
            .contentShape(Capsule())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .help("My Wardrobe — drag items here to save for later")
    }
    
    private var emptyState: some View {
        let iconName: String = controller.selectedContentType != nil
            ? previewIcon(for: controller.selectedContentType!)
            : (selectedFolder == nil ? "tray" : "folder")
        let title: String
        let subtitle: String
        if let type = controller.selectedContentType {
            title = "No \(previewTitle(for: type).lowercased()) items"
            subtitle = selectedFolder == nil
                ? "Copy a \(previewTitle(for: type).lowercased()) and it will appear here."
                : "No \(previewTitle(for: type).lowercased()) items in \(selectedFolder?.name ?? "folder")."
        } else if let folder = selectedFolder {
            title = "No items in \(folder.name)"
            subtitle = "Move items into this folder from the strip or the full app."
        } else {
            title = "No clipboard items yet"
            subtitle = "Copy something and it will appear here."
        }
        return VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
    private var isRenamingSelectedFolder: Bool {
        guard case .renaming(let folderID) = folderEditor else { return false }
        return selectedFolder?.id == folderID
    }
    private func commitFolderEdit() {
        let trimmed = folderDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch folderEditor {
        case .renaming(let folderID):
            if let folder = viewModel.folders.first(where: { $0.id == folderID }) {
                viewModel.renameFolder(folder, name: trimmed)
            }
            controller.showToast("Renamed folder", isError: false)
        case .creating:
            let folder = viewModel.createFolder(named: trimmed.isEmpty ? "Untitled Folder" : trimmed)
            controller.selectedFolderID = folder.id
            controller.showToast("Created folder", isError: false)
        case .none:
            break
        }
        folderEditor = nil
        folderDraft = ""
    }
    private func handleFolderDrop(providers: [NSItemProvider], into folder: ClipboardFolder?) -> Bool {
        // Prefer internal payload when available.
        let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.hetpasteFolderItemIDs.identifier) })
            ?? providers.first
        guard let provider else { return false }
        loadClipboardItemIDs(from: provider) { ids in
            guard !ids.isEmpty else { return }
            if let folder {
                withAnimation(.easeOut(duration: 0.18)) {
                    confirmedFolderID = folder.id
                }
                viewModel.assignItems(ids, to: folder)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                        confirmedFolderID = nil
                    }
                    controller.endCardDrag()
                }
            }
        }
        targetedFolderID = nil
        return true
    }
    private func loadClipboardItemIDs(from provider: NSItemProvider, onLoad: @escaping ([UUID]) -> Void) {
        guard provider.hasItemConformingToTypeIdentifier(UTType.hetpasteFolderItemIDs.identifier) else { return }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.hetpasteFolderItemIDs.identifier) { data, _ in
            guard let data,
                  let raw = String(data: data, encoding: .utf8),
                  !raw.isEmpty else { return }
            let ids = raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty else { return }
            DispatchQueue.main.async { onLoad(ids) }
        }
    }
    @ViewBuilder
    private var toastView: some View {
        if let message = controller.toastMessage {
            HStack(spacing: 7) {
                Image(systemName: controller.isToastError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(controller.isToastError ? Color(hex: "#D32F2F") : Color(hex: "#191919").opacity(0.94))
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
    @ViewBuilder
    private var previewView: some View {
        if let item = controller.previewItem {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: previewIcon(for: item))
                        .font(.system(size: 12, weight: .semibold))
                    Text(previewTitle(for: item))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(Theme.textSecondary)
                Text(item.contentText ?? item.fileName ?? "No preview available")
                    .font(.system(size: item.contentType == .text || item.contentType == .richText || item.contentType == .url ? 13 : 12, design: item.contentType == .url ? .monospaced : .default))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(width: 380)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Theme.border, lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 12, y: 5)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
    private func scrollToFocusedCard(using proxy: ScrollViewProxy) {
        guard viewModel.activeItems.indices.contains(controller.focusedIndex) else { return }
        let item = viewModel.activeItems[controller.focusedIndex]
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(item.id, anchor: .center)
        }
    }
    private func restore(_ item: ClipboardItem, asPlainText: Bool = false, closesStrip: Bool) {
        Task {
            let result = await viewModel.restoreToPasteboard(item, asPlainText: asPlainText)
            controller.showToast(result.message, isError: !result.didCopy)
            if result.didCopy && closesStrip {
                try? await Task.sleep(nanoseconds: 220_000_000)
                await MainActor.run {
                    onClose()
                }
            }
        }
    }
    private func previewIcon(for item: ClipboardItem) -> String {
        switch item.contentType {
        case .url: return "link"
        case .richText: return "doc.richtext"
        case .file: return "doc"
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .text: return "text.alignleft"
        }
    }
    private func previewTitle(for item: ClipboardItem) -> String {
        switch item.contentType {
        case .url: return "URL Preview"
        case .richText: return "Rich Text Preview"
        case .file: return "File Preview"
        case .image: return "Image Preview"
        case .video: return "Video Preview"
        case .text: return "Text Preview"
        }
    }
}
#Preview {
    QuickClipboardStripView(
        viewModel: ClipboardHistoryViewModel(),
        controller: QuickClipboardStripController(),
        wardrobeViewModel: WardrobeViewModel(),
        onClose: {},
        onOpenFullApp: { _ in },
        onExpandFullApp: { _ in }
    )
    .padding(24)
    .background(Theme.bg)
}
struct MultiCopyModeIndicator: View {
    @ObservedObject var manager: PsychoCopyManager
    let onPasteNext: () -> Void
    @State private var isPulsingBadge = false
    @State private var showQueuePopover = false
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 32, height: 32)
                    .scaleEffect(isPulsingBadge ? 1.15 : 1.0)
                    .animation(
                        .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                        value: isPulsingBadge
                    )
                Image(systemName: "square.3.layers.3d.down.forward")
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Sequential Paste Active")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                Text(manager.copyQueue.isEmpty
                     ? "Copy items to add them to the queue"
                     : "\(manager.copyQueue.count) item\(manager.copyQueue.count == 1 ? "" : "s") queued — press P to paste next")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer()
            if !manager.copyQueue.isEmpty {
                Button(action: { showQueuePopover.toggle() }) {
                    HStack(spacing: 5) {
                        Text("\(manager.copyQueue.count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Theme.accent)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Theme.accent.opacity(0.8))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
                .help("View queue")
                .popover(isPresented: $showQueuePopover, arrowEdge: .bottom) {
                    PsychoCopyQueuePopover(manager: manager, onPasteNext: onPasteNext)
                }
            }
            Button(action: onPasteNext) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.right.to.line")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Paste Next")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(Theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(manager.copyQueue.isEmpty ? Color.white.opacity(0.6) : Color.white)
                )
            }
            .buttonStyle(.plain)
            .disabled(manager.copyQueue.isEmpty)
            .help("Paste next queued item (P)")
            Button(action: { manager.deactivateMultiCopyMode() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.white.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.white.opacity(0.3), lineWidth: 0.75)
                    )
            }
            .buttonStyle(.plain)
            .help("Exit Sequential Paste mode")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(Theme.accent)
        )
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.white.opacity(0.15)),
            alignment: .bottom
        )
        .onAppear { isPulsingBadge = true }
    }
}
struct PsychoCopyQueuePopover: View {
    @ObservedObject var manager: PsychoCopyManager
    let onPasteNext: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "square.3.layers.3d.down.forward")
                    .foregroundColor(Theme.accent)
                    .font(.system(size: 12, weight: .semibold))
                Text("Copy Queue")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("\(manager.copyQueue.count) items")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            Divider().background(Theme.divider)
            if manager.copyQueue.preview.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.textTertiary)
                    Text("Queue is empty")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(manager.copyQueue.preview.enumerated()), id: \.element.id) { idx, item in
                            HStack(spacing: 10) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(idx == 0 ? .white : Theme.textSecondary)
                                    .frame(width: 20, height: 20)
                                    .background(
                                        Circle().fill(idx == 0 ? Theme.accent : Theme.selection)
                                    )
                                Image(systemName: queueItemIcon(for: item))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Theme.textSecondary)
                                    .frame(width: 16)
                                Text(item.queuePreviewText())
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                if idx == 0 {
                                    Text("NEXT")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(Theme.accent)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule().fill(Theme.accent.opacity(0.12))
                                        )
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(idx == 0 ? Theme.accent.opacity(0.04) : Color.clear)
                            if idx < manager.copyQueue.preview.count - 1 {
                                Divider().padding(.leading, 44).background(Theme.divider)
                            }
                        }
                        if manager.copyQueue.count > 10 {
                            Text("+ \(manager.copyQueue.count - 10) more")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Theme.textTertiary)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            Divider().background(Theme.divider)
            HStack(spacing: 8) {
                Button(action: onPasteNext) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.to.line")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Paste Next")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(manager.copyQueue.isEmpty ? Theme.accent.opacity(0.4) : Theme.accent)
                    )
                }
                .buttonStyle(.plain)
                .disabled(manager.copyQueue.isEmpty)
                Spacer()
                Button(action: { manager.clearQueue() }) {
                    Text("Clear All")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.red.opacity(0.75))
                }
                .buttonStyle(.plain)
                .disabled(manager.copyQueue.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .background(Theme.bg)
    }
    private func queueItemIcon(for item: ClipboardItem) -> String {
        switch item.contentType {
        case .url: return "link"
        case .richText: return "doc.richtext"
        case .file: return "doc"
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .text: return "text.alignleft"
        }
    }
}
