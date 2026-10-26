import SwiftUI
import AppKit
import ChromaCore

/// «Место на диске» на экране «Состояние».
///
/// Устроено как «Хранилище» macOS: сверху — сколько всего и полоса по
/// частям, ниже — по строке на часть. В строке три колонки, и у каждой своё
/// дело: слева что это (цвет из полосы, название, пояснение мелко), справа —
/// размер, одной колонкой на всю секцию, и последней — переход туда, где эту
/// часть уменьшают. Раньше размер, пояснение и ссылка стояли одной строкой
/// вперемешку, и колонку чисел глазу было не собрать.
///
/// Сам экран ничего не удаляет: удаление живёт на экране своей части, со
/// своими вопросами.
struct DiskUsageSection: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var diskUsage: DiskUsageViewModel
    @ObservedObject var environment: EnvironmentViewModel
    /// Объём кэша, по которому он держит свой предел (`Statistics.fileBytes`),
    /// — без журнала SQLite, который в обходе папки тоже виден.
    var cacheFileBytes: Int64?
    var go: (SidebarSection, Int?) -> Void
    @State private var showsServiceParts = false

    /// Часть приложения — строкой и долей полосы.
    private struct Part: Identifiable {
        let id: String
        let color: Color
        let title: String
        let detail: String?
        let bytes: Int64?
        /// Прочитано не всё: размер — нижняя граница.
        var unreadable = false
        var reveal: URL?
        var open: (() -> Void)?
        var openTitle: String?
    }

    var body: some View {
        Section {
            summary
            if let report = diskUsage.report {
                ForEach(parts(report)) { part in
                    row(part)
                }
                serviceRow(report)
                if showsServiceParts {
                    ForEach(Self.serviceGroups(report.serviceParts), id: \.title) { group in
                        HStack {
                            Text(group.title)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 19)
                            Spacer()
                            sizeText(group.bytes)
                            trailingSlot { EmptyView() }
                        }
                    }
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text("Место на диске")
                Spacer()
                if diskUsage.isMeasuring { ProgressView().controlSize(.small) }
                Button(String(localized: "Пересчитать")) { diskUsage.measure(app) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(diskUsage.isMeasuring)
                InfoButton(String(localized: "Объём файлов приложения по частям. Удалить что-то можно на экране этой части — переход стоит в её строке."))
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let report = diskUsage.report {
                    Text("Посчитано в \(report.measuredAt.formatted(date: .omitted, time: .shortened)).")
                }
                // Здесь, а не в подсказке: число без этой оговорки пугает
                // зря — 17 ГБ копий могут не занимать и половины.
                Text("Резервные копии снимаются клонированием APFS: пока база не менялась, копия делит с ней место, и на деле занято меньше, чем объём файлов. Сколько занято точно, видно по свободному месту.")
            }
        }
        .monospacedDigit()
    }

    // MARK: - Сверху: всего и полоса

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Приложение занимает")
                Spacer()
                if let report = diskUsage.report {
                    Text(Self.bytes(report.totalBytes))
                        .font(.title3.weight(.semibold))
                } else {
                    Text("считается…").foregroundStyle(.secondary)
                }
            }
            if let report = diskUsage.report {
                bar(parts(report) + [servicePart(report)])
                HStack {
                    Text(freeText(report))
                        .foregroundStyle(report.nextBackupFits == false ? Color.orange : Color.secondary)
                    Spacer()
                }
                .font(.callout)
            }
        }
        .padding(.vertical, 4)
    }

    /// Доли частей — по объёму, каждая своим цветом, как метка в её строке.
    private func bar(_ parts: [Part]) -> some View {
        let shown = parts.filter { ($0.bytes ?? 0) > 0 }
        return GeometryReader { geometry in
            let gaps = CGFloat(max(0, shown.count - 1)) * 2
            let widths = Self.segmentWidths(shown.map { $0.bytes ?? 0 }, in: max(0, geometry.size.width - gaps))
            HStack(spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, part in
                    Rectangle()
                        .fill(part.color)
                        .frame(width: widths[index])
                        .help("\(part.title): \(Self.bytes(part.bytes ?? 0))")
                }
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }

    /// Доли полосы: крошечная часть получает хотя бы несколько точек, чтобы
    /// её было видно, — но за счёт крупных, а не сверх ширины полосы: иначе
    /// хвост выталкивался за край и обрезался.
    static func segmentWidths(_ values: [Int64], in width: CGFloat, minimum: CGFloat = 3) -> [CGFloat] {
        let total = values.reduce(0, +)
        guard total > 0, width > 0 else { return values.map { _ in 0 } }
        let proportional = values.map { width * CGFloat($0) / CGFloat(total) }
        // Закреплённые на минимуме отнимают место у остальных, и после
        // сжатия под минимум может уйти та, что была чуть выше него, —
        // поэтому закрепляем, пока набор не перестанет расти.
        var pinned = Set<Int>()
        while true {
            let reserved = minimum * CGFloat(pinned.count)
            let freeTotal = proportional.indices.filter { !pinned.contains($0) }.reduce(CGFloat(0)) { $0 + proportional[$1] }
            guard reserved < width, freeTotal > 0 else { return proportional }
            let scale = (width - reserved) / freeTotal
            let more = proportional.indices.filter { !pinned.contains($0) && proportional[$0] * scale < minimum }
            if more.isEmpty {
                return proportional.indices.map { pinned.contains($0) ? minimum : proportional[$0] * scale }
            }
            pinned.formUnion(more)
        }
    }

    private func freeText(_ report: DiskUsageReport) -> String {
        var text = report.freeBytes.map { String(localized: "Свободно на диске: \(Self.bytes($0))") }
            ?? String(localized: "Свободное место неизвестно")
        if let other = report.databaseVolumeFreeBytes {
            text += String(localized: " · на томе базы: \(Self.bytes(other))")
        }
        if report.nextBackupFits == false {
            text += String(localized: " — следующая копия базы не поместится")
        }
        return text
    }

    // MARK: - Строки

    private func parts(_ report: DiskUsageReport) -> [Part] {
        let complete = environment.backups.filter { !$0.isIncomplete }
        var backupDetail = complete.isEmpty
            ? String(localized: "копий нет")
            : RussianCount.grouped(complete.count, "копия", "копии", "копий")
        if complete.count > 1, let oldest = complete.min(by: { $0.createdAt < $1.createdAt }) {
            backupDetail += String(localized: ", самая старая — \(oldest.createdAt.formatted(.relative(presentation: .named)))")
        }
        var engine: [String] = []
        if let binary = report.engineBinaryBytes { engine.append(String(localized: "отдельная программа \(Self.bytes(binary))")) }
        if let venv = report.engineVenvBytes { engine.append(String(localized: "окружение Python \(Self.bytes(venv))")) }
        let engineBytes: Int64? = (report.engineBinaryBytes == nil && report.engineVenvBytes == nil)
            ? nil : (report.engineBinaryBytes ?? 0) + (report.engineVenvBytes ?? 0)
        // Ни одной установки в папке приложения — это ещё не «стоит где-то
        // ещё»: движка может не быть вовсе.
        let engineElsewhere = app.environmentStatus.isEngineInstalled
            ? String(localized: "установлен не в папке приложения")
            : String(localized: "не установлен")
        let database = EnvironmentViewModel.databaseFolder(app)
        // Процент — по тому же счёту, по которому корзина вытесняет старое:
        // по оценке записей, а не по размеру файла.
        let trashDetail = app.trash.isLoading
            ? String(localized: "записи загружаются…")
            : limitDetail(
                used: Int64(app.trash.totalBytes), limit: app.trash.capacityBytes,
                prefix: RussianCount.grouped(app.trash.entries.count, "запись", "записи", "записей")
            )

        var result = [
            Part(
                id: "database", color: .blue, title: String(localized: "База ChromaDB"),
                detail: database.map { String(localized: "папка \($0.lastPathComponent)") }
                    ?? String(localized: "на внешнем сервере — отсюда не видно"),
                bytes: report.databaseBytes,
                unreadable: report.unreadable.contains(.database),
                reveal: database
            ),
        ]
        if let idle = report.idleDatabaseBytes {
            result.append(Part(
                id: "idleDatabase", color: .cyan, title: String(localized: "Локальная база"),
                detail: String(localized: "сейчас не используется — приложение работает с другой базой"),
                bytes: idle,
                unreadable: report.unreadable.contains(.idleDatabase),
                reveal: AppPaths.defaultEmbeddedDatabase
            ))
        }
        result += [
            Part(
                id: "engine", color: .purple, title: String(localized: "Движок ChromaDB"),
                detail: engine.isEmpty ? engineElsewhere : engine.joined(separator: " · "),
                bytes: engineBytes,
                unreadable: report.unreadable.contains(.engine),
                open: { go(.environment, SidebarSection.environment.tabIndex(String(localized: "Установка"))) },
                openTitle: String(localized: "Установка")
            ),
            Part(
                id: "backups", color: .orange, title: String(localized: "Резервные копии"),
                detail: backupDetail, bytes: report.backupsBytes,
                unreadable: report.unreadable.contains(.backups),
                reveal: AppPaths.backupsDirectory,
                open: { go(.environment, SidebarSection.environment.tabIndex(String(localized: "Резервные копии"))) },
                openTitle: String(localized: "Резервные копии")
            ),
            Part(
                id: "trash", color: .pink, title: String(localized: "Корзина"),
                detail: trashDetail,
                bytes: report.trashBytes,
                unreadable: report.unreadable.contains(.trash),
                open: { go(.trash, nil) },
                openTitle: String(localized: "Корзина")
            ),
            Part(
                id: "cache", color: .teal, title: String(localized: "Кэш векторов"),
                detail: limitDetail(
                    used: cacheFileBytes ?? report.embeddingCacheBytes,
                    limit: settings.configuration.embeddingCacheLimitBytes, prefix: nil
                ),
                bytes: report.embeddingCacheBytes,
                unreadable: report.unreadable.contains(.cache),
                open: { go(.models, SidebarSection.models.tabIndex(String(localized: "Кэш"))) },
                openTitle: String(localized: "Кэш")
            ),
            Part(
                id: "logs", color: .gray, title: String(localized: "Журналы"),
                detail: String(localized: "журнал доступа и логи сервера"),
                bytes: report.logsBytes,
                unreadable: report.unreadable.contains(.logs),
                reveal: AppPaths.logsDirectory,
                open: { go(.logs, nil) },
                openTitle: String(localized: "Логи")
            ),
        ]
        return result
    }

    private func servicePart(_ report: DiskUsageReport) -> Part {
        Part(
            id: "service", color: .indigo, title: String(localized: "Служебные данные"),
            detail: nil, bytes: report.serviceBytes,
            unreadable: report.unreadable.contains(.service), reveal: AppPaths.supportDirectory
        )
    }

    /// Предел — в двоичных гигабайтах, как его задают в настройках («1 ГБ» —
    /// это 1024³ байт), а заполнение — долей: «из 1,07 ГБ» и «942,9 МБ из
    /// 1 ГБ» читались одинаково плохо.
    private func limitDetail(used: Int64, limit: Int64, prefix: String?) -> String {
        let limitText = limit.formatted(.byteCount(style: .memory))
        let share = limit > 0 ? Int((Double(used) / Double(limit) * 100).rounded()) : 0
        let filled = String(localized: "предел \(limitText), заполнен на \(share.plainDigits) %")
        return prefix.map { "\($0) · \(filled)" } ?? filled
    }

    private func row(_ part: Part) -> some View {
        HStack(spacing: 10) {
            marker(part.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(part.title)
                if part.unreadable {
                    Text("прочитано не всё — к части файлов нет доступа, размер больше")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if let detail = part.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            if let bytes = part.bytes { sizeText(bytes) } else { Text("—").foregroundStyle(.secondary) }
            trailingSlot {
                if let open = part.open {
                    Button(action: open) {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Открыть «\(part.openTitle ?? part.title)»"))
                }
            }
        }
        .contextMenu {
            if let url = part.reveal {
                Button(String(localized: "Показать в Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            if let open = part.open {
                Button(String(localized: "Открыть «\(part.openTitle ?? part.title)»"), action: open)
            }
        }
    }

    /// Служебные данные раскрываются своей же стрелкой в колонке переходов:
    /// у строки с раскрытием слева размер съезжал из общей колонки.
    private func serviceRow(_ report: DiskUsageReport) -> some View {
        HStack(spacing: 10) {
            marker(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text("Служебные данные")
                if report.unreadable.contains(.service) {
                    Text("прочитано не всё — к части файлов нет доступа, размер больше")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else {
                    Text("манифесты, прогоны оценки, проверки, настройки")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            sizeText(report.serviceBytes)
            trailingSlot {
                if !report.serviceParts.isEmpty {
                    // Состояние видно по стрелке: вниз — раскрыто, вправо — свёрнуто.
                    Button(action: toggleServiceParts) { Image(systemName: showsServiceParts ? "chevron.down" : "chevron.right") }
                        .buttonStyle(.borderless)
                        .help(showsServiceParts ? String(localized: "Свернуть") : String(localized: "Показать по частям"))
                }
            }
        }
        .contextMenu {
            Button(String(localized: "Показать в Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
            }
        }
    }

    private func toggleServiceParts() {
        withAnimation(.easeInOut(duration: 0.15)) { showsServiceParts.toggle() }
    }

    private func marker(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }

    private func sizeText(_ bytes: Int64) -> some View {
        Text(Self.bytes(bytes))
            .foregroundStyle(.secondary)
            .frame(minWidth: 70, alignment: .trailing)
    }

    /// Колонка переходов — одной ширины во всех строках, даже пустая:
    /// иначе колонка размеров ломается там, где перехода нет.
    private func trailingSlot<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(width: 18, alignment: .center)
    }

    private static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    /// Части служебных данных — своими именами; файлы настроек и их запасные
    /// копии — одной строкой: по отдельности это полсотни строк по килобайту.
    static func serviceGroups(_ parts: [DiskUsageReport.Part]) -> [(title: String, bytes: Int64)] {
        var settingsBytes: Int64 = 0
        var groups: [(title: String, bytes: Int64)] = []
        for part in parts {
            if part.name.hasSuffix(".json") || part.name.hasSuffix(".der") || part.name.hasSuffix(".yaml") {
                settingsBytes += part.bytes
            } else {
                groups.append((serviceTitle(part.name), part.bytes))
            }
        }
        if settingsBytes > 0 { groups.append((String(localized: "Настройки и их запасные копии"), settingsBytes)) }
        return groups.sorted { $0.bytes > $1.bytes }
    }

    private static func serviceTitle(_ name: String) -> String {
        switch name {
        case "manifests": return String(localized: "Манифесты синхронизации")
        case "evaluation-runs": return String(localized: "Прогоны оценки")
        case "model-judgements": return String(localized: "Оценки прогонов чат-моделью")
        case "inspections": return String(localized: "Проверки коллекций")
        case "topics": return String(localized: "Темы коллекций")
        case "web-pages": return String(localized: "Страницы сайтов")
        case "git-state": return String(localized: "Состояние репозиториев")
        case "import-checkpoints": return String(localized: "Точки продолжения импорта")
        case "journals": return String(localized: "Журналы прерванных синхронизаций")
        case "servers": return String(localized: "Запущенные серверы")
        default: return name
        }
    }
}
