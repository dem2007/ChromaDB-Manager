import Foundation

/// Что лежит на каждом уровне вложенности папки источника.
///
/// Нужно двум разным разговорам, и оба про одно и то же дерево:
/// редактору источника — чтобы человек называл уровни, **видя** их («уровень 1
/// — две папки: 2025, 2026»), а синхронизации — чтобы заметить уровень глубже
/// названных и сказать о нём вместо того, чтобы молча потерять смысл папок.
///
/// Считается по относительным путям **подходящих файлов**, а не обходом всех
/// каталогов: папка, в которой нет ни одного индексируемого файла, уровнем
/// не является — её содержимое в базу не попадает, и предлагать назвать её
/// значило бы спрашивать о том, чего не будет.
/// Уровень вложенности, которому никто не давал имени.
///
/// Появляется сам: в папку добавили ещё одну ступень — «Системы/2025/Система
/// 1/**договоры**/…», — и смысл этой ступени в базу не попадает. Приложение
/// не выдумывает ей имя (`level_4` в метаданных всей коллекции — мусор,
/// который никто не заказывал) и не делает работы: оно говорит, что уровень
/// появился, и ждёт. То же правило, что у и у исчезнувших файлов.
public struct NewFolderLevel: Codable, Hashable, Sendable, Identifiable {
    public var number: Int
    public var id: Int { number }
    public var folderCount: Int
    public var examples: [String]

    public init(number: Int, folderCount: Int, examples: [String]) {
        self.number = number
        self.folderCount = folderCount
        self.examples = examples
    }
}

public struct FolderLevels: Sendable, Hashable {
    public struct Level: Sendable, Hashable, Identifiable {
        /// Номер уровня, считая от папки источника: 1 — её прямые подпапки.
        public var number: Int
        public var id: Int { number }
        /// Сколько **разных** имён папок встретилось на этом уровне.
        public var folderCount: Int
        /// Сами имена, по алфавиту, — не больше `namesKept`.
        ///
        /// Нужны для одной проверки, которую иначе делать не на чем: уровень
        /// объявили числом, а половина папок называется словами. Ответить на это
        /// можно только посмотрев на имена, и лучше в редакторе, чем в базе.
        public var names: [String]
        /// Имён на уровне больше, чем сохранено: проверка типа считалась
        /// по части, и говорить «все разбираются» уже нельзя.
        public var namesTruncated: Bool
        /// Файлов, которые до этого уровня не достают (лежат выше).
        ///
        /// Это и есть ответ на вопрос «можно ли обещать схеме коллекции поле
        /// с этого уровня»: ноль — поле будет у каждого чанка, больше нуля —
        /// у стольких-то файлов его не будет, и это надо сказать до прогона,
        /// а не после.
        public var filesAbove: Int

        public init(
            number: Int, folderCount: Int, names: [String],
            namesTruncated: Bool = false, filesAbove: Int
        ) {
            self.number = number
            self.folderCount = folderCount
            self.names = names
            self.namesTruncated = namesTruncated
            self.filesAbove = filesAbove
        }

        /// Несколько имён для показа — этого хватает, чтобы человек узнал
        /// свою папку и понял, о каком уровне идёт речь.
        public var examples: [String] { Array(names.prefix(examplesShown)) }

        /// Имена, которые к этому типу не приводятся: «архив» в числовом поле.
        public func namesNotMatching(_ level: PathLevel) -> [String] {
            names.filter { level.value(for: $0) == nil }
        }
    }

    public var levels: [Level]
    public var fileCount: Int
    /// Несколько настоящих путей для предпросмотра: показать, что получится,
    /// на выдуманном `folder/file.txt` — значит показать не то.
    public var samplePaths: [String]
    /// Дерево глубже, чем можно назвать (`PathLevel.maximumLevels`).
    public var deeperThanLimit: Bool

    public init(
        levels: [Level] = [], fileCount: Int = 0,
        samplePaths: [String] = [], deeperThanLimit: Bool = false
    ) {
        self.levels = levels
        self.fileCount = fileCount
        self.samplePaths = samplePaths
        self.deeperThanLimit = deeperThanLimit
    }

    public var isEmpty: Bool { levels.isEmpty }
    /// Самый глубокий уровень, на котором есть папки.
    public var depth: Int { levels.count }

    /// Сколько имён показывать в примере одного уровня.
    public static let examplesShown = 4
    /// Сколько имён хранить на уровень. Их обычно десятки; предел стоит
    /// на случай папки с годами по дням — держать в памяти экрана редактора
    /// сто тысяч строк ради проверки типа незачем.
    public static let namesKept = 2_000

    /// Уровни, до которых настройки источника не дотягиваются.
    ///
    /// Только те, что **глубже** списка уровней источника: пропущенный
    /// посередине уровень — осознанный выбор человека («год не нужен»),
    /// и напоминать о нём каждый прогон значит спорить с его решением.
    /// Пустой список уровней у источника — молчание: он полями из пути
    /// не пользуется, и подпапки есть у кого угодно.
    public func unnamed(beyond named: Int) -> [NewFolderLevel] {
        guard named > 0 else { return [] }
        return levels
            .filter { $0.number > named && $0.number <= PathLevel.maximumLevels }
            .map { NewFolderLevel(number: $0.number, folderCount: $0.folderCount, examples: $0.examples) }
    }

    /// Уровни по относительным путям файлов.
    ///
    /// Чистая функция: то же самое дерево, посчитанное дважды, обязано дать
    /// одинаковый ответ — иначе редактор и синхронизация будут спорить о том,
    /// сколько в папке уровней.
    public static func of(paths: [String], depthLimit: Int = PathLevel.maximumLevels + 4) -> FolderLevels {
        var namesByLevel: [Int: Set<String>] = [:]
        var filesByDepth: [Int: Int] = [:]
        // По одному примеру на глубину, а не все пути подряд: в папке бывает
        // сто тысяч файлов, и держать их копию ради четырёх строк предпросмотра
        // — это лишний список размером с саму папку.
        var sampleByDepth: [Int: String] = [:]
        var deepest = 0

        for path in paths {
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty else { continue }
            let folders = trimmed.split(separator: "/").map(String.init).dropLast()
            filesByDepth[folders.count, default: 0] += 1
            deepest = max(deepest, folders.count)
            for (index, folder) in folders.enumerated() where index < depthLimit {
                namesByLevel[index + 1, default: []].insert(folder)
            }
            // Пример на каждую глубину — первый по алфавиту, чтобы список
            // не менялся от порядка обхода файловой системы.
            if let existing = sampleByDepth[folders.count] {
                if trimmed < existing { sampleByDepth[folders.count] = trimmed }
            } else {
                sampleByDepth[folders.count] = trimmed
            }
        }

        let counted = min(deepest, depthLimit)
        var levels: [Level] = []
        for number in 1...max(counted, 1) where counted >= 1 {
            let names = namesByLevel[number] ?? []
            guard !names.isEmpty else { continue }
            // «Выше уровня» — файлы, у которых папок меньше, чем номер уровня.
            let above = filesByDepth.filter { $0.key < number }.values.reduce(0, +)
            let sorted = names.sorted()
            levels.append(Level(
                number: number,
                folderCount: names.count,
                names: Array(sorted.prefix(namesKept)),
                namesTruncated: sorted.count > namesKept,
                filesAbove: above
            ))
        }

        // Показываются самые глубокие пути: по ним видно все уровни сразу,
        // а по файлу из корня не видно ни одного.
        let samples = sampleByDepth.keys.sorted(by: >).prefix(examplesShown)
            .compactMap { sampleByDepth[$0] }
        return FolderLevels(
            levels: levels,
            fileCount: paths.count,
            samplePaths: samples,
            deeperThanLimit: deepest > PathLevel.maximumLevels
        )
    }
}
