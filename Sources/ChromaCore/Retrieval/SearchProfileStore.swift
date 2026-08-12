import Foundation

/// Search profiles, kept per collection.
///
/// Local, like every other thing the app remembers about a collection that the
/// collection itself has no room for (2.8). A profile is not data: losing this
/// file costs the tuning of a search, not a single document — which is why the
/// worst case of a file written by a newer build is an empty list rather than a
/// screen that refuses to open.
public final class SearchProfileStore {
    /// The file as it is written now: profiles, plus the collections where the
    /// pipeline is switched off.
    ///
    /// Builds up to 10.8 wrote a bare array. Both shapes are read, because a
    /// file that stops decoding does not announce itself — it answers «профилей
    /// нет» and quietly turns a tuned search back into the default one.
    struct Contents: Codable {
        var profiles: [SearchProfile] = []
        var collectionsWithoutPipeline: [String] = []

        init(profiles: [SearchProfile] = [], collectionsWithoutPipeline: [String] = []) {
            self.profiles = profiles
            self.collectionsWithoutPipeline = collectionsWithoutPipeline
        }

        /// Файл, записанный сборкой до появления выключателя, — это просто
        /// список профилей. Читается и он: иначе профили пропали бы, а
        /// пропавший профиль — это молча изменившийся поиск.
        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self),
               container.contains(.profiles) {
                profiles = try container.decodeIfPresent([SearchProfile].self, forKey: .profiles) ?? []
                collectionsWithoutPipeline = try container.decodeIfPresent(
                    [String].self, forKey: .collectionsWithoutPipeline
                ) ?? []
                return
            }
            profiles = try [SearchProfile](from: decoder)
            collectionsWithoutPipeline = []
        }
    }

    private let file: GuardedJSONFile<Contents>
    private let log: LogHandler
    private var profiles: [SearchProfile]
    /// Collections where «умный поиск» is off: the switch of E0.1 that turns the
    /// whole pipeline back into the plain query of stage 2.
    ///
    /// Off is stored, not on: a collection nobody has touched searches with
    /// whatever its profile says, and the file stays empty until somebody makes
    /// a decision.
    private var collectionsWithoutPipeline: Set<String>

    public init(directory: URL = AppPaths.supportDirectory, log: @escaping LogHandler = noopLogHandler) {
        self.file = GuardedJSONFile(
            url: directory.appendingPathComponent("search-profiles.json"),
            category: "Поиск",
            log: log,
            decoder: { JSONDecoder() },
            encoder: {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                return encoder
            }
        )
        self.log = log
        let contents = file.value(or: Contents())
        self.profiles = contents.profiles
        self.collectionsWithoutPipeline = Set(contents.collectionsWithoutPipeline)
    }

    /// Почему ничего не сохраняется, если это так.
    public var persistenceProblem: String? { file.problem }

    // MARK: - The master switch

    /// Whether the pipeline runs for this collection at all.
    ///
    /// On unless somebody turned it off. The switch exists because a tuned
    /// profile is not always wanted: «покажи, что найдёт обычный поиск» is a
    /// question people ask when a result surprises them, and answering it by
    /// editing six settings and putting them back afterwards is how tuning gets
    /// lost.
    public func isPipelineEnabled(for collectionName: String) -> Bool {
        !collectionsWithoutPipeline.contains(collectionName)
    }

    public func setPipelineEnabled(_ enabled: Bool, for collectionName: String) {
        if enabled {
            collectionsWithoutPipeline.remove(collectionName)
        } else {
            collectionsWithoutPipeline.insert(collectionName)
        }
        persist()
        log(.info, "Поиск", enabled
            ? "Умный поиск включён для коллекции «\(collectionName)»"
            : "Умный поиск выключен для коллекции «\(collectionName)» — запросы идут как на этапе 2")
    }

    /// What a search runs with, given the switch.
    ///
    /// With the pipeline off this is a profile with every optional stage off —
    /// which E0.1 defines as the search of stage 2 exactly. It keeps the chosen
    /// profile's **name**, so the diagnostics panel does not claim a search ran
    /// under settings it ignored.
    public func effectiveProfile(for collectionName: String) -> SearchProfile {
        let profile = defaultProfile(for: collectionName)
        guard !isPipelineEnabled(for: collectionName) else { return profile }
        return SearchProfile.plain(collectionName: collectionName, name: profile.name)
    }

    public func profiles(for collectionName: String) -> [SearchProfile] {
        profiles
            .filter { $0.collectionName == collectionName }
            .sorted { left, right in
                if left.isDefault != right.isDefault { return left.isDefault }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    /// The profile a search uses when the user has not chosen one.
    ///
    /// A collection nobody has tuned gets a profile with every optional stage
    /// off — the search of stage 2, unchanged. It is **not** written to
    /// disk: a file full of untouched defaults would make «этой коллекции
    /// что-то настраивали» unanswerable.
    public func defaultProfile(for collectionName: String) -> SearchProfile {
        profiles(for: collectionName).first { $0.isDefault }
            ?? profiles(for: collectionName).first
            ?? SearchProfile(collectionName: collectionName)
    }

    public func profile(id: UUID) -> SearchProfile? {
        profiles.first { $0.id == id }
    }

    @discardableResult
    public func save(_ profile: SearchProfile) -> SearchProfile {
        var stored = profile
        stored.name = profile.name.trimmingCharacters(in: .whitespaces)
        if stored.name.isEmpty { stored.name = String(localized: "Без названия") }

        if let index = profiles.firstIndex(where: { $0.id == stored.id }) {
            profiles[index] = stored
        } else {
            profiles.append(stored)
        }
        // One default per collection, enforced here rather than hoped for: two
        // defaults would make «какой профиль применился» depend on sort order.
        if stored.isDefault {
            for index in profiles.indices
            where profiles[index].collectionName == stored.collectionName && profiles[index].id != stored.id {
                profiles[index].isDefault = false
            }
        }
        persist()
        log(.info, "Поиск", "Профиль поиска «\(stored.name)» сохранён для коллекции «\(stored.collectionName)»")
        return stored
    }

    public func remove(id: UUID) {
        guard let removed = profiles.first(where: { $0.id == id }) else { return }
        profiles.removeAll { $0.id == id }
        // Removing the default leaves the collection without one; the oldest
        // remaining profile takes over rather than the search silently falling
        // back to untuned defaults.
        if removed.isDefault,
           let next = profiles.firstIndex(where: { $0.collectionName == removed.collectionName }) {
            profiles[next].isDefault = true
        }
        persist()
        log(.info, "Поиск", "Профиль поиска «\(removed.name)» удалён")
    }

    /// Profiles of a collection that no longer exists are of no use to anyone.
    public func removeAll(forCollection collectionName: String) {
        profiles.removeAll { $0.collectionName == collectionName }
        // And the switch with them: a collection recreated under the same name
        // should not inherit «умный поиск выключен» from a previous one.
        collectionsWithoutPipeline.remove(collectionName)
        persist()
    }

    public func all() -> [SearchProfile] { profiles }

    /// Replaces the whole list, for an import already shown and confirmed.
    public func replaceAll(_ replacement: [SearchProfile]) {
        profiles = replacement
        persist()
    }

    // MARK: - Export and import

    /// A profile as a portable file. Together with the query sets of D1 this is
    /// what makes a tuned search transferable to another machine.
    public func exportData(_ subject: [SearchProfile]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(subject)
    }

    /// Profiles read from a file, retargeted at a collection.
    ///
    /// New ids, because the file may have come from a machine where these
    /// profiles still exist: importing must add, never overwrite something the
    /// user did not name. `isDefault` is dropped for the same reason — an
    /// import should not silently replace which profile a collection searches
    /// with.
    public func importing(_ data: Data, into collectionName: String) throws -> [SearchProfile] {
        let decoded = try JSONDecoder().decode([SearchProfile].self, from: data)
        return decoded.map { profile in
            var copy = profile
            copy.id = UUID()
            copy.collectionName = collectionName
            copy.isDefault = false
            return copy
        }
    }

    private func persist() {
        file.write(Contents(
            profiles: profiles,
            collectionsWithoutPipeline: collectionsWithoutPipeline.sorted()
        ))
    }
}
