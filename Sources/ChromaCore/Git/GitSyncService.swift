import Foundation

/// Готовит git-репозиторий к синхронизации.
///
/// Как и у веба, обход кончается здесь: план получается тот же самый `SyncPlan`,
/// и дальше идут общий журнал, общий манифест и общая запись. Разница только
/// в том, **у кого спрашивать**, что изменилось: у файловой системы или у git.
public final class GitSyncService {
    /// Состояние репозитория на сейчас — чтобы экран и автоматический запуск
    /// могли принять решение, ничего не индексируя.
    public struct Status: Sendable, Hashable {
        public var hasGit: Bool
        public var isRepository: Bool
        public var branch: String?
        public var commit: String?
        public var previousBranch: String?
        public var previousCommit: String?
        public var changedFiles: Int?

        /// Ветку переключили с прошлой синхронизации.
        ///
        /// Переиндексацию это **не** запускает: смена ветки — обычное рабочее
        /// действие, а переиндексация репозитория стоит часов работы модели
        ///.
        public var branchChanged: Bool {
            guard let branch, let previousBranch, !previousBranch.isEmpty else { return false }
            return branch != previousBranch
        }

        public var branchChangeNote: String? {
            guard branchChanged, let previousBranch, let branch else { return nil }
            guard let changedFiles else {
                return String(localized: "Ветка сменилась: \(previousBranch) → \(branch). Индексация сама не запускается — запустите её, когда сочтёте нужным.")
            }
            return String(localized: "Ветка сменилась: \(previousBranch) → \(branch), изменившихся файлов \(changedFiles.plainDigits). Индексация сама не запускается — запустите её, когда сочтёте нужным.")
        }
    }

    public struct Preparation {
        public var plan: SyncPlan
        public var state: GitSourceState
        public var status: Status
        /// Файлы, переименованные с прошлой синхронизации: старый путь → новый.
        /// Их чанки надо перенести **до** записи, чтобы не считать векторы
        /// заново.
        public var renames: [(from: String, to: String)]
        /// Git не установлен — источник работает как обычная папка, и человеку
        /// об этом сказано.
        public var degradedReason: String?
    }

    private let registry: ExtractorRegistry
    private let states: GitStateStore
    private let fileManager = FileManager.default
    private let makeRepository: (URL) -> GitRepository?
    private let log: LogHandler

    public init(
        registry: ExtractorRegistry = .standard(),
        states: GitStateStore = GitStateStore(),
        makeRepository: @escaping (URL) -> GitRepository? = { GitRepository(root: $0) },
        log: @escaping LogHandler = noopLogHandler
    ) {
        self.registry = registry
        self.states = states
        self.makeRepository = makeRepository
        self.log = log
    }

    public func state(sourceID: UUID) -> GitSourceState { states.load(sourceID: sourceID) }
    public func save(_ state: GitSourceState, sourceID: UUID) { states.save(state, sourceID: sourceID) }
    public func forget(sourceID: UUID) { states.remove(sourceID: sourceID) }

    // MARK: - Состояние

    /// Спрашивает у git, что происходит, ничего не индексируя.
    public func status(of source: DataSource) async -> Status {
        let previous = states.load(sourceID: source.id)
        guard let settings = source.git else {
            return Status(
                hasGit: GitRepository.isInstalled(), isRepository: false,
                branch: nil, commit: nil,
                previousBranch: previous.branch, previousCommit: previous.commit,
                changedFiles: nil
            )
        }
        guard let repository = makeRepository(source.url) else {
            return Status(
                hasGit: false, isRepository: false, branch: nil, commit: nil,
                previousBranch: previous.branch, previousCommit: previous.commit, changedFiles: nil
            )
        }
        guard await repository.isRepository() else {
            return Status(
                hasGit: true, isRepository: false, branch: nil, commit: nil,
                previousBranch: previous.branch, previousCommit: previous.commit, changedFiles: nil
            )
        }

        let branch = try? await repository.currentBranch()
        let commit = try? await repository.headCommit()
        var changed: Int?
        if let previousCommit = previous.commit {
            changed = (try? await repository.changes(
                since: previousCommit, includeWorkingCopy: settings.indexesWorkingCopy
            ))?.count
        }
        return Status(
            hasGit: true, isRepository: true, branch: branch, commit: commit ?? nil,
            previousBranch: previous.branch, previousCommit: previous.commit, changedFiles: changed
        )
    }

    // MARK: - План

    public enum GitSyncError: LocalizedError {
        case notGit(String)

        public var errorDescription: String? {
            switch self {
            case .notGit(let name):
                return String(localized: "Источник «\(name)» — не git-репозиторий.")
            }
        }
    }

    /// Строит план по ответам git.
    ///
    /// Возвращает `nil`, когда индексировать надо обычным обходом папки: git не
    /// установлен или в папке нет репозитория. Это деградация, а не отказ, и
    /// причина уезжает наверх словами.
    public func prepare(
        source: DataSource,
        embeddingModel: String,
        manifest: SourceManifest,
        progress: ((_ processed: Int, _ total: Int, _ current: String) -> Void)? = nil
    ) async throws -> Preparation? {
        guard let settings = source.git else { throw GitSyncError.notGit(source.name) }

        guard let repository = makeRepository(source.url) else {
            log(.warning, "Git", "Источник «\(source.name)»: git не установлен — индексируется как обычная папка")
            return Preparation(
                plan: SyncPlan(sourceID: source.id, sourceName: source.name, items: [], newlyMissing: [], pendingRemovals: manifest.pendingRemovals),
                state: states.load(sourceID: source.id),
                status: Status(hasGit: false, isRepository: false),
                renames: [],
                degradedReason: GitRepository.GitError.notInstalled.localizedDescription
            )
        }
        guard await repository.isRepository() else {
            log(.warning, "Git", "Источник «\(source.name)»: в папке нет репозитория — индексируется как обычная папка")
            return Preparation(
                plan: SyncPlan(sourceID: source.id, sourceName: source.name, items: [], newlyMissing: [], pendingRemovals: manifest.pendingRemovals),
                state: states.load(sourceID: source.id),
                status: Status(hasGit: true, isRepository: false),
                renames: [],
                degradedReason: GitRepository.GitError.notARepository(source.path).localizedDescription
            )
        }

        let previous = states.load(sourceID: source.id)
        let branch = (try? await repository.currentBranch()) ?? ""
        let commit = (try? await repository.headCommit()) ?? nil

        // Перечень — у git, а не у файловой системы: он сам учитывает
        // `.gitignore`, не заходит в `.git` и не видит неотслеживаемый мусор.
        let listed = try await repository.listFiles(includeUntracked: settings.indexesWorkingCopy)
        let excluded = Set(source.excludedPaths)
        let files = listed.filter { path in
            guard !excluded.contains(path) else { return false }
            guard !settings.excludes(path) else { return false }
            guard !source.fileExtensions.isEmpty else { return true }
            return source.fileExtensions.contains((path as NSString).pathExtension.lowercased())
        }

        // Что трогали с прошлого раза — один вызов вместо десятков тысяч чтений.
        var touched: Set<String>?
        var renames: [(from: String, to: String)] = []
        if let previousCommit = previous.commit, previousCommit != commit || settings.indexesWorkingCopy {
            if let changes = try? await repository.changes(
                since: previousCommit, includeWorkingCopy: settings.indexesWorkingCopy
            ) {
                var names: Set<String> = []
                for change in changes {
                    names.insert(change.path)
                    if case .renamed(let from) = change.kind {
                        names.insert(from)
                        // Переносить есть что только у файла, который в базе уже
                        // есть под старым именем.
                        if manifest.entries[from] != nil { renames.append((from: from, to: change.path)) }
                    }
                }
                touched = names
            }
        } else if previous.commit == commit, previous.commit != nil, !settings.indexesWorkingCopy {
            // Коммит тот же и рабочая копия не в счёт: не трогали ничего.
            touched = []
        }

        let signature = source.chunking.signature
        let extractionSignature = source.extractionSignature
        var items: [SyncPlanItem] = []
        // Переименованный файл в манифесте окажется уже под новым именем —
        // перенос идёт до записи, и план должен считать так же.
        var known = manifest.entries
        for rename in renames {
            if let entry = known.removeValue(forKey: rename.from) {
                var moved = entry
                moved.relativePath = rename.to
                known[rename.to] = moved
            }
        }

        for (index, path) in files.enumerated() {
            if Task.isCancelled { throw SyncError.cancelled }
            progress?(index, files.count, path)

            let url = source.url.appendingPathComponent(path)
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes?[.modificationDate] as? Date) ?? Date()
            guard fileManager.fileExists(atPath: url.path) else {
                // `ls-files` знает файл, а на диске его нет: так бывает при
                // незавершённом checkout. Не беда молча, а причина.
                items.append(SyncPlanItem(
                    relativePath: path, url: url,
                    kind: .skipped(reason: String(localized: "файл числится в репозитории, но его нет на диске"), remedy: .retry),
                    collectionName: source.collectionName, size: 0, modifiedAt: modified
                ))
                continue
            }

            let entry = known[path]
            let recipeMismatch = Self.recipeMismatch(
                entry: entry, signature: signature, embeddingModel: embeddingModel,
                extractionSignature: extractionSignature, collectionName: source.collectionName
            )
            let metadata = await Self.metadata(
                path: path, branch: branch, commit: commit,
                info: settings.includesCommitInfo ? try? await repository.fileInfo(path: path) : nil
            )

            // Вот ради чего всё: git сказал, что файл не трогали, — значит, его
            // не надо ни читать, ни хэшировать, ни извлекать.
            if let touched, !touched.contains(path), entry != nil, recipeMismatch == nil {
                items.append(SyncPlanItem(
                    relativePath: path, url: url, kind: .unchanged,
                    collectionName: source.collectionName, size: size, modifiedAt: modified,
                    contentHash: entry?.contentHash, routeMetadata: metadata
                ))
                continue
            }

            do {
                let extracted = try await registry.extract(
                    from: url,
                    options: SourceSyncService.extractionOptions(for: source)
                )
                let hash = SourceSyncService.contentHash(of: extracted.plainText)
                let kind: SyncItemKind
                switch SyncDecisionRules.decideRead(entry: entry, contentHash: hash, recipeMismatch: recipeMismatch) {
                case .new: kind = .new
                case .reindex(let reason): kind = .changed(reason: reason)
                case .touch, .skip, .needsReextraction: kind = .unchanged
                }
                items.append(SyncPlanItem(
                    relativePath: path, url: url, kind: kind,
                    collectionName: source.collectionName, size: size, modifiedAt: modified,
                    contentHash: hash, textLength: extracted.plainText.count, routeMetadata: metadata
                ))
            } catch {
                items.append(SyncPlanItem(
                    relativePath: path, url: url,
                    kind: .skipped(
                        reason: SourceSyncService.reason(for: error),
                        remedy: FileProblem.remedy(for: error)
                    ),
                    collectionName: source.collectionName, size: size, modifiedAt: modified,
                    routeMetadata: metadata
                ))
            }
        }

        // Файл, исчезнувший из репозитория, из базы не удаляется сам —
        // общее правило 8.4 и правило 1 приложения 5.
        let planned = Set(items.map(\.relativePath))
        var newlyMissing: [PendingRemoval] = []
        var pendingRemovals = manifest.pendingRemovals
        for (path, entry) in known where !planned.contains(path) {
            guard !entry.isOrphaned else { continue }
            guard !pendingRemovals.contains(where: { $0.relativePath == path }) else { continue }
            let removal = PendingRemoval(
                relativePath: path, collectionName: entry.collectionName, chunkIDs: entry.chunkIDs
            )
            newlyMissing.append(removal)
            pendingRemovals.append(removal)
        }

        let status = Status(
            hasGit: true, isRepository: true, branch: branch, commit: commit,
            previousBranch: previous.branch, previousCommit: previous.commit,
            changedFiles: touched?.count
        )
        let plan = SyncPlan(
            sourceID: source.id, sourceName: source.name,
            items: items.sorted { $0.relativePath < $1.relativePath },
            newlyMissing: newlyMissing, pendingRemovals: pendingRemovals
        )
        log(.info, "Git", "Источник «\(source.name)» (\(branch)): файлов \(files.count.plainDigits), к записи \(plan.writeItems.count.plainDigits), переименований \(renames.count.plainDigits)")
        return Preparation(
            plan: plan,
            state: GitSourceState(commit: commit, branch: branch, syncedAt: Date()),
            status: status,
            renames: renames,
            degradedReason: nil
        )
    }

    // MARK: - Мелочи

    static func metadata(path: String, branch: String, commit: String?, info: GitFileInfo?) async -> ChromaMetadata {
        var metadata: ChromaMetadata = ["git_relative_path": .string(path)]
        if !branch.isEmpty { metadata["git_branch"] = .string(branch) }
        if let commit, !commit.isEmpty { metadata["git_commit"] = .string(commit) }
        if let info {
            metadata["last_commit_date"] = .string(info.lastCommitDate)
            metadata["last_commit_author"] = .string(info.lastCommitAuthor)
        }
        return metadata
    }

    static func recipeMismatch(
        entry: ManifestEntry?, signature: String, embeddingModel: String,
        extractionSignature: String, collectionName: String
    ) -> String? {
        guard let entry else { return nil }
        if entry.chunkingSignature != signature { return String(localized: "изменились параметры чанкинга") }
        if entry.embeddingModel != embeddingModel { return String(localized: "сменилась модель эмбеддинга") }
        if !entry.extractionSignature.isEmpty, entry.extractionSignature != extractionSignature {
            return String(localized: "изменились параметры извлечения")
        }
        if entry.collectionName != collectionName { return String(localized: "сменилась коллекция назначения") }
        return nil
    }
}
