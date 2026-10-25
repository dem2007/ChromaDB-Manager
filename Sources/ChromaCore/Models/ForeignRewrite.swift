import Foundation

/// Настройки переписала другая сборка приложения.
///
/// 16 октября запуск августовских копий (v7, v10) переписал `config.json`:
/// они не знают полей из пути, и уровни пропали у всех источников разом.
/// Защита этого не видела — она считает исчезнувшие **записи**
/// (источники, клиентов, профили), а здесь записи остались, исчезло их
/// содержимое. А следом «обновить поля» сняло эти поля и с чанков.
///
/// Поэтому приложение держит копию того, что записало само последним
/// (`config.own.json`, — старые сборки о ней не знают и не трогают), и при
/// запуске сверяет с ней файл: ручная работа, которой в файле больше нет,
/// называется и возвращается одной кнопкой.
public struct ForeignRewrite: Sendable, Hashable {
    /// Что пропало — строками для экрана и журнала.
    public var lost: [String]

    public var isEmpty: Bool { lost.isEmpty }

    /// Ручная работа, которая есть в своей копии и которой нет в файле.
    public static func between(own: AppConfiguration, current: AppConfiguration) -> ForeignRewrite {
        var lost: [String] = []
        let currentSources = Dictionary(current.dataSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for source in own.dataSources {
            guard let now = currentSources[source.id] else {
                lost.append(String(localized: "источник «\(source.name)»"))
                continue
            }
            var fields: [String] = []
            let ownLevels = source.pathLevels.filter(\.isNamed).count
            if ownLevels > 0, now.pathLevels.filter(\.isNamed).isEmpty {
                fields.append(String(localized: "поля из пути (\(ownLevels))"))
            }
            if !source.customMetadata.isEmpty, now.customMetadata.isEmpty {
                fields.append(String(localized: "свои поля (\(source.customMetadata.count))"))
            }
            if !source.tableProfiles.isEmpty, now.tableProfiles.isEmpty {
                fields.append(String(localized: "профили таблиц (\(source.tableProfiles.count))"))
            }
            if !source.tableProfileAssignments.isEmpty, now.tableProfileAssignments.isEmpty {
                fields.append(String(localized: "назначения профилей (\(source.tableProfileAssignments.count))"))
            }
            if !source.excludedPaths.isEmpty, now.excludedPaths.isEmpty {
                fields.append(String(localized: "исключённые файлы (\(source.excludedPaths.count))"))
            }
            if !fields.isEmpty {
                lost.append(String(localized: "«\(source.name)»: \(fields.joined(separator: ", "))"))
            }
        }
        let shared = Set(current.sharedTableProfiles.map(\.id))
        let lostShared = own.sharedTableProfiles.filter { !shared.contains($0.id) }.count
        if lostShared > 0 { lost.append(String(localized: "общие профили таблиц (\(lostShared))")) }
        let clients = Set(current.externalClients.map(\.id))
        let lostClients = own.externalClients.filter { !clients.contains($0.id) }.count
        if lostClients > 0 { lost.append(String(localized: "клиенты (\(lostClients))")) }
        let servers = Set(current.serverProfiles.map(\.id))
        let lostServers = own.serverProfiles.filter { !servers.contains($0.id) }.count
        if lostServers > 0 { lost.append(String(localized: "подключения (\(lostServers))")) }
        return ForeignRewrite(lost: lost)
    }

    /// Файл, в который возвращено пропавшее. Остальное — как в файле:
    /// возвращается только то, чего в нём нет вовсе, и ничего, что в нём
    /// изменили, не затирается.
    public static func restored(_ current: AppConfiguration, from own: AppConfiguration) -> AppConfiguration {
        var result = current
        for source in own.dataSources {
            guard let index = result.dataSources.firstIndex(where: { $0.id == source.id }) else {
                result.dataSources.append(source)
                continue
            }
            var now = result.dataSources[index]
            if now.pathLevels.filter(\.isNamed).isEmpty, !source.pathLevels.filter(\.isNamed).isEmpty {
                now.pathLevels = source.pathLevels
            }
            if now.customMetadata.isEmpty { now.customMetadata = source.customMetadata }
            if now.tableProfiles.isEmpty { now.tableProfiles = source.tableProfiles }
            if now.tableProfileAssignments.isEmpty { now.tableProfileAssignments = source.tableProfileAssignments }
            if now.excludedPaths.isEmpty { now.excludedPaths = source.excludedPaths }
            result.dataSources[index] = now
        }
        let shared = Set(result.sharedTableProfiles.map(\.id))
        result.sharedTableProfiles += own.sharedTableProfiles.filter { !shared.contains($0.id) }
        let clients = Set(result.externalClients.map(\.id))
        result.externalClients += own.externalClients.filter { !clients.contains($0.id) }
        let servers = Set(result.serverProfiles.map(\.id))
        result.serverProfiles += own.serverProfiles.filter { !servers.contains($0.id) }
        return result
    }
}
