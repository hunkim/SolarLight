import Foundation

/// File search match with the local file URL resolved.
struct FileSearchMatch: Identifiable, Equatable {
    let id: String              // file_id from Upstage
    let filename: String
    let snippet: String
    let score: Double
    let localURL: URL?          // file:// URL when we still know where it lives locally

    static func == (lhs: FileSearchMatch, rhs: FileSearchMatch) -> Bool {
        lhs.id == rhs.id && lhs.filename == rhs.filename
            && lhs.snippet == rhs.snippet && lhs.score == rhs.score
            && lhs.localURL == rhs.localURL
    }

    /// Convert to a citation for display. Returns `nil` when we can't form a
    /// link (no local file URL and no remote handle to fall back to).
    func toCitation() -> ChatCitation? {
        guard let url = localURL else { return nil }
        return ChatCitation(
            title: filename,
            url: url,
            kind: .file(snippet: snippet)
        )
    }
}

/// Persistent record of one indexed file.
private struct IndexEntry: Codable {
    var relativePath: String
    var size: Int
    /// Modification time in epoch seconds (rounded to int) so JSON round-trips cleanly.
    var mtime: Int
    var fileId: String          // id returned by POST /files
    var status: String          // "in_progress" | "completed" | "failed"
    var lastError: String?
    var indexedAt: Int
}

/// Persistent manifest stored alongside the app's Application Support data.
private struct IndexManifest: Codable {
    var schemaVersion: Int
    var vectorStoreId: String?
    var folderPath: String
    var entries: [IndexEntry]

    static let currentSchema = 1
}

/// Public summary of the indexer's state.
struct FileIndexStatus: Equatable {
    enum Phase: Equatable {
        case idle
        case scanning
        case uploading(current: Int, total: Int)
        case waitingForIndexing(current: Int, total: Int)
        case cleaningUp(current: Int, total: Int)
        case error(String)
    }

    var phase: Phase = .idle
    var totalFiles: Int = 0
    var indexedFiles: Int = 0
    var lastSyncAt: Date?
}

/// Orchestrates the local file index: scans the configured folder, uploads
/// new/changed files via `UpstageFileSearchClient`, removes deleted ones,
/// persists state, and runs queries.
@MainActor
final class FileIndexManager: ObservableObject {
    @Published private(set) var status = FileIndexStatus()
    @Published private(set) var isSyncing = false

    private let storeURL: URL
    private var manifest: IndexManifest
    private var client: UpstageFileSearchClient?
    private var syncTask: Task<Void, Never>?
    private var watcher: FolderWatcher?
    private var watchedFolder: URL?
    private var debounceTask: Task<Void, Never>?
    private var dirtyDuringSync = false

    /// FSEvents may have missed changes while the app was closed; if our last
    /// sync is older than this, kick off a catch-up sync when watching starts.
    private static let staleSyncThreshold: TimeInterval = 5 * 60

    /// FSEvents already coalesces with a 1.5s latency window. We add another
    /// debounce on top so a multi-file drop produces a single sync.
    private static let debounceSeconds: UInt64 = 3

    /// File names we always skip to avoid uploading junk and macOS metadata.
    private static let ignoredNames: Set<String> = [
        ".DS_Store", "Icon\r", "Thumbs.db", ".localized"
    ]

    /// Hard cap below the API limit (500/store) so we always have headroom.
    private static let maxFilesPerStore = 480

    init(storeURL: URL? = nil) {
        let resolved = storeURL ?? FileIndexManager.defaultStoreURL()
        self.storeURL = resolved
        self.manifest = FileIndexManager.loadManifest(from: resolved)
        self.status.totalFiles = manifest.entries.count
        self.status.indexedFiles = manifest.entries.filter { $0.status == "completed" }.count
    }

    /// Default folder we propose: ~/Downloads.
    static func defaultFolderURL() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }

    /// Returns true if file search is configured and at least one file finished
    /// indexing (so a search would have something to match).
    var isReady: Bool {
        client != nil && manifest.vectorStoreId != nil && status.indexedFiles > 0
    }

    var vectorStoreId: String? { manifest.vectorStoreId }

    /// Resolve a Files API `file_id` to a local URL on disk, if we still
    /// have it tracked in the manifest.
    func localURL(forFileId fileId: String) -> URL? {
        guard let entry = manifest.entries.first(where: { $0.fileId == fileId }) else {
            return nil
        }
        return URL(fileURLWithPath: manifest.folderPath).appending(path: entry.relativePath)
    }

    // MARK: - Configuration changes

    /// Update credentials/folder. Triggers re-sync only when the folder changes.
    /// On folder change we also purge the previous folder's files from the
    /// remote vector store + Files API so they don't pollute searches or
    /// silently consume the per-store quota.
    func configure(apiKey: String, folder: URL) async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            client = nil
            stopWatching()
            return
        }
        client = UpstageFileSearchClient(apiKey: trimmed)

        let normalized = folder.standardizedFileURL.path
        if manifest.folderPath != normalized {
            // Cancel any in-flight sync of the OLD folder before purging.
            syncTask?.cancel()
            await syncTask?.value
            syncTask = nil

            await purgeRemoteEntries()

            manifest.folderPath = normalized
            // Reset sync timestamp so the next start triggers a full initial sync.
            status.lastSyncAt = nil
            status.totalFiles = 0
            status.indexedFiles = 0
            status.phase = .idle
            persist()
        }
    }

    /// Delete every tracked file from the remote vector store and Files API,
    /// then clear local entries. Best-effort: individual delete failures are
    /// ignored so a transient network blip doesn't leave us stuck.
    private func purgeRemoteEntries() async {
        let entries = manifest.entries
        guard !entries.isEmpty else { return }

        let total = entries.count
        let vectorStoreId = manifest.vectorStoreId
        let client = self.client

        for (offset, entry) in entries.enumerated() {
            status.phase = .cleaningUp(current: offset + 1, total: total)
            if let client {
                if let vectorStoreId {
                    try? await client.removeFileFromVectorStore(
                        vectorStoreId: vectorStoreId,
                        fileId: entry.fileId
                    )
                }
                try? await client.deleteFile(id: entry.fileId)
            }
        }

        manifest.entries.removeAll()
        persist()
    }

    /// Begin watching the configured folder via FSEvents and run a catch-up
    /// sync if the local index is missing or stale.
    func startWatching(folder: URL) {
        guard client != nil else { return }

        // If we're already watching this folder, just decide whether a
        // catch-up sync is needed.
        let folderChanged = watchedFolder?.standardizedFileURL.path != folder.standardizedFileURL.path

        if folderChanged {
            stopWatching()
        }

        if watcher == nil {
            let watcher = FolderWatcher { [weak self] in
                Task { @MainActor [weak self] in
                    self?.onFolderChanged()
                }
            }
            watcher.start(path: folder.standardizedFileURL.path)
            self.watcher = watcher
            self.watchedFolder = folder
        }

        if shouldRunInitialSync() {
            sync(folder: folder)
        }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        watchedFolder = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func shouldRunInitialSync() -> Bool {
        if manifest.entries.isEmpty { return true }
        guard let last = status.lastSyncAt else { return true }
        return Date().timeIntervalSince(last) > FileIndexManager.staleSyncThreshold
    }

    private func onFolderChanged() {
        guard let folder = watchedFolder else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: FileIndexManager.debounceSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.isSyncing {
                    self.dirtyDuringSync = true
                } else {
                    self.sync(folder: folder)
                }
            }
        }
    }

    // MARK: - Sync

    /// Run a full sync: scan the folder, upload new/changed files, and remove
    /// entries whose local files have disappeared. Folder switches are
    /// handled by `configure()`; this method trusts the manifest is current.
    func sync(folder: URL) {
        guard let client else {
            status.phase = .error("Upstage API key not configured.")
            return
        }
        if isSyncing {
            return
        }
        isSyncing = true
        status.phase = .scanning

        syncTask = Task { [weak self] in
            await self?.performSync(client: client, folder: folder)
        }
    }

    private func performSync(client: UpstageFileSearchClient, folder: URL) async {
        defer {
            Task { @MainActor in
                self.isSyncing = false
                if self.dirtyDuringSync {
                    self.dirtyDuringSync = false
                    self.onFolderChanged()
                }
            }
        }

        // 1. Ensure a vector store exists.
        do {
            try await ensureVectorStore(client: client)
        } catch {
            await MainActor.run { self.status.phase = .error(error.localizedDescription) }
            return
        }
        guard let vectorStoreId = manifest.vectorStoreId else { return }

        // 2. Scan folder for supported files.
        let discovered: [DiscoveredFile]
        do {
            discovered = try scanFolder(folder)
        } catch {
            await MainActor.run { self.status.phase = .error(error.localizedDescription) }
            return
        }

        let discoveredByPath = Dictionary(uniqueKeysWithValues: discovered.map { ($0.relativePath, $0) })

        // 3. Diff: deletions = manifest entries whose path no longer exists or
        //    whose size/mtime changed; uploads = discovered files not in manifest
        //    or with a stale entry.
        var entriesByPath = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.relativePath, $0) })
        var toDelete: [IndexEntry] = []
        var toUpload: [DiscoveredFile] = []

        for entry in manifest.entries {
            if let match = discoveredByPath[entry.relativePath],
               match.size == entry.size, match.mtime == entry.mtime {
                continue // unchanged
            }
            toDelete.append(entry)
            entriesByPath.removeValue(forKey: entry.relativePath)
        }

        for file in discovered where entriesByPath[file.relativePath] == nil {
            toUpload.append(file)
        }

        // Stay safely under the per-store limit.
        if entriesByPath.count + toUpload.count > FileIndexManager.maxFilesPerStore {
            let allowed = max(0, FileIndexManager.maxFilesPerStore - entriesByPath.count)
            toUpload = Array(toUpload.prefix(allowed))
        }

        // 4. Apply deletions.
        for entry in toDelete {
            try? await client.removeFileFromVectorStore(vectorStoreId: vectorStoreId, fileId: entry.fileId)
            try? await client.deleteFile(id: entry.fileId)
            await MainActor.run {
                self.manifest.entries.removeAll { $0.relativePath == entry.relativePath }
                self.persist()
            }
        }

        // 5. Upload new/changed files.
        let totalToUpload = toUpload.count
        for (offset, file) in toUpload.enumerated() {
            await MainActor.run {
                self.status.phase = .uploading(current: offset + 1, total: totalToUpload)
            }
            do {
                let uploaded = try await client.uploadFile(at: file.url)
                let added = try await client.addFileToVectorStore(
                    vectorStoreId: vectorStoreId,
                    fileId: uploaded.id
                )
                let entry = IndexEntry(
                    relativePath: file.relativePath,
                    size: file.size,
                    mtime: file.mtime,
                    fileId: uploaded.id,
                    status: added.status,
                    lastError: added.lastError?.message,
                    indexedAt: Int(Date().timeIntervalSince1970)
                )
                await MainActor.run {
                    self.manifest.entries.append(entry)
                    self.persist()
                }
            } catch {
                // Skip this file; continue with others.
                continue
            }
        }

        // 6. Poll pending entries to "completed" / "failed".
        await pollPending(client: client, vectorStoreId: vectorStoreId)

        // 7. Final state.
        await MainActor.run {
            self.status.totalFiles = self.manifest.entries.count
            self.status.indexedFiles = self.manifest.entries.filter { $0.status == "completed" }.count
            self.status.lastSyncAt = Date()
            self.status.phase = .idle
        }
    }

    private func ensureVectorStore(client: UpstageFileSearchClient) async throws {
        if let id = manifest.vectorStoreId {
            // Best effort: confirm it still exists. If retrieve fails with 404
            // we'll create a fresh one and clear stale entries.
            do {
                _ = try await client.getVectorStore(id: id)
                return
            } catch UpstageFileSearchClient.ClientError.badResponse(404, _) {
                manifest.vectorStoreId = nil
                manifest.entries.removeAll()
                persist()
            } catch {
                // Network error: trust the existing id, surface failures later.
                return
            }
        }

        let store = try await client.createVectorStore(name: "SolarLight File Search")
        await MainActor.run {
            self.manifest.vectorStoreId = store.id
            self.persist()
        }
    }

    private func pollPending(client: UpstageFileSearchClient, vectorStoreId: String) async {
        let pending = manifest.entries.filter { $0.status == "in_progress" }
        guard !pending.isEmpty else { return }

        let total = pending.count
        var done = 0

        // Poll up to ~60s per file with 2s spacing.
        for entry in pending {
            for _ in 0..<30 {
                if Task.isCancelled { return }
                do {
                    let updated = try await client.getVectorStoreFile(
                        vectorStoreId: vectorStoreId,
                        fileId: entry.fileId
                    )
                    if updated.status != "in_progress" {
                        await MainActor.run {
                            if let idx = self.manifest.entries.firstIndex(where: { $0.fileId == entry.fileId }) {
                                self.manifest.entries[idx].status = updated.status
                                self.manifest.entries[idx].lastError = updated.lastError?.message
                                self.persist()
                            }
                        }
                        break
                    }
                } catch {
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            done += 1
            await MainActor.run {
                self.status.phase = .waitingForIndexing(current: done, total: total)
            }
        }
    }

    // MARK: - Search

    /// Run a vector search. Returns matches with local file URLs resolved when
    /// the file is still tracked by this index.
    func search(query: String, maxResults: Int = 5) async throws -> [FileSearchMatch] {
        guard let client else { throw UpstageFileSearchClient.ClientError.missingAPIKey }
        guard let vectorStoreId = manifest.vectorStoreId else { return [] }

        let results = try await client.search(
            vectorStoreId: vectorStoreId,
            query: query,
            maxResults: maxResults
        )

        let folderURL = URL(fileURLWithPath: manifest.folderPath)
        let entriesById = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.fileId, $0) })

        return results.compactMap { result -> FileSearchMatch? in
            guard let id = result.fileId, let filename = result.filename else {
                return nil
            }
            let localURL: URL? = {
                if let entry = entriesById[id] {
                    return folderURL.appending(path: entry.relativePath)
                }
                return nil
            }()
            return FileSearchMatch(
                id: id,
                filename: filename,
                snippet: result.text ?? "",
                score: result.score ?? 0,
                localURL: localURL
            )
        }
    }

    // MARK: - Reset

    /// Wipe local state (does not delete remote vector store or files).
    func clearLocalIndex() {
        manifest = IndexManifest(
            schemaVersion: IndexManifest.currentSchema,
            vectorStoreId: nil,
            folderPath: manifest.folderPath,
            entries: []
        )
        persist()
        status = FileIndexStatus()
    }

    // MARK: - Folder scanning

    private struct DiscoveredFile {
        let url: URL
        let relativePath: String
        let size: Int
        let mtime: Int
    }

    private func scanFolder(_ folder: URL) throws -> [DiscoveredFile] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let contents = try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var results: [DiscoveredFile] = []
        for url in contents {
            let name = url.lastPathComponent
            if FileIndexManager.ignoredNames.contains(name) { continue }

            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard UpstageFileSearchClient.supportedExtensions.contains(ext) else { continue }

            let size = values.fileSize ?? 0
            let mtime = Int((values.contentModificationDate ?? Date()).timeIntervalSince1970)

            results.append(DiscoveredFile(
                url: url,
                relativePath: name, // top-level only — Downloads-scale recursion would be too aggressive.
                size: size,
                mtime: mtime
            ))
        }

        // Deterministic order: oldest first so prioritize older artifacts during cap-trimming.
        results.sort { $0.mtime > $1.mtime }
        return Array(results.prefix(FileIndexManager.maxFilesPerStore))
    }

    // MARK: - Persistence

    private static func defaultStoreURL() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        let dir = support.appending(path: "SolarLight", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "file-index.json")
    }

    private static func loadManifest(from url: URL) -> IndexManifest {
        if let data = try? Data(contentsOf: url),
           let manifest = try? JSONDecoder().decode(IndexManifest.self, from: data) {
            return manifest
        }
        return IndexManifest(
            schemaVersion: IndexManifest.currentSchema,
            vectorStoreId: nil,
            folderPath: FileIndexManager.defaultFolderURL().path,
            entries: []
        )
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            // Persistence failure is logged at the UI layer via subsequent error states.
        }
    }
}
