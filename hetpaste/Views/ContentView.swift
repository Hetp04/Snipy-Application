import SwiftUI
import UniformTypeIdentifiers
enum NavDestination: Equatable {
    case launchpad           
    case history             
    case favorites           
    case chain
    case filteredByApp(String) 
    case filteredByType(ContentType) 
    case folder(ClipboardFolder)
    case trash               
    case settings
}
struct ContentView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @State private var destination: NavDestination = .launchpad
    @State private var showToast: Bool = false
    @State private var copiedAppName: String = ""
    @State private var toastTimer: Timer? = nil
    @State private var isSidebarVisible: Bool = true
    @State private var expandedItem: ClipboardItem? = nil
    
    @State private var isCreatingChain: Bool = false
    @State private var chainSelectedIDs: [UUID] = []
    @State private var showChainOverlay: Bool = false
    @State private var editingChain: Chain? = nil
    @State private var draftChainName: String = ""
    @State private var draftChainItems: [ClipboardItem] = []

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if isCreatingChain {
                    ChainSelectionTopBar(
                        selectedCount: chainSelectedIDs.count,
                        onCancel: {
                            withAnimation {
                                isCreatingChain = false
                                chainSelectedIDs.removeAll()
                                editingChain = nil
                            }
                        },
                        onNext: {
                            if let chain = editingChain {
                                draftChainName = chain.name
                            } else {
                                draftChainName = ""
                            }
                            
                            draftChainItems = chainSelectedIDs.compactMap { id in viewModel.activeItems.first(where: { $0.id == id }) }
                            withAnimation { showChainOverlay = true }
                        }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    Divider().background(Theme.divider)
                }
                
                HStack(spacing: 0) {
                if isSidebarVisible {
                    SidebarView(
                        destination: $destination,
                        onDropToTrash: { id in
                            if let item = viewModel.items.first(where: { $0.id == id }) {
                                viewModel.moveToTrash(item)
                            }
                        }
                    )
                    .transition(.move(edge: .leading))
                    Divider()
                        .background(Theme.divider)
                }
                mainStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: destination)
                }
            }
            .blur(radius: expandedItem != nil || showChainOverlay ? 10 : 0)
            
            if showChainOverlay {
                Color.black.opacity(0.3).ignoresSafeArea()
                    .onTapGesture { showChainOverlay = false }
                
                ChainNamingOverlay(
                    chainName: $draftChainName,
                    items: $draftChainItems,
                    isEditing: editingChain != nil,
                    onCancel: { showChainOverlay = false },
                    onSave: {
                        let finalIDs = draftChainItems.map { $0.id }
                        if let chain = editingChain {
                            viewModel.updateChain(chain, name: draftChainName, snippetIDs: finalIDs)
                        } else {
                            viewModel.createChain(name: draftChainName.isEmpty ? "Untitled Chain" : draftChainName, snippetIDs: finalIDs)
                        }
                        showChainOverlay = false
                        isCreatingChain = false
                        chainSelectedIDs.removeAll()
                        destination = .chain
                    }
                )
                .frame(width: 800, height: 600)
                .background(Theme.bg)
                .cornerRadius(12)
                .shadow(radius: 20)
                .zIndex(100)
            }
            if let item = expandedItem {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            expandedItem = nil
                        }
                    }
                ClipboardItemRow(
                    item: item,
                    isExpanded: true,
                    onExpand: {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            expandedItem = nil
                        }
                    }
                )
                .frame(width: 700, height: 600)
                .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 15)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .zIndex(100)
            }
            if showToast {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Copied from \(copiedAppName)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color(hex: "191919").opacity(0.95))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 10, y: 5)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .zIndex(1)
            }
        }
        .frame(
            minWidth: 900, idealWidth: 900, maxWidth: .infinity,
            minHeight: 640, idealHeight: 640, maxHeight: .infinity
        )
        .background(Theme.bg)
        .onChange(of: viewModel.focusedItemID) { _, focusedID in
            guard focusedID != nil else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                destination = .history
            }
        }
        .onChange(of: viewModel.expandedItemID) { _, expandedID in
            guard let expandedID = expandedID,
                  let item = viewModel.items.first(where: { $0.id == expandedID }) else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                expandedItem = item
                destination = .history
            }
        }
        .onAppear {
            viewModel.handleRemoteCloudChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            viewModel.handleRemoteCloudChange()
        }
    }
    @ViewBuilder
    private var mainStage: some View {
        switch destination {
        case .launchpad:
            LaunchpadView(
                items: viewModel.items,
                onSelectApp: { selectedApp in
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    if let app = selectedApp {
                        destination = .filteredByApp(app)
                    } else {
                        destination = .history
                    }
                }
            },
                onSelectCategory: { type in
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        destination = .filteredByType(type)
                    }
                }
            )
        case .history:
            ClipboardFeedView(
                viewModel: viewModel,
                preFilteredApp: nil,
                showFavoritesOnly: false,
                onItemCopy: triggerCopyToast,
                onLaunchpadTap: { destination = .launchpad },
                onSelectFolder: { folder in destination = .folder(folder) },
                onExpandItem: { item in
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        expandedItem = item
                    }
                },
                isChainSelectionMode: isCreatingChain,
                chainSelectedIDs: $chainSelectedIDs
            )
        case .favorites:
            ClipboardFeedView(
                viewModel: viewModel,
                preFilteredApp: nil,
                showFavoritesOnly: true,
                onItemCopy: triggerCopyToast,
                onLaunchpadTap: { destination = .launchpad },
                onExpandItem: { item in
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        expandedItem = item
                    }
                },
                isChainSelectionMode: isCreatingChain,
                chainSelectedIDs: $chainSelectedIDs
            )
        case .chain:
            ChainView(
                viewModel: viewModel,
                onItemCopy: triggerCopyToast,
                onCreateChain: {
                    withAnimation {
                        isCreatingChain = true
                        destination = .history
                    }
                },
                onEditChain: { chain in
                    editingChain = chain
                    chainSelectedIDs = viewModel.activeItems(for: chain).map { $0.id }
                    
                    withAnimation {
                        isCreatingChain = true
                        destination = .history
                    }
                }
            )
        case .filteredByApp(let appName):
            ClipboardFeedView(
                viewModel: viewModel,
                preFilteredApp: appName,
                preFilteredType: nil,
                showFavoritesOnly: false,
                onItemCopy: triggerCopyToast,
                onLaunchpadTap: { destination = .launchpad },
                onExpandItem: { item in
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        expandedItem = item
                    }
                },
                isChainSelectionMode: isCreatingChain,
                chainSelectedIDs: $chainSelectedIDs
            )
        case .filteredByType(let type):
            ClipboardFeedView(
                viewModel: viewModel,
                preFilteredApp: nil,
                preFilteredType: type,
                showFavoritesOnly: false,
                onItemCopy: triggerCopyToast,
                onLaunchpadTap: { destination = .launchpad },
                onExpandItem: { item in
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        expandedItem = item
                    }
                },
                isChainSelectionMode: isCreatingChain,
                chainSelectedIDs: $chainSelectedIDs
            )
        case .folder(let folder):
            ClipboardFeedView(
                viewModel: viewModel,
                selectedFolder: folder,
                showFavoritesOnly: false,
                onItemCopy: triggerCopyToast,
                onLaunchpadTap: { destination = .launchpad },
                onBackToHistory: { destination = .history },
                onExpandItem: { item in
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        expandedItem = item
                    }
                },
                isChainSelectionMode: isCreatingChain,
                chainSelectedIDs: $chainSelectedIDs
            )
        case .trash:
            TrashView(
                viewModel: viewModel,
                onExpandItem: { item in
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        expandedItem = item
                    }
                }
            )
        case .settings:
            SettingsView(manager: viewModel.psychoCopyManager, viewModel: viewModel)
        }
    }
    @ViewBuilder
    private func placeholderView(title: String, icon: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(Theme.textTertiary)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            Text("Coming soon")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
    }
    private func triggerCopyToast(for item: ClipboardItem) {
        copiedAppName = item.sourceAppName
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            showToast = true
        }
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showToast = false
            }
        }
    }
}
struct ClipboardFeedView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    var preFilteredApp: String? = nil      
    var preFilteredType: ContentType? = nil
    var selectedFolder: ClipboardFolder? = nil
    var showFavoritesOnly: Bool = false
    let onItemCopy: (ClipboardItem) -> Void
    var onLaunchpadTap: (() -> Void)? = nil
    var onSelectFolder: ((ClipboardFolder) -> Void)? = nil
    var onBackToHistory: (() -> Void)? = nil
    var onExpandItem: ((ClipboardItem) -> Void)? = nil
    var isChainSelectionMode: Bool = false
    var chainSelectedIDs: Binding<[UUID]>? = nil
    
    private var allItems: [ClipboardItem] { viewModel.activeItems }
    @State private var search = ClipboardSearchQuery()
    @State private var searchInputTask: Task<Void, Never>?
    @State private var showsAdvancedSearch = false
    @State private var advancedApps: Set<String> = []
    @State private var advancedCategories: Set<ContentCategory> = []
    @State private var advancedDateFilter: ClipboardDateFilter? = nil
    @State private var customSelectedDate: Date? = nil
    @State private var showsAppFilter = false
    @State private var showsTypeFilter = false
    @State private var showsDateFilter = false
    @State private var isCustomCalendarViewActive = false
    @State private var selectedItemID: UUID? = nil
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var draggingItemIDs: Set<UUID> = []
    @State private var absorbedItemIDs: Set<UUID> = []
    @State private var editingFolderID: UUID? = nil
    @State private var editingFolderName: String = ""
    @State private var folderToast: String?
    @State private var isGridView: Bool = true
    @State private var shouldFocusSearch: Bool = false
    
    var layoutColumns: [GridItem] {
        if isGridView {
            return [
                // Fixed three-column grids make cards too narrow as soon as
                // the sidebar or a smaller window reduces the available width.
                // Let SwiftUI choose one, two, or three readable card columns.
                // Compact tiles keep the visual rhythm of the original square
                // layout. The adaptive grid adds/removes tiles as space changes
                // instead of stretching two cards across a wide window.
                GridItem(.adaptive(minimum: 210, maximum: 240), spacing: 16)
            ]
        } else {
            return [
                GridItem(.flexible(minimum: 0), spacing: 16)
            ]
        }
    }
    var filteredItems: [ClipboardItem] {
        var result = search.text.isEmpty ? allItems : viewModel.semanticSearchResults
        result = result.filter(search.matches)
        if !advancedApps.isEmpty { result = result.filter { advancedApps.contains($0.sourceAppName) } }
        if !advancedCategories.isEmpty { result = result.filter { advancedCategories.contains(ContentCategory.detect(from: $0)) } }
        if let advancedDateFilter {
            result = result.filter { advancedDateFilter.contains($0.createdAt) }
        } else if let customSelectedDate {
            result = result.filter { Calendar.current.isDate($0.createdAt, inSameDayAs: customSelectedDate) }
        }
        if showFavoritesOnly {
            result = result.filter { $0.isPinned }
        }
        if let selectedFolder {
            result = result.filter { $0.folderIDs.contains(selectedFolder.id) }
        }
        if let app = preFilteredApp {
            result = result.filter { $0.sourceAppName.lowercased() == app.lowercased() }
        }
        if let type = preFilteredType {
            result = result.filter { $0.contentType == type }
        }
        return result
    }
    var mostRecentID: UUID? { filteredItems.first?.id }
    var todayItems:     [ClipboardItem] { filteredItems.filter { Calendar.current.isDateInToday($0.createdAt) } }
    var yesterdayItems: [ClipboardItem] { filteredItems.filter { Calendar.current.isDateInYesterday($0.createdAt) } }
    var thisWeekItems: [ClipboardItem] {
        let cal = Calendar.current
        let startOfWeek = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return filteredItems.filter { 
            !cal.isDateInToday($0.createdAt) &&
            !cal.isDateInYesterday($0.createdAt) &&
            $0.createdAt >= startOfWeek
        }
    }
    var olderItems: [ClipboardItem] {
        let cal = Calendar.current
        let startOfWeek = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return filteredItems.filter { 
            $0.createdAt < startOfWeek
        }
    }
    private var feedTitle: String {
        if showFavoritesOnly { return "Favorites" }
        if let selectedFolder { return selectedFolder.name }
        if let type = preFilteredType {
            switch type {
            case .url: return "Links"
            case .image: return "Images"
            case .video: return "Videos"
            case .file: return "Files"
            case .text: return "Code Snippets"
            case .richText: return "Rich Text"
            }
        }
        if let app = preFilteredApp { return app }
        return "All History"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    if selectedFolder != nil {
                        Button(action: { onBackToHistory?() }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(Theme.textSecondary)
                                .frame(width: 26, height: 26)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color(hex: "#F7F7F5"))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Back to All History")
                    }
                    Text(feedTitle)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    HStack(spacing: 8) {
                        // Slider toggle for List/Grid
                        HStack(spacing: 0) {
                            Button(action: { withAnimation { isGridView = false } }) {
                                Image(systemName: "list.bullet")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(!isGridView ? Theme.accent : Theme.textTertiary)
                                    .frame(width: 32, height: 26)
                                    .background(
                                        !isGridView ? Capsule().fill(Color(hex: "#F6F6F6")).softOuterShadow(darkShadow: Color(hex: "#A3B1C6").opacity(0.4), lightShadow: Color.white, offset: 2, radius: 4) : nil
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("List view")
                            
                            Button(action: { withAnimation { isGridView = true } }) {
                                Image(systemName: "square.grid.2x2")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(isGridView ? Theme.accent : Theme.textTertiary)
                                    .frame(width: 32, height: 26)
                                    .background(
                                        isGridView ? Capsule().fill(Color(hex: "#F6F6F6")).softOuterShadow(darkShadow: Color(hex: "#A3B1C6").opacity(0.4), lightShadow: Color.white, offset: 2, radius: 4) : nil
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Grid view")
                        }
                        .padding(3)
                        .background(
                            Capsule()
                                .fill(Color(hex: "#F6F6F6"))
                                .softInnerShadow(Capsule(), darkShadow: Color(hex: "#A3B1C6").opacity(0.6), lightShadow: Color.white, spread: 0.15, radius: 6)
                        )
                    }
                }
                SearchBarView(query: $search, shouldFocus: $shouldFocusSearch, showsAdvanced: $showsAdvancedSearch, items: allItems, folders: viewModel.folders)
                    .onChange(of: search.text) { _, query in scheduleTextSearch(query) }
                if showsAdvancedSearch {
                    advancedSearchControls.transition(.opacity.combined(with: .move(edge: .top)))
                }
                if viewModel.isSearching {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Thinking…") }
                        .font(.system(size: 11, weight: .medium)).foregroundColor(Theme.textTertiary)
                        .padding(.top, 2)
                } else if let error = viewModel.searchError, !search.text.isEmpty {
                    Text(error).font(.system(size: 11, weight: .medium)).foregroundColor(.red.opacity(0.8)).padding(.top, 2)
                }
                if let selectedID = selectedItemID, let item = allItems.first(where: { $0.id == selectedID }), item.sourceAppName.lowercased() == "finder" {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.textTertiary)
                        Text(path(for: item))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.05))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .zIndex(10)
            Divider().background(Theme.divider)
            ScrollView {
                if viewModel.isLoading && allItems.isEmpty {
                    VStack(spacing: 12) {
                        Spacer().frame(height: 80)
                        ProgressView()
                        Text("Loading from iCloud…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                } else if let error = viewModel.loadError, allItems.isEmpty {
                    VStack(spacing: 12) {
                        Spacer().frame(height: 80)
                        Image(systemName: "exclamationmark.icloud")
                            .font(.system(size: 32))
                            .foregroundColor(Theme.textTertiary)
                        Text("Couldn't load history")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity)
                } else if filteredItems.isEmpty {
                    VStack(spacing: 12) {
                        Spacer().frame(height: 80)
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 32))
                            .foregroundColor(Theme.textTertiary)
                        Text(search.isActive ? "Nothing found" : "Nothing copied yet")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Theme.textTertiary)
                        Text(search.isActive ? "Try different text or remove a filter." : "Copy something and it'll show up here.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        if shouldShowFolders {
                            folderSection
                        }
                        if search.isActive || !advancedApps.isEmpty || !advancedCategories.isEmpty {
                            gridSection("Results", items: filteredItems)
                        } else {
                            if !todayItems.isEmpty     { gridSection("Today",     items: todayItems) }
                            if !yesterdayItems.isEmpty { gridSection("Yesterday", items: yesterdayItems) }
                            if !thisWeekItems.isEmpty  { gridSection("This Week", items: thisWeekItems) }
                            if !olderItems.isEmpty     { gridSection("Older",     items: olderItems) }
                            if selectedFolder == nil, !showFavoritesOnly, preFilteredApp == nil, preFilteredType == nil {
                                loadMoreFooter
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            .zIndex(0)
        }
        .background(Theme.bg)
        .onAppear {
            selectedItemID = viewModel.focusedItemID
        }
        .onChange(of: viewModel.focusedItemID) { _, focusedID in
            guard let focusedID else { return }
            selectedItemID = focusedID
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusClipboardSearch)) { _ in
            shouldFocusSearch = true
        }
        .onDisappear { searchInputTask?.cancel() }
    }

    /// Autocomplete is calculated directly from the current input, while the
    /// card grid waits a moment before touching the local index. This avoids
    /// JSON decoding and a grid redraw for every individual key event.
    private func scheduleTextSearch(_ query: String) {
        searchInputTask?.cancel()
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.search(query: "")
            return
        }
        searchInputTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                viewModel.search(query: query)
            } catch is CancellationError {
                // Expected while the user continues typing.
            } catch {
                // Sleeping cannot otherwise fail; leave the current results intact.
            }
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if viewModel.hasMoreCachedItems || viewModel.isLoadingMoreItems {
            HStack(spacing: 8) {
                if viewModel.isLoadingMoreItems { ProgressView().controlSize(.small) }
                Text(viewModel.isLoadingMoreItems ? "Loading older cards…" : "Load older cards")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .id(viewModel.items.last?.id)
            .onAppear { viewModel.loadMoreItemsIfNeeded() }
        }
    }
    private var shouldShowFolders: Bool {
        selectedFolder == nil &&
        preFilteredApp == nil &&
        preFilteredType == nil &&
        !showFavoritesOnly &&
        !search.isActive &&
        advancedApps.isEmpty &&
        advancedCategories.isEmpty &&
        advancedDateFilter == nil &&
        customSelectedDate == nil
    }
    private var availableAdvancedApps: [(name: String, bundleID: String?)] {
        let grouped = Dictionary(grouping: allItems, by: \ClipboardItem.sourceAppName)
        return grouped.map { name, items in (name, items.compactMap(\.sourceAppBundleID).first) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var searchableCategories: [ContentCategory] {
        [.text, .url, .image, .file, .code, .color, .email, .phone, .richText, .video]
    }
    private var dateFilterTitle: String {
        if let advancedDateFilter {
            return "Date · \(advancedDateFilter.rawValue)"
        } else if let customSelectedDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return "Date · \(formatter.string(from: customSelectedDate))"
        }
        return "Date"
    }
    private var isDateFilterActive: Bool {
        advancedDateFilter != nil || customSelectedDate != nil
    }
    private var advancedSearchControls: some View {
        HStack(spacing: 8) {
            advancedFilterButton(title: advancedApps.isEmpty ? "Apps" : "Apps · \(advancedApps.count)", icon: "app.fill", isActive: !advancedApps.isEmpty) {
                showsAppFilter.toggle()
            }
            .popover(isPresented: $showsAppFilter, arrowEdge: .bottom) { appFilterPopover }
            
            advancedFilterButton(title: advancedCategories.isEmpty ? "Types" : "Types · \(advancedCategories.count)", icon: "square.grid.2x2.fill", isActive: !advancedCategories.isEmpty) {
                showsTypeFilter.toggle()
            }
            .popover(isPresented: $showsTypeFilter, arrowEdge: .bottom) { typeFilterPopover }
            
            advancedFilterButton(title: dateFilterTitle, icon: "calendar", isActive: isDateFilterActive) {
                showsDateFilter.toggle()
            }
            .popover(isPresented: $showsDateFilter, arrowEdge: .bottom) { dateFilterPopover }
            
            if !advancedApps.isEmpty || !advancedCategories.isEmpty || isDateFilterActive {
                Button("Clear filters") {
                    advancedApps.removeAll()
                    advancedCategories.removeAll()
                    advancedDateFilter = nil
                    customSelectedDate = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 2).padding(.top, -3)
    }
    private func advancedFilterButton(title: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold)).foregroundColor(isActive ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(isActive ? Theme.accent.opacity(0.09) : Theme.card))
            .overlay(Capsule().stroke(isActive ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 0.75))
        }.buttonStyle(.plain)
    }
    private var appFilterPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterPopoverHeader("Filter by apps", selectedCount: advancedApps.count) { advancedApps.removeAll() }
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(availableAdvancedApps, id: \.name) { app in
                        let selected = advancedApps.contains(app.name)
                        Button { if selected { advancedApps.remove(app.name) } else { advancedApps.insert(app.name) } } label: {
                            HStack(spacing: 10) {
                                if let id = app.bundleID, let icon = IconCache.shared.resolveAppIcon(bundleID: id) {
                                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 18, height: 18)
                                } else { Image(systemName: "app.fill").font(.system(size: 12, weight: .semibold)).frame(width: 18, height: 18) }
                                Text(app.name).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.textPrimary).lineLimit(1)
                                Spacer(); checkmark(selected)
                            }.padding(.horizontal, 10).frame(height: 34)
                                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent.opacity(0.08) : Color.clear))
                        }.buttonStyle(.plain)
                    }
                }.padding(6)
            }.frame(height: min(CGFloat(availableAdvancedApps.count) * 34 + 12, 260))
        }.frame(width: 270).background(Theme.bg)
    }
    private var typeFilterPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterPopoverHeader("Filter by type", selectedCount: advancedCategories.count) { advancedCategories.removeAll() }
            Divider()
            VStack(spacing: 2) {
                ForEach(searchableCategories, id: \.self) { category in
                    let selected = advancedCategories.contains(category)
                    Button { if selected { advancedCategories.remove(category) } else { advancedCategories.insert(category) } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: ClipboardSearchToken.category(category).icon).font(.system(size: 12, weight: .semibold)).frame(width: 18)
                            Text(category.searchFilterTitle).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.textPrimary)
                            Spacer(); checkmark(selected)
                        }.padding(.horizontal, 10).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent.opacity(0.08) : Color.clear))
                    }.buttonStyle(.plain)
                }
            }.padding(6)
        }.frame(width: 240).background(Theme.bg)
    }
    private var primaryDateFilters: [ClipboardDateFilter] {
        [.today, .yesterday, .last7Days, .thisMonth]
    }
    private var dateFilterPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isCustomCalendarViewActive {
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isCustomCalendarViewActive = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .bold))
                            Text("Back")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    Text("Select Date")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    
                    Spacer()
                    
                    if customSelectedDate != nil {
                        Button("Clear") {
                            customSelectedDate = nil
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.accent)
                    } else {
                        Text("Clear")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.clear)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                
                Divider()
                
                SleekCalendarView(selectedDate: $customSelectedDate) { _ in
                    advancedDateFilter = nil
                }
                .padding(8)
            } else {
                filterPopoverHeader("Filter by date", selectedCount: isDateFilterActive ? 1 : 0) {
                    advancedDateFilter = nil
                    customSelectedDate = nil
                }
                Divider()
                
                VStack(spacing: 3) {
                    ForEach(primaryDateFilters) { filter in
                        let selected = advancedDateFilter == filter && customSelectedDate == nil
                        Button {
                            if selected {
                                advancedDateFilter = nil
                            } else {
                                advancedDateFilter = filter
                                customSelectedDate = nil
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: filter.icon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 18)
                                    .foregroundColor(selected ? Theme.accent : Theme.textSecondary)
                                Text(filter.rawValue)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                Spacer()
                                checkmark(selected)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent.opacity(0.08) : Color.clear))
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Divider().padding(.vertical, 4)
                    
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isCustomCalendarViewActive = true
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 18)
                                .foregroundColor(customSelectedDate != nil ? Theme.accent : Theme.textSecondary)
                            
                            Text(customSelectedDate.map { date in
                                let formatter = DateFormatter()
                                formatter.dateStyle = .medium
                                return formatter.string(from: date)
                            } ?? "Custom Date…")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(customSelectedDate != nil ? Theme.accent : Theme.textPrimary)
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Theme.textTertiary)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(customSelectedDate != nil ? Theme.accent.opacity(0.08) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(6)
            }
        }
        .frame(width: 250)
        .background(Theme.bg)
    }
    private func filterPopoverHeader(_ title: String, selectedCount: Int, onClear: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textPrimary)
            Spacer()
            if selectedCount > 0 { Button("Clear") { onClear() }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.accent) }
        }.padding(.horizontal, 14).frame(height: 42)
    }
    private func checkmark(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 15, weight: .semibold)).foregroundColor(selected ? Theme.accent : Theme.border)
    }
    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Folders")
            if let error = viewModel.loadError {
                Text("Folder sync error: \(error)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.red.opacity(0.82))
                    .padding(.horizontal, 2)
            }
            LazyVGrid(columns: layoutColumns, spacing: 16) {
                ForEach(viewModel.folders) { folder in
                    FolderCardView(
                        folder: folder,
                        itemCount: viewModel.itemCount(in: folder),
                        isEditing: editingFolderID == folder.id,
                        editingName: $editingFolderName,
                        onOpen: { onSelectFolder?(folder) },
                        onBeginRename: {
                            editingFolderID = folder.id
                            editingFolderName = folder.name
                        },
                        onCommitRename: {
                            viewModel.renameFolder(folder, name: editingFolderName)
                            editingFolderID = nil
                        },
                        onDelete: {
                            viewModel.deleteFolder(folder)
                        },
                        onDropItems: { itemIDs in
                            draggingItemIDs = []   // successful drop — clear immediately
                            viewModel.assignItems(itemIDs, to: folder)
                        }
                    )
                }
                NewFolderCardView {
                    let folder = viewModel.createFolder()
                    editingFolderID = folder.id
                    editingFolderName = folder.name
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let folderToast {
                Text(folderToast)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: "#191919").opacity(0.94)))
                    .padding(.bottom, -8)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                self.folderToast = nil
                            }
                        }
                    }
            }
        }
    }
    @ViewBuilder
    private func gridSection(_ title: String, items: [ClipboardItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title)
            LazyVGrid(columns: layoutColumns, spacing: 16) {
                ForEach(items) { item in
                    gridItemRow(item)
                }
            }
        }
    }
    private func gridItemRow(_ item: ClipboardItem) -> some View {
        let freshItem = viewModel.items.first(where: { $0.id == item.id }) ?? item
        return Group {
            if isChainSelectionMode, let chainBinding = chainSelectedIDs {
                let isSelectedForChain = chainBinding.wrappedValue.contains(freshItem.id)
                ClipboardItemRow(
                    item: freshItem,
                    isSelected: isSelectedForChain,
                    isMostRecent: false,
                    onToggleFavorite: {},
                    onRetrySync: {},
                    onCopy: { toggleChainSelection(freshItem.id, binding: chainBinding) },
                    onDelete: {},
                    onTrash: {},
                    onExpand: {},
                    onPrimaryTap: { toggleChainSelection(freshItem.id, binding: chainBinding) }
                )
            } else {
                ClipboardItemRow(
                    item: freshItem,
                    isSelected: selectedItemID == freshItem.id,
                    isMostRecent: freshItem.id == mostRecentID,
                    onToggleFavorite: { viewModel.toggleFavorite(freshItem) },
                    onRetrySync: { viewModel.retrySync(freshItem) },
                    onCopy: {
                        selectedItemID = freshItem.id
                        viewModel.copyToPasteboard(freshItem)
                        onItemCopy(freshItem)
                    },
                    onDelete: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            if let selectedFolder {
                                viewModel.removeFromFolder(freshItem, folderID: selectedFolder.id)
                            } else {
                                viewModel.deleteItem(freshItem)
                            }
                        }
                    },
                    onTrash: { viewModel.moveToTrash(freshItem) },
                    onExpand: { onExpandItem?(freshItem) },
                    onPrimaryTap: {
                        selectedItemID = freshItem.id
                        selectedItemIDs = [freshItem.id]
                        viewModel.copyToPasteboard(freshItem)
                        onItemCopy(freshItem)
                    },
                    isAssetLoading: viewModel.assetLoadingIDs.contains(freshItem.id),
                    assetLoadError: viewModel.assetLoadError(for: freshItem.id),
                    onRetryAssetDownload: { viewModel.retryAssetDownload(for: freshItem) },
                    onOpenOCRViewer: freshItem.contentType == .image ? {
                        ImageTextViewerWindowManager.shared.open(item: freshItem, viewModel: viewModel)
                    } : nil,
                    onSaveContent: { id, contentText, rtfData, htmlData, rtfdData in
                        Task {
                            do {
                                try await viewModel.updateItemContent(
                                    id: id,
                                    contentText: contentText,
                                    rtfData: rtfData,
                                    htmlData: htmlData,
                                    rtfdData: rtfdData
                                )
                            } catch {
                                print("Failed to save content: \(error)")
                            }
                        }
                    }
                )
                .opacity(draggingItemIDs.contains(freshItem.id) ? 0.35 : 1)
                .animation(.easeOut(duration: 0.16), value: draggingItemIDs)
                .onDrag {
                    let ids = selectedItemIDs.contains(freshItem.id) ? Array(selectedItemIDs) : [freshItem.id]
                    draggingItemIDs = Set(ids)
                    // No explicit drag-end callback in SwiftUI onDrag — reset after
                    // a generous timeout so it reappears if the drag is cancelled.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { draggingItemIDs = [] }
                    return viewModel.folderDragItemProvider(for: ids)
                } preview: {
                    dragPreview(for: freshItem)
                }
                .onAppear {
                    // Existing cards created before the thumbnail feature are
                    // migrated automatically in a throttled background queue.
                    viewModel.prepareImageThumbnailIfNeeded(for: freshItem)
                }
            }
        }
    }
    
    /// A deliberately smaller snapshot used as the cursor-following drag image,
    /// distinct from the full-size card left behind in the grid.
    @ViewBuilder
    private func dragPreview(for item: ClipboardItem) -> some View {
        ClipboardItemRow(
            item: item,
            isSelected: selectedItemID == item.id,
            isMostRecent: item.id == mostRecentID,
            onToggleFavorite: {},
            onRetrySync: {},
            onCopy: {},
            onDelete: {},
            onTrash: {},
            onExpand: {}
        )
        .frame(width: 260)
        .scaleEffect(0.5, anchor: .center)
        .shadow(color: .black.opacity(0.24), radius: 18, y: 10)
        .padding(28)
    }
    private func toggleChainSelection(_ id: UUID, binding: Binding<[UUID]>) {
        var ids = binding.wrappedValue
        if let idx = ids.firstIndex(of: id) {
            ids.remove(at: idx)
        } else {
            ids.append(id)
        }
        binding.wrappedValue = ids
    }
    private func path(for item: ClipboardItem) -> String {
        if let url = item.revealableFileURL {
            return url.path
        }
        if item.contentType == .url, let text = item.contentText, URL(string: text) != nil {
            return text
        }
        if let storagePath = item.storagePath {
            return storagePath
        }
        if let text = item.contentText {
            let truncated = String(text.prefix(50)).replacingOccurrences(of: "\n", with: " ")
            return "\(item.sourceAppName) • \(truncated)..."
        }
        return item.sourceAppName
    }
}
struct FolderCardView: View {
    let folder: ClipboardFolder
    let itemCount: Int
    let isEditing: Bool
    @Binding var editingName: String
    let onOpen: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onDelete: () -> Void
    let onDropItems: ([UUID]) -> Void
    @State private var isTargeted: Bool = false
    @State private var confirmsDrop: Bool = false
    @State private var countScale: CGFloat = 1
    @FocusState private var isNameFocused: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(Color(hex: "#3A3A3C"))
            if isEditing {
                TextField("Folder name", text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(hex: "#1C1C1E"))
                    .focused($isNameFocused)
                    .onSubmit(onCommitRename)
            } else {
                Text(folder.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(hex: "#1C1C1E"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Text("\(itemCount)")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.textSecondary)
                .scaleEffect(countScale)
            Button {
                onBeginRename()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(hex: "#3A3A3C"))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Rename", action: onBeginRename)
                Button("Delete Folder", role: .destructive, action: onDelete)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(Theme.selection))
        .scaleEffect(isTargeted ? 1.08 : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.75), value: isTargeted)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing {
                onOpen()
            }
        }
        .contextMenu {
            Button("Rename", action: onBeginRename)
            Button("Delete Folder", role: .destructive, action: onDelete)
        }

        .onAppear {
            if isEditing {
                isNameFocused = true
            }
        }
        .onDrop(of: [UTType.hetpasteFolderItemIDs], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            handleDrop(provider: provider)
            return true
        }
        .onChange(of: isEditing) { _, newValue in
            isNameFocused = newValue
        }
    }
    private func handleDrop(provider: NSItemProvider) {
        guard provider.hasItemConformingToTypeIdentifier(UTType.hetpasteFolderItemIDs.identifier) else { return }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.hetpasteFolderItemIDs.identifier) { data, _ in
            guard let data,
                  let raw = String(data: data, encoding: .utf8),
                  !raw.isEmpty else { return }
            let ids = raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty else { return }
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.18)) {
                    confirmsDrop = true
                    countScale = 1.15
                }
                onDropItems(ids)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                        confirmsDrop = false
                        countScale = 1
                    }
                }
            }
        }
    }
}
struct NewFolderCardView: View {
    let onCreate: () -> Void
    var body: some View {
        Button(action: onCreate) {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Color(hex: "#3A3A3C"))
                Text("New Folder")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(hex: "#1C1C1E"))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Rectangle().fill(Theme.selection))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(Theme.textTertiary)
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.leading, 2)
    }
}

// MARK: - Chain UI Components

struct ChainSelectionTopBar: View {
    let selectedCount: Int
    let onCancel: () -> Void
    let onNext: () -> Void
    
    var body: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text("\(selectedCount) selected")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            if selectedCount >= 2 {
                Button("Next →", action: onNext)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.accent)
            } else {
                Text("Select ≥2")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(hex: "#F6F6F6").shadow(color: .black.opacity(0.05), radius: 3, y: 2))
    }
}

struct ChainItemDropDelegate: DropDelegate {
    let item: ClipboardItem
    @Binding var items: [ClipboardItem]
    @Binding var draggedItem: ClipboardItem?
    
    func dropEntered(info: DropInfo) {
        guard let draggedItem = draggedItem,
              draggedItem.id != item.id,
              let from = items.firstIndex(where: { $0.id == draggedItem.id }),
              let to = items.firstIndex(where: { $0.id == item.id }) else { return }
        
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            items.swapAt(from, to)
        }
    }
    
    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        return true
    }
}

struct ChainNamingOverlay: View {
    @Binding var chainName: String
    @Binding var items: [ClipboardItem]
    let isEditing: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    
    @State private var isGalleryMode = false
    @State private var draggedItem: ClipboardItem?
    
    let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 16)
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textSecondary)
                
                Spacer()
                Text(isEditing ? "Edit Chain" : "Save Chain").font(.headline)
                Spacer()
                Button(isEditing ? "Save Changes" : "Save", action: onSave)
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.accent)
                    .font(.headline)
            }
            .padding(16)
            Divider()
            
            VStack(alignment: .leading, spacing: 16) {
                if isEditing {
                    Text(chainName)
                        .font(.system(size: 24, weight: .bold))
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                } else {
                    TextField("Chain Name", text: $chainName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 24, weight: .bold))
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                }
                
                HStack {
                    Text("Drag to reorder snippets")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                    Spacer()
                    
                    // View Toggle
                    HStack(spacing: 0) {
                        Button(action: { isGalleryMode = false }) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 13, weight: isGalleryMode ? .regular : .semibold))
                                .foregroundColor(isGalleryMode ? Theme.textSecondary : .white)
                                .frame(width: 32, height: 26)
                                .background(isGalleryMode ? Color.clear : Color(hex: "#2C2C2E"))
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: { isGalleryMode = true }) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 13, weight: isGalleryMode ? .semibold : .regular))
                                .foregroundColor(isGalleryMode ? .white : Theme.textSecondary)
                                .frame(width: 32, height: 26)
                                .background(isGalleryMode ? Color(hex: "#2C2C2E") : Color.clear)
                        }
                        .buttonStyle(.plain)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                }
                .padding(.horizontal, 20)
                
                if !isGalleryMode {
                    List {
                        ForEach(items) { item in
                            HStack {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundColor(Theme.textTertiary)
                                Text(item.previewText ?? "Item")
                                    .lineLimit(1)
                                    .font(.system(size: 13))
                                Spacer()
                                Button(action: {
                                    withAnimation {
                                        items.removeAll { $0.id == item.id }
                                    }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(Theme.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 8)
                            .listRowBackground(Color.clear)
                        }
                        .onMove { indices, newOffset in
                            items.move(fromOffsets: indices, toOffset: newOffset)
                        }
                    }
                    .listStyle(.plain)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ZStack(alignment: .topLeading) {
                                    ClipboardItemRow(item: item, isSelected: false)
                                        .allowsHitTesting(false) // Disable inner buttons while ordering
                                        .opacity(draggedItem?.id == item.id ? 0.3 : 1.0)
                                        .scaleEffect(draggedItem?.id == item.id ? 0.95 : 1.0)
                                    
                                    // Transparent overlay to catch drag gestures covering the whole bounds
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onDrag {
                                            draggedItem = item
                                            return NSItemProvider(object: item.id.uuidString as NSString)
                                        }
                                        .onDrop(of: [UTType.text], delegate: ChainItemDropDelegate(item: item, items: $items, draggedItem: $draggedItem))
                                    
                                    // Sequence Badge
                                    Text("\(index + 1)")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white)
                                        .frame(width: 24, height: 24)
                                        .background(Theme.accent)
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                        .offset(x: -8, y: -8)
                                        .zIndex(1)
                                        
                                    // Remove Button
                                    Button(action: {
                                        withAnimation {
                                            items.removeAll { $0.id == item.id }
                                        }
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(Theme.textSecondary)
                                            .background(Color.white.clipShape(Circle()))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 8, y: -8)
                                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                                    .zIndex(2)
                                }
                            }
                        }
                        .padding(20)
                    }
                }
            }
        }
    }
}
struct SleekCalendarView: View {
    @Binding var selectedDate: Date?
    var onSelect: (Date) -> Void
    
    @State private var currentMonth: Date = Date()
    private let calendar = Calendar.current
    
    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: currentMonth)
    }
    
    private var daysInMonth: [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: currentMonth) else {
            return []
        }
        
        let startWeekday = calendar.component(.weekday, from: monthInterval.start) // 1 = Sunday
        var days: [Date?] = Array(repeating: nil, count: startWeekday - 1)
        
        var date = monthInterval.start
        while date < monthInterval.end {
            days.append(date)
            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = nextDate
        }
        return days
    }
    
    private let weekdaySymbols = ["S", "M", "T", "W", "T", "F", "S"]
    
    var body: some View {
        VStack(spacing: 8) {
            // Month Header with Nav Arrows
            HStack {
                Text(monthYearString)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                
                Spacer()
                
                Button {
                    if let prevMonth = calendar.date(byAdding: .month, value: -1, to: currentMonth) {
                        currentMonth = prevMonth
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black.opacity(0.04)))
                }
                .buttonStyle(.plain)
                
                Button {
                    if let nextMonth = calendar.date(byAdding: .month, value: 1, to: currentMonth) {
                        currentMonth = nextMonth
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black.opacity(0.04)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            
            // Weekday symbols
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { idx in
                    Text(weekdaySymbols[idx])
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 2)
            
            // Days Grid
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(0..<daysInMonth.count, id: \.self) { index in
                    if let dayDate = daysInMonth[index] {
                        let dayNumber = calendar.component(.day, from: dayDate)
                        let isSelected = selectedDate.map { calendar.isDate($0, inSameDayAs: dayDate) } ?? false
                        let isToday = calendar.isDateInToday(dayDate)
                        
                        Button {
                            selectedDate = dayDate
                            onSelect(dayDate)
                        } label: {
                            Text("\(dayNumber)")
                                .font(.system(size: 11, weight: isSelected ? .bold : (isToday ? .semibold : .regular)))
                                .foregroundColor(isSelected ? .white : (isToday ? Theme.accent : Theme.textPrimary))
                                .frame(width: 26, height: 26)
                                .background(
                                    Circle()
                                        .fill(isSelected ? Theme.accent : (isToday ? Theme.accent.opacity(0.12) : Color.clear))
                                )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 26, height: 26)
                    }
                }
            }
        }
        .padding(4)
        .onAppear {
            if let selectedDate {
                currentMonth = selectedDate
            }
        }
    }
}

#Preview {
    ContentView(viewModel: ClipboardHistoryViewModel())
}
