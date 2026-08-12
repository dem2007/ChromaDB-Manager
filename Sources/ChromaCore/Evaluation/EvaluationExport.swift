import Foundation

/// Экспорт отчёта в Markdown и JSON.
///
/// **Оба формата обязаны нести полные параметры вариантов.** Отчёт, в котором
/// написано «вариант A лучше варианта B», но не написано, чем A отличался
/// от B, через неделю не значит ничего — а D1.2 хранит профиль внутри варианта
/// именно затем, чтобы он был.
public enum EvaluationExport {

    // MARK: - Markdown

    public static func markdown(
        run: EvaluationRun,
        set: QuerySet? = nil,
        ks: [Int] = EvaluationMetrics.defaultKs,
        divergentLimit: Int = 10
    ) -> String {
        let metrics = EvaluationMetrics.compute(run: run, set: set, ks: ks)
        let table = EvaluationReport.table(metrics, ks: ks)
        let rows = EvaluationReport.queryRows(run: run, set: set)
        var out: [String] = []

        out.append("# Отчёт прогона «\(run.name)»")
        out.append("")
        out.append("- Набор запросов: **\(run.querySetName)**, запросов \(run.queries.count)")
        out.append("- Начат: \(iso(run.startedAt))" + (run.finishedAt.map { ", завершён: \(iso($0))" } ?? ""))
        out.append("- Версия приложения: \(run.appVersion)")
        if !run.isComplete {
            // Неполный прогон помечается в отчёте, а не только на экране:
            // выгруженный файл живёт отдельно от приложения.
            out.append("- ⚠️ **Прогон неполный.**" + (run.note.isEmpty ? "" : " \(run.note)"))
        }
        out.append("")

        out.append("## Варианты")
        out.append("")
        for variant in run.variants {
            out.append("### \(variant.name)")
            out.append("")
            out.append("- Коллекция: `\(variant.collectionName)`")
            out.append("- Модель: `\(variant.model)`")
            out.append("- Метрика: \(variant.metric?.rawValue ?? "неизвестна")")
            out.append("- n_results: \(variant.nResults)")
            out.append("- Фильтр: \(variant.filter == nil ? "нет" : "есть")")
            out.append("- Профиль: `\(variant.profile.name)`")
            for line in profileLines(variant.profile) { out.append("  - \(line)") }
            if !variant.note.isEmpty { out.append("- Примечание: \(variant.note)") }
            out.append("")
        }

        out.append("## Метрики")
        out.append("")
        out.append(markdownTable(table))
        out.append("")
        for (index, item) in metrics.enumerated() {
            var notes: [String] = []
            if item.failedCells > 0 { notes.append("сбойных ячеек \(item.failedCells)") }
            if !item.coverage.isComplete { notes.append(item.coverage.line) }
            for k in ks { if let note = item.note(for: k) { notes.append(note) } }
            if !notes.isEmpty {
                out.append("- **\(table.variantNames[index])**: " + notes.joined(separator: "; "))
            }
        }
        if let caveat = EvaluationReport.lengthCaveat(run) {
            out.append("")
            out.append("> \(caveat)")
        }
        out.append("")

        let divergent = EvaluationReport.mostDivergent(rows, limit: divergentLimit)
        out.append("## Где варианты разошлись сильнее всего")
        out.append("")
        if divergent.isEmpty {
            out.append("Расхождений нет: на всех запросах варианты повели себя одинаково "
                       + "либо судить не по чему — разметки не хватает.")
        } else {
            out.append(queryTable(divergent, variants: run.variants))
        }
        out.append("")

        out.append("## Все запросы")
        out.append("")
        out.append(queryTable(rows, variants: run.variants))
        out.append("")
        return out.joined(separator: "\n")
    }

    static func profileLines(_ profile: SearchProfile) -> [String] {
        var lines: [String] = []
        var sources: [String] = []
        if profile.vectorSearchEnabled { sources.append("векторный") }
        if profile.textSearchEnabled { sources.append("текстовый") }
        lines.append("источники: " + (sources.isEmpty ? "нет" : sources.joined(separator: " + ")))
        if profile.vectorSearchEnabled && profile.textSearchEnabled {
            lines.append("слияние RRF: rrf_k \(profile.fusionK), веса \(profile.vectorWeight)/\(profile.textWeight)")
        }
        lines.append("пул: n_results × \(profile.candidateMultiplier), не меньше \(profile.minimumCandidates)")
        lines.append("иерархия: искать по \(profile.searchLevel.rawValue), возвращать \(profile.promotion.rawValue)"
                     + (profile.collapseByParent ? ", схлопывать" : ""))
        if profile.diversityEnabled { lines.append("MMR: λ \(profile.diversityLambda)") }
        if let window = profile.contextWindow, window > 0 { lines.append("соседей: \(window)") }
        if profile.rerankEnabled && !profile.rerankModel.isEmpty {
            lines.append("переранжирование: \(profile.rerankModel), режим \(profile.rerankMode.rawValue)")
        }
        return lines
    }

    private static func markdownTable(_ table: EvaluationReport.Table) -> String {
        var lines: [String] = []
        lines.append("| Метрика | " + table.variantNames.joined(separator: " | ") + " |")
        lines.append("|---|" + String(repeating: "---|", count: table.variantNames.count))
        for column in table.columns {
            let cells = column.cells.map { cell in
                // Лучшее значение выделяется жирным — единственный способ
                // перенести подсветку в текстовый формат, не соврав про неё.
                cell.isBest ? "**\(cell.text)**" : cell.text
            }
            lines.append("| \(column.title) | " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private static func queryTable(
        _ rows: [EvaluationReport.QueryRow], variants: [EvaluationVariant]
    ) -> String {
        var lines: [String] = []
        lines.append("| Запрос | " + variants.map(\.name).joined(separator: " | ") + " |")
        lines.append("|---|" + String(repeating: "---|", count: variants.count))
        for row in rows {
            let cells = row.outcomes.map { outcome -> String in
                if case .failed(let reason) = outcome { return "сбой: \(reason)" }
                return outcome.text
            }
            lines.append("| \(escaped(row.text)) | " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    /// Вертикальная черта в тексте запроса разломала бы таблицу Markdown.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - JSON

    /// JSON отчёта — не дамп прогона.
    ///
    /// Выгрузка самого прогона уже есть (`EvaluationRunStore.exportData`) и
    /// нужна, чтобы прогон вернуть. Здесь другое: посчитанные метрики, исходы
    /// по запросам и параметры вариантов — то, что читает человек или чужой
    /// скрипт, не разбирая заново формулы D1.3.
    public static func json(
        run: EvaluationRun,
        set: QuerySet? = nil,
        ks: [Int] = EvaluationMetrics.defaultKs
    ) throws -> Data {
        let metrics = EvaluationMetrics.compute(run: run, set: set, ks: ks)
        let table = EvaluationReport.table(metrics, ks: ks)
        let rows = EvaluationReport.queryRows(run: run, set: set)

        var payload: [String: Any] = [
            "run": [
                "id": run.id.uuidString,
                "name": run.name,
                "querySet": run.querySetName,
                "queries": run.queries.count,
                "startedAt": iso(run.startedAt),
                "isComplete": run.isComplete,
                "note": run.note,
                "appVersion": run.appVersion,
            ],
            "variants": run.variants.map { variant in
                [
                    "name": variant.name,
                    "collection": variant.collectionName,
                    "model": variant.model,
                    "metric": variant.metric?.rawValue ?? NSNull(),
                    "nResults": variant.nResults,
                    "hasFilter": variant.filter != nil,
                    "profile": variant.profile.name,
                    "profileDetails": profileLines(variant.profile),
                    "note": variant.note,
                ] as [String: Any]
            },
            // Медиана длины результата — то, без чего hit rate вариантов с
            // разной нарезкой сравнивают, не зная, что сравнивают.
            "medianResultLength": zip(
                run.variants.map(\.name), EvaluationReport.medianResultLengths(run)
            ).map { name, length in
                ["variant": name, "characters": length ?? NSNull()] as [String: Any]
            },
            "metrics": table.columns.map { column in
                [
                    "key": column.key,
                    "title": column.title,
                    "betterIs": column.direction == .higherIsBetter ? "higher" : "lower",
                    "values": zip(table.variantNames, column.cells).map { name, cell in
                        [
                            "variant": name,
                            // `null`, а не 0: «неприменимо» и «ноль» — разные
                            // ответы, и в JSON это различие обязано сохраниться.
                            "value": cell.value ?? NSNull(),
                            "text": cell.text,
                            "isBest": cell.isBest,
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
            "queries": rows.map { row in
                [
                    "text": row.text,
                    "spread": row.spread,
                    "outcomes": zip(run.variants.map(\.name), row.outcomes).map { name, outcome in
                        var item: [String: Any] = ["variant": name]
                        switch outcome {
                        case .found(let rank): item["outcome"] = "found"; item["rank"] = rank
                        case .missed: item["outcome"] = "missed"
                        case .unmarked: item["outcome"] = "unmarked"
                        case .failed(let reason): item["outcome"] = "failed"; item["reason"] = reason
                        }
                        return item
                    },
                ] as [String: Any]
            },
        ]
        payload["divergentQueries"] = EvaluationReport.mostDivergent(rows).map(\.text)
        payload["lengthCaveat"] = EvaluationReport.lengthCaveat(run) ?? NSNull()
        return try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        )
    }
}
