import AppKit
import CloudKit
import Combine
import Foundation
import UniformTypeIdentifiers
extension UTType {
    static let hetpasteFolderItemIDs = UTType(exportedAs: "com.hetpaste.folder-item-ids")
    static let hetpasteWardrobeItemID = UTType(exportedAs: "com.hetpaste.wardrobe-item-id")
}
struct ClipboardRestoreResult {
    let didCopy: Bool
    let message: String
}
enum CloudSyncState: Equatable {
    case idle, syncing, offline, failed(String)
    var title: String {
        switch self {
        case .idle: return "iCloud synced"
        case .syncing: return "Syncing with iCloud…"
        case .offline: return "Offline — changes will retry"
        case .failed: return "iCloud needs attention"
        }
    }
}
@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    var trashedItems: [ClipboardItem] { items.filter { $0.isDeleted } }
    var activeItems: [ClipboardItem] { items.filter { !$0.isDeleted } }
    @Published private(set) var folders: [ClipboardFolder] = []
    @Published private(set) var chains: [Chain] = []
    @Published private(set) var chainItems: [UUID: [ChainItem]] = [:]
    @Published private(set) var isLoading: Bool = false
    @Published var loadError: String?
    @Published var focusedItemID: UUID?
    @Published var expandedItemID: UUID?
    @Published private(set) var semanticSearchResults: [ClipboardItem] = []
    @Published private(set) var isSearching = false
    @Published var searchError: String?
    @Published private(set) var cloudSyncState: CloudSyncState = .syncing
    @Published private(set) var cloudDiagnostics = CloudSyncDiagnostics.shared
    @Published private(set) var assetLoadingIDs: Set<UUID> = []
    @Published private(set) var assetLoadErrors: [UUID: String] = [:]
    @Published private(set) var isClipboardCapturePaused = false
    @Published private(set) var isDeletingClipboardHistory = false
    @Published private(set) var clipboardHistoryDeletionProgress = 0
    @Published var psychoCopyManager: PsychoCopyManager
    // Keep CloudKit construction lazy. XCTest launches the app as the test
    // host before the test bundle is connected, and unsigned test hosts must
    // never attempt to create a CloudKit container.
    private lazy var service = ClipboardService()
    private lazy var repository = ClipboardRepository()
    private var pendingFolderIDs: Set<UUID> = []
    private var pendingItemIDs: Set<UUID> = []
    private var searchTask: Task<Void, Never>?
    private var activeSearchID = UUID()
    private var pendingDeletionIDs: Set<UUID> = []
    private var pendingFolderDeletionIDs: Set<UUID> = []
    private var pendingChainIDs: Set<UUID> = []
    private var pendingChainDeletionIDs: Set<UUID> = []
    private var pendingUploadQueue: [ClipboardItem] = []
    private var isUploadQueueRunning = false
    private var thumbnailBackfillAttemptedIDs: Set<UUID> = []
    private var retryTask: Task<Void, Never>?
    private var metadataPersistenceTask: Task<Void, Never>?
    private var automaticSyncTask: Task<Void, Never>?
    private var coalescedSyncTask: Task<Void, Never>?
    private var followUpRemoteSyncRequested = false
    private var hasCompletedInitialCloudLoad = false
    private var clipboardCaptureStateCancellable: AnyCancellable?

    private let retryNotBeforeKey = "cloudkit.retry-not-before"
    private let quotaRetryAttemptKey = "cloudkit.quota-retry-attempt"
    private let initialPageSize = 80
    private let automaticSyncInterval: Duration = .seconds(30)
    @Published private(set) var hasMoreCachedItems = false
    @Published private(set) var isLoadingMoreItems = false
    init() {
        self.psychoCopyManager = PsychoCopyManager()
        if RuntimeEnvironment.isRunningUnitTests || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return
        }
        psychoCopyManager.onGlobalPasteRequested = { [weak self] in
            guard let self = self else { return }
            self.performSequentialPaste()
        }
        psychoCopyManager.onGlobalReversePasteRequested = { [weak self] in
            guard let self = self else { return }
            self.performReverseSequentialPaste()
        }
        NotificationCenter.default.addObserver(
            forName: PsychoCopyManager.modeChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.service.captureRawTypes = self.psychoCopyManager.isMultiCopyModeActive
            }
        }
        service.onNewItems = { [weak self] items in
            Task { @MainActor in self?.handleNewItems(items) }
        }
        NetworkReachability.shared.start()
        NotificationCenter.default.addObserver(
            forName: .hetpasteNetworkBecameAvailable,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // CloudKit's explicit Retry-After window is still respected by
                // loadHistory; this only retries immediately for ordinary loss of
                // connectivity when the path comes back.
                if case .failed = self.cloudSyncState {
                    Task { await self.loadHistory() }
                } else {
                    self.handleRemoteCloudChange()
                }
            }
        }
        isClipboardCapturePaused = service.isCapturePaused
        clipboardCaptureStateCancellable = service.$isCapturePaused
            .receive(on: RunLoop.main)
            .sink { [weak self] isPaused in
                self?.isClipboardCapturePaused = isPaused
            }
        service.start()
        handleRemoteCloudChange()
        startAutomaticSyncLoop()
    }

    deinit {
        automaticSyncTask?.cancel()
        coalescedSyncTask?.cancel()
        retryTask?.cancel()
        metadataPersistenceTask?.cancel()
    }

    /// CloudKit subscriptions are the fast path. This modest fallback keeps a
    /// running menu-bar app convergent even if macOS coalesces or delays a push
    /// notification, without polling while the device is offline.
    private func startAutomaticSyncLoop() {
        automaticSyncTask?.cancel()
        automaticSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.automaticSyncInterval ?? .seconds(30))
                guard !Task.isCancelled, let self else { return }
                guard NetworkReachability.shared.isOnline else { continue }
                self.handleRemoteCloudChange()
            }
        }
    }

    func toggleClipboardCapturePaused() {
        service.toggleCapturePaused()
    }

    func clipboardHistoryCount(in range: ClipboardHistoryRange) -> Int {
        LibraryMetadataStore.shared.historyItemCount(in: range)
    }

    func deleteClipboardHistory(in range: ClipboardHistoryRange) async throws -> Int {
        guard !isDeletingClipboardHistory else { return 0 }
        isDeletingClipboardHistory = true
        clipboardHistoryDeletionProgress = 0
        defer { isDeletingClipboardHistory = false }

        let localMatches = LibraryMetadataStore.shared.historyItemIDs(in: range)
        do {
            _ = try await repository.deleteHistory(in: range) { [weak self] count in
                Task { @MainActor [weak self] in
                    self?.clipboardHistoryDeletionProgress = count
                }
            }
            removePermanentlyDeletedHistoryItems(localMatches)
            loadError = nil
            return localMatches.count
        } catch let partial as ClipboardHistoryDeletionFailure {
            // CloudKit non-atomic batches can partly succeed. Remove only the
            // IDs confirmed deleted and leave every failed item available for
            // a later retry instead of pretending the whole request worked.
            removePermanentlyDeletedHistoryItems(partial.deletedItemIDs)
            handleCloudFailure(partial.underlyingError)
            throw partial
        } catch {
            handleCloudFailure(error)
            throw error
        }
    }

    func clipboardHistoryDeletionMessage(for error: Error) -> String {
        let underlying = (error as? ClipboardHistoryDeletionFailure)?.underlyingError ?? error
        return specificCloudErrorMessage(underlying)
            ?? "Clipboard history couldn’t be deleted from iCloud. Please try again when you’re connected."
    }

    private func removePermanentlyDeletedHistoryItems(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        metadataPersistenceTask?.cancel()
        items.removeAll { ids.contains($0.id) }
        pendingItemIDs.subtract(ids)
        pendingDeletionIDs.subtract(ids)
        LibraryMetadataStore.shared.remove(items: ids)
        for id in ids {
            AssetCache.shared.remove(for: id)
            AssetCache.shared.removeRichPayload(for: id)
            FileAccessStore.shared.remove(for: id)
        }
        reloadVisibleLibraryPage()
        persistLibraryCache(immediately: true)
    }

    func loadHistory() async {
        let cached = LibraryMetadataStore.shared.loadInitial(itemLimit: initialPageSize)
        items = cached.items
        folders = cached.folders
        chains = cached.chains
        chainItems = cached.chainItems
        pendingItemIDs = cached.queues.pendingItemIDs
        pendingFolderIDs = cached.queues.pendingFolderIDs
        pendingDeletionIDs = cached.queues.pendingDeletionIDs
        pendingFolderDeletionIDs = cached.queues.pendingFolderDeletionIDs
        pendingChainIDs = cached.queues.pendingChainIDs
        pendingChainDeletionIDs = cached.queues.pendingChainDeletionIDs
        hasMoreCachedItems = cached.hasMoreItems
        hydrateVisibleFileReferences()
        updateDiagnostics()
        if let retryNotBefore = UserDefaults.standard.object(forKey: retryNotBeforeKey) as? Date,
           retryNotBefore > Date() {
            cloudSyncState = .offline
            scheduleRetry(at: retryNotBefore)
            return
        }
        isLoading = true
        cloudSyncState = .syncing
        loadError = nil
        do {
            let accountIdentifier = try await CloudKitManager.shared.currentAccountIdentifier()
            if LibraryMetadataStore.shared.resetIfAccountChanged(to: accountIdentifier) {
                CloudKitManager.shared.discardChangeToken()
                items = []; folders = []; chains = []; chainItems = [:]
            }
            if LibraryMetadataStore.shared.needsInitialRemoteBootstrap() {
                // One small, sorted request gets the newest cards on screen
                // immediately. The following token-based import fills history
                // in batches without delaying that first useful view.
                let recent = try await repository.fetchRecent(limit: initialPageSize)
                LibraryMetadataStore.shared.upsert(items: recent)
                LibraryMetadataStore.shared.markInitialRemoteBootstrapComplete()
                reloadVisibleLibraryPage()
            }
            // CloudKit returns only records since the persisted zone token.
            // On a new device it streams the initial zone in server batches;
            // on every later launch it normally writes only a small delta.
            let delta = try await LibrarySyncCoordinator.shared.sync()
            refreshPendingQueuesFromStore()
            reloadVisibleLibraryPage()
            startEmbeddingBackfill()
            persistLibraryCache()
            await retryQueuedChanges()
            // Resumable transfers retain their local source after a crash.
            // Only states whose source is gone are safe to reclaim here.
            await repository.cleanupAbandonedChunkTransfers()
            CloudSyncDiagnostics.shared.recordSuccess(source: "macOS foreground delta", delta: delta)
            hasCompletedInitialCloudLoad = true
            if pendingItemIDs.isEmpty,
               pendingFolderIDs.isEmpty,
               pendingDeletionIDs.isEmpty,
               pendingFolderDeletionIDs.isEmpty,
               pendingChainIDs.isEmpty,
               pendingChainDeletionIDs.isEmpty {
                UserDefaults.standard.removeObject(forKey: quotaRetryAttemptKey)
            }
        } catch {
            loadError = cloudErrorMessage(error)
            cloudSyncState = isTransientCloudError(error) ? .offline : .failed(cloudErrorMessage(error))
            handleCloudFailure(error)
        }
        if loadError == nil { cloudSyncState = .idle }
        isLoading = false
    }

    func syncNow() {
        // Explicit user intent may bypass a previously scheduled backoff.
        UserDefaults.standard.removeObject(forKey: retryNotBeforeKey)
        handleRemoteCloudChange()
    }

    private func reloadVisibleLibraryPage() {
        let local = LibraryMetadataStore.shared.loadInitial(itemLimit: initialPageSize)
        let pendingVisibleItems = items.filter { pendingItemIDs.contains($0.id) }
        var merged = Dictionary(uniqueKeysWithValues: local.items.map { ($0.id, $0) })
        for item in pendingVisibleItems { merged[item.id] = item }
        items = merged.values.sorted { $0.createdAt > $1.createdAt }
        folders = mergeFolders(local.folders)
        chains = local.chains
        chainItems = local.chainItems
        hasMoreCachedItems = local.hasMoreItems
        hydrateVisibleFileReferences()
    }

    private func refreshPendingQueuesFromStore() {
        let queues = LibraryMetadataStore.shared.loadInitial(itemLimit: 0).queues
        pendingItemIDs = queues.pendingItemIDs
        pendingFolderIDs = queues.pendingFolderIDs
        pendingDeletionIDs = queues.pendingDeletionIDs
        pendingFolderDeletionIDs = queues.pendingFolderDeletionIDs
        pendingChainIDs = queues.pendingChainIDs
        pendingChainDeletionIDs = queues.pendingChainDeletionIDs
    }

    /// Appends one bounded metadata page from the local index. CloudKit is not
    /// contacted while scrolling, so months of history do not delay the grid.
    func loadMoreItemsIfNeeded() {
        guard hasMoreCachedItems, !isLoadingMoreItems else { return }
        isLoadingMoreItems = true
        let cursor = items.last?.createdAt
        let cursorID = items.last?.id
        let page = LibraryMetadataStore.shared.loadItems(olderThan: cursor, afterID: cursorID, limit: initialPageSize)
        let known = Set(items.map(\.id))
        let additions = page.filter { !known.contains($0.id) }
        items.append(contentsOf: additions)
        items.sort { $0.createdAt > $1.createdAt }
        hydrateVisibleFileReferences()
        hasMoreCachedItems = page.count == initialPageSize
        isLoadingMoreItems = false
    }

    private func hydrateVisibleFileReferences() {
        for index in items.indices where items[index].contentType == .file || items[index].contentType == .image || items[index].contentType == .video {
            guard items[index].originalFileURL == nil,
                  let url = FileAccessStore.shared.resolve(for: items[index].id)
            else { continue }
            items[index].originalFileURL = url
            if IconCache.shared.cachedFileIcon(forItemId: items[index].id) == nil {
                IconCache.shared.saveFileIcon(IconCache.shared.fileIcon(for: url), forItemId: items[index].id)
            }
        }
    }
    func handleRemoteCloudChange() {
        if isLoading || coalescedSyncTask != nil {
            // Do not start concurrent CloudKit fetches. Preserve the event so
            // a tiny token-based catch-up runs immediately after the current
            // merge completes.
            followUpRemoteSyncRequested = true
            return
        }
        coalescedSyncTask = Task { [weak self] in
            guard let self else { return }
            if self.hasCompletedInitialCloudLoad { await self.syncRemoteDeltaOnly() }
            else { await self.loadHistory() }
            self.coalescedSyncTask = nil
            if self.followUpRemoteSyncRequested {
                self.followUpRemoteSyncRequested = false
                self.handleRemoteCloudChange()
            }
        }
    }
    /// The periodic fallback must be cheap when there is nothing new. It only
    /// advances the zone token and reloads visible UI when CloudKit reports a
    /// real record change; bootstrap, embeddings, and transfer cleanup remain
    /// in the full initial-load path.
    private func syncRemoteDeltaOnly() async {
        do {
            let delta = try await LibrarySyncCoordinator.shared.sync()
            if delta.hasChanges {
                let applyStartedAt = Date()
                reloadVisibleLibraryPage(); persistLibraryCache()
                CloudSyncDiagnostics.shared.recordUIApply(duration: Date().timeIntervalSince(applyStartedAt))
            }
            CloudSyncDiagnostics.shared.recordSuccess(source: "macOS fallback delta", delta: delta)
        } catch {
            CloudSyncDiagnostics.shared.recordFailure(error)
        }
    }
    
    private func loadChains() async {
        do {
            let fetchedChains = try await repository.fetchChains()
            var itemsDict: [UUID: [ChainItem]] = [:]
            for chain in fetchedChains {
                let items = try await repository.fetchChainItems(chainID: chain.id)
                itemsDict[chain.id] = items
            }
            self.chains = fetchedChains
            self.chainItems = itemsDict
        } catch {
            print("Failed to load chains: \(error)")
        }
    }
    private func handleNewItems(_ newItems: [ClipboardItem]) {
        var itemsToInsert = [ClipboardItem]()
        
        for item in newItems {
            if let first = items.first,
               first.contentType == item.contentType,
               first.contentText == item.contentText,
               item.localData == nil {
                continue
            }
            psychoCopyManager.handleClipboardChange(item)
            if let data = item.localData {
                AssetCache.shared.setProtected(true, for: item.id)
                AssetCache.shared.store(data, for: item.id)
                if item.contentType == .image { ThumbnailCache.shared.createAndStore(from: data, for: item.id) }
            }
            itemsToInsert.append(item)
            pendingItemIDs.insert(item.id)
        }
        
        guard !itemsToInsert.isEmpty else { return }
        
        // Single batch update for UI & Disk
        items.insert(contentsOf: itemsToInsert, at: 0)
        persistLibraryCache()
        
        for item in itemsToInsert {
            if item.contentType == .image, item.localData != nil {
                updateItem(id: item.id) { $0.ocrStatus = .pending }
                triggerOCRInBackground(for: item.id)
            }
        }
        
        // Queue items for upload to prevent concurrently bombarding CloudKit
        pendingUploadQueue.append(contentsOf: itemsToInsert)
        processUploadQueue()
    }
    
    private func processUploadQueue() {
        guard !isUploadQueueRunning else { return }
        isUploadQueueRunning = true
        Task(priority: .utility) {
            while !self.pendingUploadQueue.isEmpty {
                // Upload batch sequentially but up to 3 at once
                let batch = Array(self.pendingUploadQueue.prefix(3))
                await MainActor.run {
                    self.pendingUploadQueue.removeFirst(batch.count)
                }
                
                await withTaskGroup(of: Void.self) { group in
                    for item in batch {
                        group.addTask {
                            if await self.sync(item) {
                                await MainActor.run { self.indexInBackground(item) }
                            }
                        }
                    }
                }
            }
            await MainActor.run { self.isUploadQueueRunning = false }
        }
    }
    /// Public: trigger OCR for an existing item (e.g. opened in viewer before OCR ran)
    func triggerOCRIfNeeded(for item: ClipboardItem) {
        guard item.contentType == .image,
              item.ocrStatus != .done,
              item.localData != nil
        else { return }
        updateItem(id: item.id) { $0.ocrStatus = .pending }
        triggerOCRInBackground(for: item.id)
    }
    private func triggerOCRInBackground(for itemID: UUID) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let data: Data? = await MainActor.run {
                self.items.first(where: { $0.id == itemID })?.localData
            }
            guard let data, let image = NSImage(data: data) else {
                await MainActor.run { self.updateItem(id: itemID) { $0.ocrStatus = .failed } }
                return
            }

            // ── Pass 1: Apple Vision (local, instant, private) ────────────
            var visionText: String = ""
            var visionBoxes: [OCRBox] = []
            do {
                visionBoxes = try await OCRService.shared.recognizeText(in: image)
                visionText  = visionBoxes.map(\.text).joined(separator: " ")
                print("[OCR] Vision found \(visionText.count) chars")
            } catch {
                print("[OCR] Vision failed: \(error.localizedDescription)")
            }

            // ── Pass 2: OpenAI fallback (fires only when Vision is poor) ──
            // Threshold: < 20 chars means Vision found essentially nothing useful.
            let needsFallback = visionText.trimmingCharacters(in: .whitespaces).count < 20
            var finalText = visionText
            
            print("[OCR] Needs fallback: \(needsFallback), Vision chars: \(visionText.count)")

            if needsFallback {
                let isConfigured = await OpenAIOCRService.shared.isConfigured
                print("[OCR] OpenAI configured: \(isConfigured)")
                
                if isConfigured {
                    print("[OCR] Vision result poor (\(visionText.count) chars) — trying OpenAI fallback")
                    do {
                        let aiText = try await OpenAIOCRService.shared.extractText(fromData: data)
                        if !aiText.isEmpty {
                            finalText = aiText
                            print("[OCR] OpenAI succeeded: \(aiText.count) chars")
                        } else {
                            print("[OCR] OpenAI returned empty text")
                        }
                    } catch {
                        print("[OpenAI-OCR] Fallback failed: \(error.localizedDescription)")
                    }
                } else {
                    print("[OCR] Vision poor but OpenAI not configured — no fallback")
                }
            }
            
            let finalOCRText = finalText
            await MainActor.run {
                self.updateItem(id: itemID) {
                    if finalOCRText.trimmingCharacters(in: .whitespaces).isEmpty {
                        $0.ocrStatus = .none
                    } else {
                        $0.ocrText = finalOCRText
                        $0.ocrStatus = .done
                    }
                }
            }
        }
    }
    @discardableResult
    private func sync(_ item: ClipboardItem) async -> Bool {
        do {
            var uploadItem = item
            if uploadItem.appIconData == nil, let bundleID = item.sourceAppBundleID, !bundleID.isEmpty {
                uploadItem.appIconData = IconCache.shared.appIconPNGData(bundleID: bundleID)
            }
            // A binary card reloads as metadata after a relaunch. Its durable
            // AssetCache source lets an interrupted chunk transfer resume.
            if uploadItem.localData == nil, let cached = AssetCache.shared.data(for: item.id) {
                uploadItem.localData = cached
            }
            // Folders are presented and restored as Finder folders, but iCloud
            // requires a byte payload. Older folder cards predate the hidden
            // archive payload added during capture, so create it on Retry too.
            if uploadItem.mimeType == "inode/directory",
               uploadItem.localData == nil,
               let folderURL = uploadItem.revealableFileURL ?? uploadItem.originalFileURL {
                uploadItem.localData = folderArchiveData(for: folderURL)
            }
            let saved = try await repository.save(uploadItem)
            updateItem(id: item.id, touchModifiedAt: false) {
                $0.syncStatus = .synced
                $0.storagePath = saved.storagePath
            }
            AssetCache.shared.setProtected(false, for: item.id)
            pendingItemIDs.remove(item.id)
            persistLibraryCache()
            return true
        } catch let conflict as ClipboardContentConflictError {
            preserveContentConflict(conflict)
            return false
        } catch {
            updateItem(id: item.id, touchModifiedAt: false) { $0.syncStatus = .failed }
            pendingItemIDs.insert(item.id)
            persistLibraryCache()
            cloudSyncState = isTransientCloudError(error) ? .offline : .failed(error.localizedDescription)
            handleCloudFailure(error)
            print("❌ Clipboard iCloud save error: \(error.localizedDescription)")
            return false
        }
    }

    private func folderArchiveData(for directory: URL) -> Data? {
        let didStartAccessing = directory.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { directory.stopAccessingSecurityScopedResource() }
        }
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("hetpaste-folder-retry-\(UUID().uuidString)")
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

    private func preserveContentConflict(_ conflict: ClipboardContentConflictError) {
        var localCopy = conflict.local
        localCopy.id = UUID()
        localCopy.createdAt = Date()
        localCopy.updatedAt = localCopy.createdAt
        localCopy.sourceAppName = "\(localCopy.sourceAppName) — Conflict Copy"
        localCopy.syncStatus = .pending

        if let index = items.firstIndex(where: { $0.id == conflict.server.id }) {
            items[index] = conflict.server
        }
        LibraryMetadataStore.shared.upsert(items: [conflict.server])
        items.append(localCopy)
        pendingItemIDs.remove(conflict.server.id)
        pendingItemIDs.insert(localCopy.id)
        persistLibraryCache(immediately: true)
        loadError = "Another device edited this card first. Your edit was preserved as a Conflict Copy."
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            await self?.retryQueuedChanges()
        }
    }

    private func indexInBackground(_ item: ClipboardItem) {
        Task { [weak self] in
            guard let self else { return }
            await self.index(item)
        }
    }

    private func index(_ item: ClipboardItem) async {
        guard PrivacySettings.shared.allowsExternalAI else {
            updateItem(id: item.id) { $0.embeddingStatus = "disabled" }
            return
        }
        updateItem(id: item.id) { $0.embeddingStatus = "pending" }
        do {
            // Index literal content first. It makes exact identifiers searchable
            // even while the richer contextual representation is still running.
            let rawVector = try await EmbeddingService.shared.embedWithRetry(item.rawSearchableText)
            try await repository.updateEmbeddings(id: item.id, rawVector: rawVector, memoryVector: nil, status: "pending")
            updateItem(id: item.id) { $0.rawEmbedding = rawVector }
            let sourceHash = CardUnderstandingService.shared.sourceHash(for: item)
            let context: String
            if let cached = try await repository.cachedSearchContext(sourceHash: sourceHash) {
                context = cached
                #if DEBUG
                print("[Clipboard Search] card understanding | reused cached context")
                #endif
            } else {
                context = try await CardUnderstandingService.shared.understandWithRetry(item)
            }
            try await repository.updateSearchContext(id: item.id, context: context, sourceHash: sourceHash)
            updateItem(id: item.id) { $0.searchContext = context; $0.contextSourceHash = sourceHash }
            guard let currentItem = items.first(where: { $0.id == item.id }) else { return }
            let vector = try await EmbeddingService.shared.embedWithRetry(currentItem.searchableText)
            try await repository.updateEmbeddings(id: item.id, rawVector: rawVector, memoryVector: vector, status: "done")
            updateItem(id: item.id) { $0.embedding = vector; $0.embeddingStatus = "done" }
        } catch is CancellationError { return }
        catch {
            #if DEBUG
            print("[Clipboard Search] indexing failed | id=\(item.id) | error=\(error.localizedDescription)")
            #endif
            // Preserve a successfully stored raw vector and retry temporary
            // provider failures on the next backfill instead of abandoning it.
            try? await repository.updateEmbeddingStatus(id: item.id, status: "pending")
            updateItem(id: item.id) { $0.embeddingStatus = "pending" }
        }
    }

    private func startEmbeddingBackfill() {
        Task { [weak self] in
            guard let self else { return }
            guard PrivacySettings.shared.allowsExternalAI else { return }
            guard let pending = try? await repository.fetchItemsNeedingEmbeddings() else { return }
            // A complete history may contain thousands of cards. Keep a small,
            // bounded number of AI requests in flight so indexing is useful
            // without overwhelming the API or unexpectedly spiking spend.
            await withTaskGroup(of: Void.self) { group in
                var iterator = pending.makeIterator()
                for _ in 0..<3 {
                    guard let item = iterator.next() else { break }
                    group.addTask { await self.index(item) }
                }
                while await group.next() != nil {
                    guard !Task.isCancelled, let item = iterator.next() else { continue }
                    group.addTask { await self.index(item) }
                }
            }
        }
    }

    /// Debounced semantic search. Cancellation is an expected control-flow path.
    func search(query: String) {
        searchTask?.cancel()
        let searchID = UUID()
        activeSearchID = searchID
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchError = nil
        if trimmed.isEmpty { isSearching = false; semanticSearchResults = []; return }
        // Search results are set by a background SQLite read below. Clearing
        // stale results prevents a previous query from being filtered/rendered
        // while the user is entering the next one.
        semanticSearchResults = []
        isSearching = false
        searchTask = Task { [weak self] in
            do {
                let literalResults = await Task.detached(priority: .userInitiated) {
                    return LibraryMetadataStore.shared.searchItems(matching: trimmed)
                }.value
                guard !Task.isCancelled, self?.activeSearchID == searchID else { return }
                self?.semanticSearchResults = literalResults

                guard PrivacySettings.shared.allowsExternalAI, self?.shouldRefineSearch(trimmed) == true else { return }
                // Do not start expensive semantic work until the user has
                // paused. New input cancels this task before any request is made.
                try await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled, self?.activeSearchID == searchID else { return }
                self?.isSearching = true
                let intentAnalysis: SearchIntentAnalysis
                do {
                    intentAnalysis = try await SearchIntentService.shared.analyze(trimmed)
                } catch {
                    intentAnalysis = SearchIntentAnalysis(semanticQuery: trimmed, matchMode: "all_in_one", retrievalQueries: [trimmed], logic: "A result must match the complete request.", requiredConstraints: [], exclusions: [], relatedConcepts: [], searchPhrases: [])
                    #if DEBUG
                    print("[Clipboard Search] intent analysis unavailable; using original request. Error: \(error.localizedDescription)")
                    #endif
                }
                let retrievalQueries = intentAnalysis.retrievalQueries.isEmpty ? [trimmed] : intentAnalysis.retrievalQueries
                var queryVectors: [([Double], String)] = []
                for retrievalQuery in retrievalQueries {
                    // Planner prose dilutes embedding retrieval with generic
                    // words such as "intent" and "constraint". Embed the
                    // actual focused request instead.
                    queryVectors.append((try await EmbeddingService.shared.embedWithRetry(retrievalQuery, interactive: true), retrievalQuery))
                }
                guard !Task.isCancelled else { return }
                var mergedHits: [UUID: SemanticSearchHit] = [:]
                for (vector, retrievalQuery) in queryVectors {
                    let hits = try await self?.repository.hybridSearch(vector: vector, rawQuery: retrievalQuery, limit: 40) ?? []
                    for hit in hits where hit.similarity > (mergedHits[hit.id]?.similarity ?? -.infinity) {
                        mergedHits[hit.id] = hit
                    }
                }
                let hits = mergedHits.values.sorted { $0.similarity > $1.similarity }
                guard !Task.isCancelled else { return }
                let candidates = await MainActor.run { [weak self] in
                    self?.rerankSearchResults(query: trimmed, semanticHits: hits) ?? []
                }
                let rerankCandidates = candidates.map {
                    SearchRerankCandidate(id: $0.id, rawContent: $0.rawSearchableText, derivedContext: $0.searchContext, sourceApp: $0.sourceAppName, createdAt: $0.createdAt)
                }
                let aiDecisions: [SearchRerankDecision]?
                do {
                    aiDecisions = try await SearchReranker.shared.rerank(query: "\(trimmed)\n\nInterpreted intent:\n\(intentAnalysis.retrievalText)", candidates: rerankCandidates)
                    #if DEBUG
                    print("[Clipboard Search] AI reranker selected \(aiDecisions?.count ?? 0) of \(rerankCandidates.count) candidates")
                    for decision in aiDecisions ?? [] {
                        print("[Clipboard Search] evidence | id=\(decision.id) confidence=\(String(format: "%.2f", decision.confidence)) \(decision.evidence.debugDescription)")
                    }
                    #endif
                } catch {
                    aiDecisions = nil
                    #if DEBUG
                    print("[Clipboard Search] AI reranker unavailable; using semantic fallback. Error: \(error.localizedDescription)")
                    #endif
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.activeSearchID == searchID else { return }
                    let results = self.applyAIReranking(aiDecisions, to: candidates)
                    self.logSearchDebug(query: trimmed, vectorDimensions: queryVectors.first?.0.count ?? 0, semanticHits: hits, finalResults: results)
                    self.semanticSearchResults = results
                    self.isSearching = false
                }
            } catch is CancellationError { /* typing cancelled the prior request; do nothing */ }
            catch {
                await MainActor.run { [weak self] in
                    guard let self, self.activeSearchID == searchID else { return }
                    #if DEBUG
                    print("[Clipboard Search] FAILED | query=\(trimmed.debugDescription) | error=\(error.localizedDescription)")
                    #endif
                    self.isSearching = false
                    self.searchError = error.localizedDescription
                }
            }
        }
    }

    /// Single words and short fragments are best served by the local index.
    /// Semantic retrieval is reserved for an actual natural-language request.
    private func shouldRefineSearch(_ query: String) -> Bool {
        let wordCount = query.split(whereSeparator: { !$0.isWhitespace }).count
        return wordCount >= 3 || query.count >= 24
    }

    private struct SearchIntent {
        let terms: [String]
        let appNames: Set<String>
        let contentTypes: Set<ContentType>
        let dateRange: ClosedRange<Date>?
    }

    private func rerankSearchResults(query: String, semanticHits: [SemanticSearchHit]) -> [ClipboardItem] {
        let intent = searchIntent(for: query)
        var candidates: [UUID: ClipboardItem] = [:]
        var scores: [UUID: Double] = [:]
        let activeByID = Dictionary(uniqueKeysWithValues: activeItems.map { ($0.id, $0) })

        for hit in semanticHits {
            guard let item = activeByID[hit.id], isEligibleSearchResult(item, for: query, intent: intent) else { continue }
            candidates[item.id] = item
            scores[item.id, default: 0] += hit.similarity * 1_000
        }

        for item in activeItems {
            guard isEligibleSearchResult(item, for: query, intent: intent) else { continue }
            let haystack = item.searchableText.lowercased()
            let hits = intent.terms.reduce(0) { total, term in total + (haystack.contains(term) ? 1 : 0) }
            let appMatches = intent.appNames.contains(normalizedSearchText(item.sourceAppName))
            let typeMatches = intent.contentTypes.contains(item.contentType)
            let dateMatches = intent.dateRange?.contains(item.createdAt) ?? false
            guard hits > 0 || appMatches || typeMatches || dateMatches else { continue }
            candidates[item.id] = item
            scores[item.id, default: 0] += Double(hits) * 80
            if haystack.contains(query.lowercased()) {
                scores[item.id, default: 0] += 120
            }
            if appMatches { scores[item.id, default: 0] += 180 }
            if typeMatches { scores[item.id, default: 0] += 90 }
            if dateMatches { scores[item.id, default: 0] += 90 }
        }

        for item in candidates.values {
            if !intent.appNames.isEmpty && intent.appNames.contains(normalizedSearchText(item.sourceAppName)) {
                scores[item.id, default: 0] += 120
            }
            if !intent.contentTypes.isEmpty && intent.contentTypes.contains(item.contentType) {
                scores[item.id, default: 0] += 70
            }
            if let range = intent.dateRange, range.contains(item.createdAt) {
                scores[item.id, default: 0] += 70
            }
        }

        let sorted = candidates.values.sorted {
            let left = scores[$0.id, default: 0]
            let right = scores[$1.id, default: 0]
            if left == right { return $0.createdAt > $1.createdAt }
            return left > right
        }

        // Let the LLM inspect a broader but still bounded pool. Limiting this too
        // early makes it impossible for it to rescue a good result that semantic
        // similarity placed just outside the local keyword-biased top ten.
        return Array(sorted.prefix(12))
    }

    private func applyAIReranking(_ decisions: [SearchRerankDecision]?, to candidates: [ClipboardItem]) -> [ClipboardItem] {
        guard let decisions else {
            // If the reranker is unavailable (for example, no provider credit),
            // retain the safe, compact semantic fallback.
            return Array(candidates.prefix(3))
        }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        return decisions.compactMap { byID[$0.id] }
    }

    private func isEligibleSearchResult(_ item: ClipboardItem, for query: String, intent: SearchIntent) -> Bool {
        let text = item.searchableText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = normalizedSearchText(text)
        let normalizedQuery = normalizedSearchText(query)

        // Captured developer logs and the query itself are not useful search results.
        if text.contains("[Clipboard Search]") || normalizedText == normalizedQuery { return false }
        // Images with no OCR/description cannot substantively answer a text search.
        if item.contentType == .image && intent.contentTypes.isEmpty { return false }
        return !text.isEmpty
    }

    /// Detailed search traces for validating semantic search and the local filters in Xcode's console.
    private func logSearchDebug(query: String, vectorDimensions: Int, semanticHits: [SemanticSearchHit], finalResults: [ClipboardItem]) {
        #if DEBUG
        let intent = searchIntent(for: query)
        let dateFormatter = ISO8601DateFormatter()
        print("\n[Clipboard Search] ─────────────────────────────────────────")
        print("[Clipboard Search] prompt: \(query.debugDescription)")
        print("[Clipboard Search] embedding dimensions: \(vectorDimensions) | semantic candidates: \(semanticHits.count) | final results: \(finalResults.count)")
        print("[Clipboard Search] parsed filters | terms=\(intent.terms) apps=\(Array(intent.appNames).sorted()) types=\(intent.contentTypes.map(\.rawValue).sorted()) dateRange=\(intent.dateRange.map { "\(dateFormatter.string(from: $0.lowerBound))...\(dateFormatter.string(from: $0.upperBound))" } ?? "none")")

        print("[Clipboard Search] semantic RPC candidates:")
        let activeByID = Dictionary(uniqueKeysWithValues: activeItems.map { ($0.id, $0) })
        for (index, hit) in semanticHits.enumerated() {
            guard let item = activeByID[hit.id] else { continue }
            let preview = item.searchableText.replacingOccurrences(of: "\n", with: " ").prefix(180)
            print("  #\(index + 1) similarity=\(String(format: "%.4f", hit.similarity)) id=\(item.id.uuidString) type=\(item.contentType.rawValue) app=\(item.sourceAppName.debugDescription) created=\(dateFormatter.string(from: item.createdAt)) text=\(String(preview).debugDescription)")
        }

        print("[Clipboard Search] final reranked results:")
        for (index, item) in finalResults.enumerated() {
            let haystack = item.searchableText.lowercased()
            let matchedTerms = intent.terms.filter { haystack.contains($0) }
            let appMatch = intent.appNames.contains(normalizedSearchText(item.sourceAppName))
            let typeMatch = intent.contentTypes.contains(item.contentType)
            let dateMatch = intent.dateRange?.contains(item.createdAt) ?? false
            let preview = item.searchableText.replacingOccurrences(of: "\n", with: " ").prefix(180)
            print("  #\(index + 1) id=\(item.id.uuidString) matchedTerms=\(matchedTerms) appMatch=\(appMatch) typeMatch=\(typeMatch) dateMatch=\(dateMatch) text=\(String(preview).debugDescription)")
        }
        print("[Clipboard Search] ─────────────────────────────────────────\n")
        #endif
    }

    private func searchIntent(for query: String) -> SearchIntent {
        let normalized = normalizedSearchText(query)
        let words = normalized
            .split(separator: " ")
            .map(String.init)
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "do", "find",
            "for", "from", "had", "has", "have", "i", "im", "in", "is", "it", "like",
            "looking", "me", "my", "of", "on", "or", "please", "search", "searching",
            "show", "some", "something", "that", "the", "thing", "this", "to", "was",
            "with"
        ]
        let terms = words.filter { $0.count > 2 && !stopWords.contains($0) }
        let apps = Set(activeItems.map { normalizedSearchText($0.sourceAppName) }
            .filter { !$0.isEmpty && normalized.contains($0) })
        return SearchIntent(
            terms: terms,
            appNames: apps,
            contentTypes: contentTypes(in: normalized),
            dateRange: dateRange(in: normalized)
        )
    }

    private func normalizedSearchText(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func contentTypes(in query: String) -> Set<ContentType> {
        var types = Set<ContentType>()
        let words = Set(query.split(separator: " ").map(String.init))
        if !words.intersection(["image", "images", "photo", "photos", "picture", "pictures", "screenshot", "screenshots"]).isEmpty { types.insert(.image) }
        if !words.intersection(["video", "videos", "movie", "movies", "recording", "recordings"]).isEmpty { types.insert(.video) }
        if !words.intersection(["file", "files", "document", "documents", "pdf", "download", "downloads"]).isEmpty { types.insert(.file) }
        if !words.intersection(["link", "links", "url", "urls", "website", "webpage"]).isEmpty { types.insert(.url) }
        if !words.intersection(["text", "snippet", "snippets", "code", "note", "notes"]).isEmpty { types.insert(.text); types.insert(.richText) }
        return types
    }

    private func dateRange(in query: String) -> ClosedRange<Date>? {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        if query.contains("today") {
            return startOfToday...now
        }
        if query.contains("yesterday") {
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? now
            let end = calendar.date(byAdding: .second, value: -1, to: startOfToday) ?? now
            return start...end
        }
        if query.contains("this week") {
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.date(byAdding: .day, value: -7, to: now) ?? now
            return start...now
        }
        if query.contains("last week") {
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)
            let end = calendar.date(byAdding: .second, value: -1, to: thisWeek?.start ?? now) ?? now
            let start = calendar.date(byAdding: .day, value: -7, to: end) ?? now
            return start...end
        }
        if query.contains("few weeks") || query.contains("couple weeks") {
            let start = calendar.date(byAdding: .weekOfYear, value: -6, to: now) ?? now
            let end = calendar.date(byAdding: .weekOfYear, value: -2, to: now) ?? now
            return start...end
        }
        if let range = relativeDateRange(in: query, unitWords: ["day", "days"], component: .day) { return range }
        if let range = relativeDateRange(in: query, unitWords: ["week", "weeks"], component: .weekOfYear) { return range }
        if let range = relativeDateRange(in: query, unitWords: ["month", "months"], component: .month) { return range }
        return monthNameRange(in: query)
    }

    private func relativeDateRange(in query: String, unitWords: Set<String>, component: Calendar.Component) -> ClosedRange<Date>? {
        let words = query.split(separator: " ").map(String.init)
        guard let unitIndex = words.firstIndex(where: { unitWords.contains($0) }) else { return nil }
        let calendar = Calendar.current
        let now = Date()
        let previous = unitIndex > 0 ? words[unitIndex - 1] : ""
        let amount = Int(previous) ?? 1
        if query.contains("last \(words[unitIndex])") {
            let start = calendar.date(byAdding: component, value: -amount, to: now) ?? now
            return start...now
        }
        if query.contains("\(previous) \(words[unitIndex]) ago") {
            let end = calendar.date(byAdding: component, value: -amount, to: now) ?? now
            let start = calendar.date(byAdding: component, value: -(amount + 1), to: now) ?? now
            return start...end
        }
        return nil
    }

    private func monthNameRange(in query: String) -> ClosedRange<Date>? {
        let months = Calendar.current.monthSymbols.map { normalizedSearchText($0) }
        guard let monthIndex = months.firstIndex(where: { query.contains($0) }) else { return nil }
        let calendar = Calendar.current
        let nowComponents = calendar.dateComponents([.year], from: Date())
        guard let year = nowComponents.year else { return nil }
        let startComponents = DateComponents(year: year, month: monthIndex + 1, day: 1)
        guard let start = calendar.date(from: startComponents),
              let end = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: start)
        else { return nil }
        return start...end
    }
    func retrySync(_ item: ClipboardItem) {
        updateItem(id: item.id, touchModifiedAt: false) { $0.syncStatus = .pending }
        if let fresh = items.first(where: { $0.id == item.id }) {
            Task { await sync(fresh) }
        }
    }
    func loadLocalDataIfNeeded(for item: ClipboardItem) {
        guard item.localData == nil, item.storagePath != nil else { return }
        if (CloudChunkManifest(storagePath: item.storagePath)?.kind == .richPayload)
            || item.storagePath?.hasPrefix(CloudClipboardPayload.storagePrefix) == true {
            guard !assetLoadingIDs.contains(item.id) else { return }
            assetLoadingIDs.insert(item.id)
            assetLoadErrors[item.id] = nil
            Task {
                defer { assetLoadingIDs.remove(item.id) }
                do {
                    guard let hydrated = try await repository.hydrateRichPayload(for: item) else { return }
                    updateItem(id: item.id, touchModifiedAt: false) {
                        $0.contentText = hydrated.contentText
                        $0.rtfData = hydrated.rtfData
                        $0.htmlData = hydrated.htmlData
                        $0.rtfdData = hydrated.rtfdData
                    }
                } catch {
                    assetLoadErrors[item.id] = specificCloudErrorMessage(error) ?? "Couldn’t download this item."
                    handleCloudFailure(error)
                }
            }
            return
        }
        if let cached = AssetCache.shared.data(for: item.id) {
            updateItem(id: item.id, touchModifiedAt: false) { $0.localData = cached }
            return
        }
        guard !assetLoadingIDs.contains(item.id) else { return }
        assetLoadingIDs.insert(item.id)
        assetLoadErrors[item.id] = nil
        Task {
            defer { assetLoadingIDs.remove(item.id) }
            do {
                guard let data = try await repository.downloadData(for: item) else { return }
                AssetCache.shared.store(data, for: item.id)
                if item.contentType == .image {
                    ThumbnailCache.shared.createAndStore(from: data, for: item.id)
                    if let thumbnail = ThumbnailCache.shared.data(for: item.id) {
                        try? await repository.updateThumbnail(id: item.id, data: thumbnail)
                    }
                }
                updateItem(id: item.id, touchModifiedAt: false) { $0.localData = data }
            } catch {
                assetLoadErrors[item.id] = specificCloudErrorMessage(error) ?? "Couldn’t download this item."
                handleCloudFailure(error)
                print("❌ iCloud asset download error: \(error.localizedDescription)")
            }
        }
    }

    /// One-time, low-priority migration for cards created before thumbnails
    /// existed. It is deliberately serialized so opening an old library does
    /// not launch dozens of full-image downloads or make the grid lag.
    func prepareImageThumbnailIfNeeded(for item: ClipboardItem) {
        guard item.contentType == .image,
              item.localData == nil,
              item.storagePath != nil,
              ThumbnailCache.shared.data(for: item.id) == nil,
              !assetLoadingIDs.contains(item.id),
              !thumbnailBackfillAttemptedIDs.contains(item.id)
        else { return }

        thumbnailBackfillAttemptedIDs.insert(item.id)
        assetLoadingIDs.insert(item.id)
        assetLoadErrors[item.id] = nil
        Task(priority: .utility) {
            await LargeTransferScheduler.preview.acquire()
            defer {
                assetLoadingIDs.remove(item.id)
                Task { await LargeTransferScheduler.preview.release() }
            }
            do {
                let resultData = try await withThrowingTaskGroup(of: Data?.self) { group in
                    group.addTask { try await self.repository.downloadData(for: item) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 30_000_000_000)
                        throw URLError(.timedOut)
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                guard let data = resultData else { return }
                AssetCache.shared.store(data, for: item.id)
                ThumbnailCache.shared.createAndStore(from: data, for: item.id)
                updateItem(id: item.id, touchModifiedAt: false) { $0.localData = data }
                if let thumbnail = ThumbnailCache.shared.data(for: item.id) {
                    try? await repository.updateThumbnail(id: item.id, data: thumbnail)
                }
            } catch {
                assetLoadErrors[item.id] = specificCloudErrorMessage(error) ?? "Couldn’t prepare this preview."
                handleCloudFailure(error)
                print("❌ iCloud thumbnail backfill error: \(error.localizedDescription)")
            }
        }
    }

    func assetLoadError(for itemID: UUID) -> String? { assetLoadErrors[itemID] }

    func retryAssetDownload(for item: ClipboardItem) {
        assetLoadErrors[item.id] = nil
        loadLocalDataIfNeeded(for: item)
    }
    
    func toggleFavorite(_ item: ClipboardItem) {
        let newValue = !item.isPinned
        updateItem(id: item.id) { $0.isPinned = newValue }
        runDurableItemMutation(itemID: item.id) { [repository] in
            try await repository.setFavorite(id: item.id, isFavorite: newValue)
        }
    }
    func moveToTrash(_ item: ClipboardItem) {
        let deletedDate = Date()
        updateItem(id: item.id) {
            $0.isDeleted = true
            $0.deletedAt = deletedDate
        }
        runDurableItemMutation(itemID: item.id) { [repository] in
            try await repository.setDeleted(id: item.id, isDeleted: true, deletedAt: deletedDate)
        }
    }
    func restoreFromTrash(_ item: ClipboardItem) {
        updateItem(id: item.id) {
            $0.isDeleted = false
            $0.deletedAt = nil
        }
        runDurableItemMutation(itemID: item.id) { [repository] in
            try await repository.setDeleted(id: item.id, isDeleted: false, deletedAt: nil)
        }
    }
    func deleteItem(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        AssetCache.shared.remove(for: item.id)
        pendingItemIDs.remove(item.id)
        pendingDeletionIDs.insert(item.id)
        persistLibraryCache()
        Task {
            do {
                try await repository.delete(id: item.id)
                pendingDeletionIDs.remove(item.id)
                persistLibraryCache()
            } catch {
                print("Failed to delete item: \(error)")
                handleCloudFailure(error)
            }
        }
    }
    func emptyTrash() {
        let toDelete = trashedItems
        items.removeAll { $0.isDeleted }
        pendingDeletionIDs.formUnion(toDelete.map(\.id))
        persistLibraryCache()
        Task {
            for item in toDelete {
                do { try await repository.delete(id: item.id); pendingDeletionIDs.remove(item.id) }
                catch { handleCloudFailure(error) }
            }
            persistLibraryCache()
        }
    }
    func deleteAllItems() {
        let toDelete = items
        let foldersToDelete = folders
        
        items.removeAll()
        folders.removeAll()
        pendingDeletionIDs.formUnion(toDelete.map(\.id))
        pendingFolderDeletionIDs.formUnion(foldersToDelete.map(\.id))
        persistLibraryCache()
        
        Task {
            // Delete sequentially to avoid CloudKit request throttling.
            // project when their history is large.
            for item in toDelete {
                do { try await repository.delete(id: item.id); pendingDeletionIDs.remove(item.id) }
                catch { handleCloudFailure(error) }
            }
            for folder in foldersToDelete {
                do {
                    try await repository.deleteFolder(id: folder.id)
                    pendingFolderDeletionIDs.remove(folder.id)
                }
                catch { handleCloudFailure(error) }
            }
            persistLibraryCache()
        }
    }
    func itemCount(in folder: ClipboardFolder) -> Int {
        LibraryMetadataStore.shared.itemCount(inFolder: folder.id)
    }
    func items(in folderID: UUID) -> [ClipboardItem] {
        items.filter { $0.folderIDs.contains(folderID) }
    }
    @discardableResult
    func createFolder(named name: String = "Untitled Folder") -> ClipboardFolder {
        let folder = ClipboardFolder(id: UUID(), name: name, createdAt: Date(), updatedAt: Date())
        pendingFolderIDs.insert(folder.id)
        folders.append(folder)
        persistLibraryCache()
        Task {
            do {
                let currentName = folders.first(where: { $0.id == folder.id })?.name ?? folder.name
                try await repository.createFolder(id: folder.id, name: currentName, createdAt: folder.createdAt, updatedAt: folder.updatedAt)
                pendingFolderIDs.remove(folder.id)
                let remoteFolders = try await repository.fetchFolders()
                folders = mergeFolders(remoteFolders)
                loadError = nil
            } catch {
                pendingFolderIDs.insert(folder.id)
                persistLibraryCache()
                loadError = folderErrorMessage(for: error, fallback: "Couldn't create folder")
                handleCloudFailure(error)
            }
        }
        return folder
    }
    func renameFolder(_ folder: ClipboardFolder, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmed.isEmpty ? "Untitled Folder" : trimmed
        updateFolder(id: folder.id) {
            $0.name = newName
            $0.updatedAt = Date()
        }
        // Renames are durable before the asynchronous write begins.
        pendingFolderIDs.insert(folder.id)
        persistLibraryCache()
        Task {
            do {
                try await repository.renameFolder(id: folder.id, name: newName)
                pendingFolderIDs.remove(folder.id)
                persistLibraryCache()
                loadError = nil
            } catch {
                pendingFolderIDs.insert(folder.id)
                persistLibraryCache()
                loadError = folderErrorMessage(for: error, fallback: "Couldn't rename folder")
                handleCloudFailure(error)
            }
        }
    }
    func deleteFolder(_ folder: ClipboardFolder) {
        let affectedItemIDs = items.filter { $0.folderIDs.contains(folder.id) }.map(\.id)
        folders.removeAll { $0.id == folder.id }
        pendingFolderDeletionIDs.insert(folder.id)
        persistLibraryCache()
        for itemID in affectedItemIDs {
            updateItem(id: itemID) { $0.folderIDs.remove(folder.id) }
        }
        Task {
            do {
                try await repository.deleteFolder(id: folder.id)
                pendingFolderDeletionIDs.remove(folder.id)
                persistLibraryCache()
                loadError = nil
            } catch {
                // Keep the local deletion and retry it later. Restoring the
                // folder here makes an offline delete appear to have failed.
                loadError = folderErrorMessage(for: error, fallback: "Couldn't delete folder")
                handleCloudFailure(error)
            }
        }
    }
    func assignItems(_ itemIDs: [UUID], to folder: ClipboardFolder) {
        let uniqueIDs = Array(Set(itemIDs))
        guard !uniqueIDs.isEmpty else { return }
        
        let itemsToMove = uniqueIDs.filter { id in
            let itemFolders = items.first(where: { $0.id == id })?.folderIDs ?? []
            return itemFolders != [folder.id]
        }
        
        guard !itemsToMove.isEmpty else { return }
        
        for id in itemsToMove {
            updateItem(id: id) { $0.folderIDs = [folder.id] }
        }
        
        for itemID in itemsToMove {
            runDurableItemMutation(itemID: itemID) { [repository] in
                try await repository.addToFolder(ids: [itemID], folderID: folder.id)
            }
        }
    }
    func removeFromFolder(_ item: ClipboardItem, folderID: UUID) {
        guard item.folderIDs.contains(folderID) else { return }
        updateItem(id: item.id) { $0.folderIDs.remove(folderID) }
        runDurableItemMutation(itemID: item.id) { [repository] in
            try await repository.removeFromFolder(id: item.id, folderID: folderID)
        }
    }
    func copyToPasteboard(_ item: ClipboardItem) {
        Task {
            _ = await restoreToPasteboard(item)
        }
    }
    func restoreToPasteboard(_ item: ClipboardItem, asPlainText: Bool = false) async -> ClipboardRestoreResult {
        let pasteboard = NSPasteboard.general
        if !asPlainText, let rawData = item.rawPasteboardData, !rawData.isEmpty {
            writeRawPasteboardData(rawData, to: pasteboard)
            service.markSelfCopy()
            return ClipboardRestoreResult(didCopy: true, message: "Copied to clipboard")
        }
        if asPlainText {
            guard let text = plainTextFallback(for: item) else {
                return ClipboardRestoreResult(didCopy: false, message: "No plain text available")
            }
            return writePlainText(text, to: pasteboard)
                ? ClipboardRestoreResult(didCopy: true, message: "Copied as plain text")
                : ClipboardRestoreResult(didCopy: false, message: "Could not copy item")
        }
        if item.hasPortableRichText {
            var richItem = item
            if (CloudChunkManifest(storagePath: item.storagePath)?.kind == .richPayload)
                || item.storagePath?.hasPrefix(CloudClipboardPayload.storagePrefix) == true {
                do {
                    guard let hydrated = try await repository.hydrateRichPayload(for: item) else {
                        return ClipboardRestoreResult(didCopy: false, message: "Could not restore rich text")
                    }
                    richItem = hydrated
                    updateItem(id: item.id, touchModifiedAt: false) {
                        $0.contentText = hydrated.contentText
                        $0.rtfData = hydrated.rtfData
                        $0.htmlData = hydrated.htmlData
                        $0.rtfdData = hydrated.rtfdData
                    }
                } catch {
                    handleCloudFailure(error)
                    return ClipboardRestoreResult(didCopy: false, message: specificCloudErrorMessage(error) ?? "Could not restore rich text")
                }
            }
            return writeRichText(richItem, to: pasteboard)
                ? ClipboardRestoreResult(didCopy: true, message: "Copied to clipboard")
                : ClipboardRestoreResult(didCopy: false, message: "Could not copy rich text")
        }
        if item.contentType == .text,
           let portableColor = PortableClipboardColor.parse(item.contentText) {
            pasteboard.clearContents()
            let color = NSColor(calibratedRed: portableColor.red, green: portableColor.green, blue: portableColor.blue, alpha: portableColor.alpha)
            let didWrite = pasteboard.writeObjects([color])
            if didWrite, let text = item.contentText { pasteboard.setString(text, forType: .string) }
            service.markSelfCopy()
            return ClipboardRestoreResult(didCopy: didWrite, message: didWrite ? "Copied to clipboard" : "Could not copy color")
        }
        if let url = item.revealableFileURL,
           item.contentType == .file || item.contentType == .video || item.contentType == .image {
            return writeFileURL(url, to: pasteboard)
                ? ClipboardRestoreResult(didCopy: true, message: "Copied to clipboard")
                : ClipboardRestoreResult(didCopy: false, message: "Could not copy file")
        }
        if item.bucket == nil {
            guard let text = item.contentText, !text.isEmpty else {
                return ClipboardRestoreResult(didCopy: false, message: "Nothing to copy")
            }
            return writePlainText(text, to: pasteboard)
                ? ClipboardRestoreResult(didCopy: true, message: "Copied to clipboard")
                : ClipboardRestoreResult(didCopy: false, message: "Could not copy item")
        }
        if let data = item.localData {
            return writeBinary(data, for: item, to: pasteboard)
                ? ClipboardRestoreResult(didCopy: true, message: "Copied to clipboard")
                : ClipboardRestoreResult(didCopy: false, message: "Could not copy item")
        }
        guard item.storagePath != nil else {
            return ClipboardRestoreResult(didCopy: false, message: "Item data is unavailable")
        }
        if let data = try? await repository.downloadData(for: item) {
            updateItem(id: item.id, touchModifiedAt: false) { $0.localData = data }
            return writeBinary(data, for: item, to: pasteboard)
                ? ClipboardRestoreResult(didCopy: true, message: "Copied to clipboard")
                : ClipboardRestoreResult(didCopy: false, message: "Could not copy item")
        }
        return ClipboardRestoreResult(didCopy: false, message: "Could not restore item")
    }
    private func plainTextFallback(for item: ClipboardItem) -> String? {
        if let text = item.contentText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let fileName = item.fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !fileName.isEmpty {
            return fileName
        }
        return nil
    }
    func focusInFullApp(_ item: ClipboardItem) {
        focusedItemID = item.id
    }
    func expandInFullApp(_ item: ClipboardItem) {
        focusedItemID = item.id 
        expandedItemID = item.id
    }
    func dragItemProvider(for item: ClipboardItem) -> NSItemProvider {
        if let url = item.revealableFileURL,
           item.contentType == .file || item.contentType == .video || item.contentType == .image {
            return NSItemProvider(object: url as NSURL)
        }
        // The actual portable representations, not the capture label, decide
        // whether an external drag retains formatting. Some legacy captures
        // are labelled text while still carrying valid RTF/HTML/RTFD.
        if item.hasPortableRichText {
            let provider = NSItemProvider(object: (item.contentText ?? "") as NSString)
            if let data = item.rtfdData {
                provider.registerDataRepresentation(forTypeIdentifier: UTType.rtfd.identifier, visibility: .all) { completion in completion(data, nil); return nil }
            }
            if let data = item.rtfData {
                provider.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { completion in completion(data, nil); return nil }
            }
            if let data = item.htmlData {
                provider.registerDataRepresentation(forTypeIdentifier: UTType.html.identifier, visibility: .all) { completion in completion(data, nil); return nil }
            }
            return provider
        }
        switch item.contentType {
        case .file, .video:
            break
        case .url:
            if let text = item.contentText, let url = URL(string: text) {
                return NSItemProvider(object: url as NSURL)
            }
        case .text:
            if let text = item.contentText {
                return NSItemProvider(object: text as NSString)
            }
        case .richText:
            return NSItemProvider(object: (item.contentText ?? "") as NSString)
        case .image:
            if let data = item.localData {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
                return provider
            }
        }
        return NSItemProvider(object: (item.contentText ?? item.fileName ?? "") as NSString)
    }

    /// Supplies only standard, app-compatible content for drags leaving the
    /// menu-bar strip.
    func stripDragItemProvider(for item: ClipboardItem) -> NSItemProvider {
        dragItemProvider(for: item)
    }
    func folderDragItemProvider(for itemIDs: [UUID]) -> NSItemProvider {
        let uniqueIDs = Array(Set(itemIDs))
        let payload = uniqueIDs.map(\.uuidString).joined(separator: ",")
        let provider = NSItemProvider()

        // Primary: internal folder-filing type.
        // Uses registerDataRepresentation — the same pattern as the working wardrobe type.
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.hetpasteFolderItemIDs.identifier,
            visibility: .all
        ) { completion in
            completion(payload.data(using: .utf8), nil)
            return nil
        }

        // Secondary: external drag fallbacks so the card can still be dropped into
        // other apps (Finder, Notes, etc.) or onto the Wardrobe.
        if uniqueIDs.count == 1, let item = items.first(where: { $0.id == uniqueIDs[0] }) {
            if let url = item.revealableFileURL,
               item.contentType == .file || item.contentType == .video || item.contentType == .image {
                provider.registerObject(url as NSURL, visibility: .all)
            } else if let text = plainTextFallback(for: item) {
                provider.registerObject(text as NSString, visibility: .all)
            }
            if item.contentType == .image, let data = item.localData {
                provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            // Wardrobe internal shortcut.
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.hetpasteWardrobeItemID.identifier,
                visibility: .all
            ) { completion in
                completion(item.id.uuidString.data(using: .utf8), nil)
                return nil
            }
        } else {
            let fallbackText = items.filter { uniqueIDs.contains($0.id) }
                .compactMap { plainTextFallback(for: $0) }
                .joined(separator: "\n")
            provider.registerObject(fallbackText as NSString, visibility: .all)
        }

        return provider
    }
    private func writeRichText(_ item: ClipboardItem, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let pbItem = NSPasteboardItem()
        if let data = item.rtfdData { pbItem.setData(data, forType: .rtfd) }
        if let data = item.rtfData { pbItem.setData(data, forType: .rtf) }
        if let data = item.htmlData { pbItem.setData(data, forType: .html) }
        if let text = item.contentText { pbItem.setString(text, forType: .string) }
        let didWrite = pasteboard.writeObjects([pbItem])
        service.markSelfCopy()
        return didWrite
    }
    private func writePlainText(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let didWrite = pasteboard.setString(text, forType: .string)
        service.markSelfCopy()
        return didWrite
    }
    private func writeFileURL(_ url: URL, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let didWrite = pasteboard.writeObjects([url as NSURL])
        service.markSelfCopy()
        return didWrite
    }
    private func writeBinary(_ data: Data, for item: ClipboardItem, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let didWrite: Bool
        switch item.contentType {
        case .image:
            didWrite = pasteboard.setData(data, forType: .png)
        default:
            didWrite = pasteboard.setData(data, forType: .fileContents)
        }
        service.markSelfCopy()
        return didWrite
    }
    private func writeRawPasteboardData(_ rawData: [String: Data], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let pbItem = NSPasteboardItem()
        for (typeIdentifier, data) in rawData {
            pbItem.setData(data, forType: NSPasteboard.PasteboardType(typeIdentifier))
        }
        pasteboard.writeObjects([pbItem])
    }
    private func updateItem(id: UUID, touchModifiedAt: Bool = true, _ mutate: (inout ClipboardItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[idx])
        if touchModifiedAt { items[idx].updatedAt = Date() }
        persistLibraryCache()
    }
    private func updateFolder(id: UUID, _ mutate: (inout ClipboardFolder) -> Void) {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        mutate(&folders[idx])
        persistLibraryCache()
    }
    func persistLibraryCache(immediately: Bool = false) {
        let queues = LibraryMetadataStore.QueueState(
            pendingItemIDs: pendingItemIDs,
            pendingFolderIDs: pendingFolderIDs,
            pendingDeletionIDs: pendingDeletionIDs,
            pendingFolderDeletionIDs: pendingFolderDeletionIDs,
            pendingChainIDs: pendingChainIDs,
            pendingChainDeletionIDs: pendingChainDeletionIDs
        )
        // Queue state and its payload must be committed immediately. This keeps
        // an offline mutation crash-safe before any CloudKit I/O begins.
        LibraryMetadataStore.shared.remove(
            items: pendingDeletionIDs,
            folders: pendingFolderDeletionIDs,
            chains: pendingChainDeletionIDs
        )
        LibraryMetadataStore.shared.upsert(
            items: items.filter { pendingItemIDs.contains($0.id) },
            folders: folders.filter { pendingFolderIDs.contains($0.id) },
            chains: chains.filter { pendingChainIDs.contains($0.id) },
            chainItems: chainItems.filter { pendingChainIDs.contains($0.key) }.values.flatMap { $0 },
            queues: queues
        )

        metadataPersistenceTask?.cancel()
        let visibleItems = items
        let visibleFolders = folders
        let visibleChains = chains
        let visibleChainItems = chainItems.values.flatMap { $0 }
        let write = {
            LibraryMetadataStore.shared.upsert(
                items: visibleItems,
                folders: visibleFolders,
                chains: visibleChains,
                chainItems: visibleChainItems,
                queues: queues
            )
        }
        if immediately {
            write()
        } else {
            metadataPersistenceTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                write()
            }
        }
        updateDiagnostics()
    }
    private func queueItemForRetry(_ id: UUID) {
        pendingItemIDs.insert(id)
        updateItem(id: id, touchModifiedAt: false) { $0.syncStatus = .pending }
        persistLibraryCache()
        cloudSyncState = .offline
    }

    /// Saves the local intent before a metadata-only CloudKit mutation begins.
    /// If the process stops at any point, the normal item queue replays the
    /// whole current record; CloudKit's timestamp conflict rule prevents that
    /// replay from replacing a newer edit from another device.
    func updateItemContent(id: UUID, contentText: String?, rtfData: Data?, htmlData: Data?, rtfdData: Data?) async throws {
        updateItem(id: id) {
            $0.contentText = contentText
            $0.rtfData = rtfData
            $0.htmlData = htmlData
            $0.rtfdData = rtfdData
            // An edit that contains a portable rich representation is no
            // longer plain text. This keeps every platform on the exact
            // formatting path instead of a code/plain-text renderer.
            if $0.hasPortableRichText {
                $0.contentType = .richText
            }
            $0.updatedAt = Date()
        }
        
        guard let item = items.first(where: { $0.id == id }) else { return }
        queueItemForRetry(id)
        _ = await sync(item)
    }

    private func runDurableItemMutation(itemID: UUID, operation: @escaping () async throws -> Void) {
        queueItemForRetry(itemID)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
                self.pendingItemIDs.remove(itemID)
                self.updateItem(id: itemID, touchModifiedAt: false) { $0.syncStatus = .synced }
                self.persistLibraryCache()
                self.loadError = nil
            } catch {
                self.loadError = self.folderErrorMessage(for: error, fallback: "Change queued until iCloud is available")
                self.handleCloudFailure(error)
            }
        }
    }
    private func retryQueuedChanges() async {
        // Deliberately serial: retrying every operation at once is the fastest
        // route to CloudKit throttling after a long offline period. A failed
        // operation stays on disk and stops this pass; the explicit server
        // Retry-After delay is then scheduled by handleCloudFailure.
        do {
            for id in pendingDeletionIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                try await repository.delete(id: id)
                pendingDeletionIDs.remove(id)
                persistLibraryCache()
            }
            for id in pendingFolderDeletionIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                try await repository.deleteFolder(id: id)
                pendingFolderDeletionIDs.remove(id)
                persistLibraryCache()
            }
            for id in pendingChainDeletionIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                try await repository.deleteChain(id: id)
                pendingChainDeletionIDs.remove(id)
                persistLibraryCache()
            }
            for id in pendingChainIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let chain = chains.first(where: { $0.id == id }) else {
                    pendingChainIDs.remove(id)
                    continue
                }
                try await repository.createChain(id: chain.id, name: chain.name, createdAt: chain.createdAt, updatedAt: chain.updatedAt)
                try await repository.deleteChainItems(chainID: chain.id)
                try await repository.addChainItems(chainItems[id] ?? [], chainID: chain.id)
                pendingChainIDs.remove(id)
                persistLibraryCache()
            }
            for id in pendingItemIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let item = items.first(where: { $0.id == id }) else {
                    pendingItemIDs.remove(id)
                    continue
                }
                guard await sync(item) else { return }
            }
            for id in pendingFolderIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let folder = folders.first(where: { $0.id == id }) else {
                    pendingFolderIDs.remove(id)
                    continue
                }
                try await repository.createFolder(id: folder.id, name: folder.name, createdAt: folder.createdAt, updatedAt: folder.updatedAt)
                pendingFolderIDs.remove(id)
                persistLibraryCache()
            }
        } catch {
            cloudSyncState = isTransientCloudError(error) ? .offline : .failed(cloudErrorMessage(error))
            handleCloudFailure(error)
        }
    }
    private func isTransientCloudError(_ error: Error) -> Bool {
        guard let cloudError = error as? CKError else { return false }
        return [.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy].contains(cloudError.code)
    }
    private func updateDiagnostics() {
        CloudSyncDiagnostics.shared.updateQueueCount(pendingItemIDs.count + pendingFolderIDs.count + pendingDeletionIDs.count + pendingFolderDeletionIDs.count + pendingChainIDs.count + pendingChainDeletionIDs.count)
    }
    private func handleCloudFailure(_ error: Error) {
        CloudSyncDiagnostics.shared.recordFailure(error)
        guard let cloudError = error as? CKError else { return }

        // CloudKit's own retry deadline always takes precedence.
        if let seconds = (cloudError as NSError).userInfo[CKErrorRetryAfterKey] as? NSNumber {
            let retryAt = Date().addingTimeInterval(seconds.doubleValue)
            UserDefaults.standard.set(retryAt, forKey: retryNotBeforeKey)
            scheduleRetry(at: retryAt)
            return
        }

        // Apple does not notify an app when a user frees private iCloud
        // storage. Keep the mutation durable and retry conservatively while
        // the app is running: 5, 10, 20, 40, then at most once an hour.
        guard cloudError.code == .quotaExceeded else { return }
        let attempt = UserDefaults.standard.integer(forKey: quotaRetryAttemptKey)
        let delay = min(3600.0, 300.0 * Double(1 << min(attempt, 3)))
        UserDefaults.standard.set(attempt + 1, forKey: quotaRetryAttemptKey)
        let retryAt = Date().addingTimeInterval(delay)
        UserDefaults.standard.set(retryAt, forKey: retryNotBeforeKey)
        scheduleRetry(at: retryAt)
    }
    private func scheduleRetry(at date: Date) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            UserDefaults.standard.removeObject(forKey: self.retryNotBeforeKey)
            await self.loadHistory()
        }
    }
    private func mergeFolders(_ remoteFolders: [ClipboardFolder]) -> [ClipboardFolder] {
        let pendingFolders = folders.filter { localFolder in
            pendingFolderIDs.contains(localFolder.id) &&
            !remoteFolders.contains(where: { $0.id == localFolder.id })
        }
        return remoteFolders + pendingFolders
    }
    private func folderErrorMessage(for error: Error, fallback: String) -> String {
        if let message = specificCloudErrorMessage(error) { return message }
        let message = error.localizedDescription.lowercased()
        if message.contains("permission") || message.contains("policy") {
            return "iCloud permissions are blocking this folder action."
        }
        return fallback
    }
    private func cloudErrorMessage(_ error: Error) -> String {
        specificCloudErrorMessage(error) ?? error.localizedDescription
    }
    private func specificCloudErrorMessage(_ error: Error) -> String? {
        if let persistenceError = error as? CloudKitPersistenceError,
           case .accountUnavailable = persistenceError {
            return "Sign in to iCloud in System Settings, then try again."
        }
        guard let cloudError = error as? CKError else { return nil }
        switch cloudError.code {
        case .quotaExceeded:
            return "Your iCloud storage or CloudKit quota is full. Free storage, then sync again."
        case .notAuthenticated:
            return "Sign in to iCloud in System Settings, then try again."
        case .permissionFailure:
            return "iCloud permission was denied for this library."
        case .networkUnavailable, .networkFailure:
            return "You are offline. Changes will retry when a connection returns."
        default:
            return nil
        }
    }
    
    // MARK: - Chain Actions
    
    func activeItems(for chain: Chain) -> [ClipboardItem] {
        let cItems = (chainItems[chain.id] ?? []).sorted { $0.position < $1.position }
        return cItems.compactMap { ci in activeItems.first(where: { $0.id == ci.snippetID }) }
    }

    func createChain(name: String, snippetIDs: [UUID]) {
        let chain = Chain(id: UUID(), name: name, createdAt: Date(), updatedAt: Date())
        var chainItemsForThisChain: [ChainItem] = []
        for (index, snippetID) in snippetIDs.enumerated() {
            chainItemsForThisChain.append(ChainItem(id: UUID(), chainID: chain.id, snippetID: snippetID, position: index))
        }
        
        chains.append(chain)
        chainItems[chain.id] = chainItemsForThisChain
        pendingChainIDs.insert(chain.id)
        persistLibraryCache()
        
        Task {
            do {
                try await repository.createChain(id: chain.id, name: name, createdAt: chain.createdAt, updatedAt: chain.updatedAt)
                try await repository.addChainItems(chainItemsForThisChain, chainID: chain.id)
                pendingChainIDs.remove(chain.id)
                persistLibraryCache()
            } catch {
                print("Failed to create chain: \(error)")
                self.pendingChainIDs.insert(chain.id)
                self.persistLibraryCache()
                self.handleCloudFailure(error)
            }
        }
    }
    
    func renameChain(_ chain: Chain, name: String) {
        guard let index = chains.firstIndex(where: { $0.id == chain.id }) else { return }
        chains[index].name = name
        chains[index].updatedAt = Date()
        pendingChainIDs.insert(chain.id)
        persistLibraryCache()
        
        Task {
            do {
                try await repository.renameChain(id: chain.id, name: name)
                pendingChainIDs.remove(chain.id)
                persistLibraryCache()
            } catch {
                print("Failed to rename chain: \(error)")
                self.pendingChainIDs.insert(chain.id); self.persistLibraryCache(); self.handleCloudFailure(error)
            }
        }
    }
    
    func updateChain(_ chain: Chain, name: String, snippetIDs: [UUID]) {
        guard let index = chains.firstIndex(where: { $0.id == chain.id }) else { return }
        let oldName = chains[index].name
        chains[index].name = name
        chains[index].updatedAt = Date()
        
        var newChainItems: [ChainItem] = []
        for (idx, snippetID) in snippetIDs.enumerated() {
            newChainItems.append(ChainItem(id: UUID(), chainID: chain.id, snippetID: snippetID, position: idx))
        }
        
        chainItems[chain.id] = newChainItems
        pendingChainIDs.insert(chain.id)
        persistLibraryCache()
        
        Task {
            do {
                if oldName != name {
                    try await repository.renameChain(id: chain.id, name: name)
                }
                try await repository.deleteChainItems(chainID: chain.id)
                if !newChainItems.isEmpty {
                    try await repository.addChainItems(newChainItems, chainID: chain.id)
                }
                pendingChainIDs.remove(chain.id)
                persistLibraryCache()
            } catch {
                print("Failed to update chain: \(error)")
                self.pendingChainIDs.insert(chain.id); self.persistLibraryCache(); self.handleCloudFailure(error)
            }
        }
    }
    
    func deleteChain(_ chain: Chain) {
        guard let index = chains.firstIndex(where: { $0.id == chain.id }) else { return }
        chains.remove(at: index)
        chainItems.removeValue(forKey: chain.id)
        // A deletion is also an operation. Queue it first so a quit/crash
        // cannot make the remote chain return on the next launch.
        pendingChainIDs.remove(chain.id)
        pendingChainDeletionIDs.insert(chain.id)
        persistLibraryCache()
        
        Task {
            do {
                try await repository.deleteChain(id: chain.id)
                pendingChainDeletionIDs.remove(chain.id)
                persistLibraryCache()
            } catch {
                print("Failed to delete chain: \(error)")
                self.pendingChainDeletionIDs.insert(chain.id); self.persistLibraryCache(); self.handleCloudFailure(error)
            }
        }
    }
    
    func updateChainItems(chain: Chain, snippetIDs: [UUID]) {
        var newChainItems: [ChainItem] = []
        for (index, snippetID) in snippetIDs.enumerated() {
            newChainItems.append(ChainItem(id: UUID(), chainID: chain.id, snippetID: snippetID, position: index))
        }
        
        chainItems[chain.id] = newChainItems
        pendingChainIDs.insert(chain.id)
        persistLibraryCache()
        
        Task {
            do {
                try await repository.deleteChainItems(chainID: chain.id)
                try await repository.addChainItems(newChainItems, chainID: chain.id)
                pendingChainIDs.remove(chain.id)
                persistLibraryCache()
            } catch {
                print("Failed to update chain items: \(error)")
                self.pendingChainIDs.insert(chain.id); self.persistLibraryCache(); self.handleCloudFailure(error)
            }
        }
    }
    
    func pasteChain(_ chain: Chain) {
        guard let items = chainItems[chain.id] else { return }
        
        let sortedChainItems = items.sorted { $0.position < $1.position }
        let clipboardItemsToPaste = sortedChainItems.compactMap { ci in
            self.items.first(where: { $0.id == ci.snippetID })
        }
        
        guard !clipboardItemsToPaste.isEmpty else { return }
        
        psychoCopyManager.clearQueue()
        psychoCopyManager.activateMultiCopyMode()
        
        for item in clipboardItemsToPaste {
            psychoCopyManager.handleClipboardChange(item)
        }
    }
}
extension ClipboardHistoryViewModel {
    func performSequentialPaste() {
        Task {
            _ = await psychoCopyManager.performSequentialPaste(viewModel: self)
        }
    }
    func performReverseSequentialPaste() {
        Task {
            _ = await psychoCopyManager.performReverseSequentialPaste(viewModel: self)
        }
    }
    func toggleMultiCopyMode() {
        psychoCopyManager.toggleMultiCopyMode()
    }
    func clearCopyQueue() {
        psychoCopyManager.clearQueue()
    }
}
