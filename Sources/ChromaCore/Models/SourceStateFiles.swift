import Foundation

/// Файлы состояния источника в папке манифестов.
///
/// У источника их до четырёх: манифест файлов, манифест таблиц и по прежней
/// версии каждого. Удаление источника стирало только первый — от шести
/// удалённых источников на диске оставалось 37 МБ. Теперь каждое хранилище
/// стирает свой файл с прежней версией само; здесь — то, что осталось от
/// источников, удалённых прежними сборками, и стирается кнопкой.
public enum SourceStateFiles {
    /// Файлы источников, которых нет в настройках, и сколько они весят.
    ///
    /// Сами они не удаляются никогда: настройки умеют потерять источники
    /// (на этот случай и снимок «что исчезло»), и тогда эти файлы — способ
    /// вернуть источник без переиндексации. Удаляет их человек, кнопкой.
    public static func orphans(
        keeping sourceIDs: Set<UUID>, in directory: URL = AppPaths.manifestsDirectory
    ) -> (files: [URL], bytes: Int64) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var files: [URL] = []
        var bytes: Int64 = 0
        for name in names {
            guard name.count >= 36, let id = UUID(uuidString: String(name.prefix(36))),
                  !sourceIDs.contains(id) else { continue }
            let url = directory.appendingPathComponent(name)
            files.append(url)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
            bytes += size
        }
        return (files, bytes)
    }

    public static func remove(_ files: [URL]) {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
