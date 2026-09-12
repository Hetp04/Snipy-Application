import Foundation

/// Small disk cache for CloudKit assets. It lets image/file cards render while
/// offline without placing large blobs into the JSON library snapshot.
final class AssetCache {
    static let shared = AssetCache()
    private let maximumBytes: Int64 = 250 * 1024 * 1024
    private let directory: URL
    private let protectedIDsKey = "hetpaste.asset-cache.protected-ids"

    private init(fileManager: FileManager = .default) {
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
        directory = support.appendingPathComponent("hetpaste/assets", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func data(for id: UUID) -> Data? {
        let assetURL = url(for: id)
        guard let data = try? Data(contentsOf: assetURL) else { return nil }
        // The eviction policy is LRU. Refresh access time without changing the
        // contents so recently viewed offline previews are retained first.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: assetURL.path)
        return data
    }
    func store(_ data: Data, for id: UUID) {
        try? data.write(to: url(for: id), options: [.atomic, .completeFileProtection])
        trimIfNeeded()
    }
    func remove(for id: UUID) { try? FileManager.default.removeItem(at: url(for: id)) }
    func contains(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: url(for: id).path) }
    func setProtected(_ isProtected: Bool, for id: UUID) {
        var ids = Set((UserDefaults.standard.stringArray(forKey: protectedIDsKey) ?? []).compactMap(UUID.init(uuidString:)))
        if isProtected { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: protectedIDsKey)
    }
    func storageUsageBytes() -> Int64 {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .reduce(Int64(0)) { total, url in total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    func protectedStorageUsageBytes() -> Int64 {
        let protectedIDs = protectedIDStrings()
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { protectedIDs.contains($0.deletingPathExtension().lastPathComponent.lowercased()) }
            .reduce(Int64(0)) { total, url in total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    func clearUnprotected() {
        let protectedIDs = protectedIDStrings()
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard !protectedIDs.contains(url.deletingPathExtension().lastPathComponent.lowercased()) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
    private func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("asset") }

    // Rich payloads are separate from binary clipboard assets. Keeping the
    // encoded CloudKit payload on disk means a large formatted item only has
    // to be downloaded once per device, then remains available for copy and
    // detail views while offline.
    func richPayloadData(for id: UUID, checksum: String) -> Data? {
        let payloadURL = richPayloadURL(for: id, checksum: checksum)
        guard let data = try? Data(contentsOf: payloadURL) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: payloadURL.path)
        return data
    }

    func storeRichPayload(_ data: Data, for id: UUID, checksum: String) {
        try? data.write(to: richPayloadURL(for: id, checksum: checksum), options: [.atomic, .completeFileProtection])
        trimIfNeeded()
    }

    func removeRichPayload(for id: UUID) {
        let prefix = id.uuidString.lowercased() + ".richpayload"
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func richPayloadURL(for id: UUID, checksum: String) -> URL {
        directory.appendingPathComponent("\(id.uuidString.lowercased()).richpayload.\(checksum)")
    }

    private func trimIfNeeded() {
        let protectedIDs = protectedIDStrings()
        let values: [(URL, Int64, Date)] = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]))?.compactMap { url in
            let resource = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = resource?.fileSize else { return nil }
            return (url, Int64(size), resource?.contentModificationDate ?? .distantPast)
        } ?? []
        var remaining = values.reduce(Int64(0)) { $0 + $1.1 }
        for (url, size, _) in values.sorted(by: { $0.2 < $1.2 }) where remaining > maximumBytes {
            guard !protectedIDs.contains(url.deletingPathExtension().lastPathComponent.lowercased()) else { continue }
            try? FileManager.default.removeItem(at: url)
            remaining -= size
        }
    }

    private func protectedIDStrings() -> Set<String> {
        Set((UserDefaults.standard.stringArray(forKey: protectedIDsKey) ?? [])
            .compactMap(UUID.init(uuidString:))
            .map { $0.uuidString.lowercased() })
    }
}





