import Foundation

/// Оценка выдачи чат-моделью — необязательный режим, выключенный по
/// умолчанию.
///
/// **Что этот тип намеренно не умеет.** Он не пишет в набор запросов и не
/// участвует в расчёте метрик. Оценка модели — подсказка разметчику, а не
/// разметка: превратить её в эталон может только человек, нажав кнопку. ТЗ
/// формулирует это как «оценка модели не является истиной», и единственный
/// способ удержать такое требование — не дать коду физической возможности его
/// нарушить.
public actor ModelJudge {
    /// Промпт и модель на входе, ответ по схеме на выходе.
    public typealias Grader = @Sendable (
        _ prompt: String, _ model: String, _ schema: ChatJSONSchema
    ) async throws -> String

    public struct Progress: Sendable {
        public let done: Int
        public let total: Int
        public let queryText: String

        public var line: String {
            String(localized: "\(done) из \(total): «\(queryText)»")
        }
    }

    private let grade: Grader
    private let log: LogHandler

    public init(grade: @escaping Grader, log: @escaping LogHandler = noopLogHandler) {
        self.grade = grade
        self.log = log
    }

    /// Сколько секунд ушло на один вызов — то, из чего складывается оценка
    /// времени следующего прогона. Меряется здесь, потому что здесь и только
    /// здесь известно, что вызов был именно оценкой (12.7).
    public private(set) var measuredSeconds: Double = 0
    public private(set) var measuredCalls: Int = 0

    public func run(
        run: EvaluationRun,
        model: String,
        prompt: JudgePrompt,
        existing: JudgementSet? = nil,
        progress: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async -> JudgementSet {
        var set = existing ?? JudgementSet(runID: run.id)
        set.runID = run.id
        measuredSeconds = 0
        measuredCalls = 0

        let fingerprint = prompt.fingerprint
        let queryTexts = Dictionary(uniqueKeysWithValues: run.queries.map { ($0.id, $0.text) })

        // Что предстоит: только неоценённое этой редакцией промпта. Повторять
        // уже сделанное — это минуты работы модели впустую, и человек об этом
        // предупреждён числом в строке стоимости.
        var todo: [(queryID: UUID, variantID: UUID, hit: EvaluationHit)] = []
        for result in run.results where result.succeeded {
            for hit in result.hits {
                let judged = set.judgement(
                    query: result.queryID, variant: result.variantID, document: hit.id
                )
                if judged?.promptFingerprint == fingerprint { continue }
                todo.append((result.queryID, result.variantID, hit))
            }
        }

        var cancelled = false
        var failed = 0
        var done = 0
        for item in todo {
            if Task.isCancelled { cancelled = true; break }
            let queryText = queryTexts[item.queryID] ?? ""
            progress(Progress(done: done, total: todo.count, queryText: queryText))
            done += 1

            let filled = prompt.filled(query: queryText, document: item.hit.text ?? "")
            let started = Date()
            do {
                let answer = try await grade(filled, model, .relevance)
                guard let parsed = Self.parse(answer) else {
                    // Молчащий провал разбора — худший вид: сорок пустых
                    // результатов и ни строчки о том, что именно пришло.
                    // Ответ обрезается: в журнал не уносится весь документ.
                    failed += 1
                    log(
                        .warning, "Оценка",
                        "Ответ модели не разобран как оценка (результат \(item.hit.id)): "
                        + "«\(answer.prefix(120))»"
                    )
                    continue
                }
                measuredSeconds += Date().timeIntervalSince(started)
                measuredCalls += 1
                // Переоценка того же результата заменяет прежнюю оценку, а не
                // копится вторым мнением рядом.
                set.judgements.removeAll {
                    $0.queryID == item.queryID && $0.variantID == item.variantID
                        && $0.documentID == item.hit.id
                }
                set.judgements.append(ModelJudgement(
                    queryID: item.queryID,
                    variantID: item.variantID,
                    documentID: item.hit.id,
                    grade: parsed.grade,
                    reason: parsed.reason,
                    model: model,
                    promptFingerprint: fingerprint
                ))
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                failed += 1
                log(.warning, "Оценка", "Модель не оценила результат \(item.hit.id): \(error.localizedDescription)")
            }
        }

        set.isComplete = !cancelled && failed == 0
        if cancelled {
            set.note = String(localized: "Оценка отменена: сделано \(done) из \(todo.count). Полученные оценки сохранены.")
        } else if failed > 0 {
            set.note = String(localized: "Модель не ответила на \(failed) из \(todo.count) — эти результаты остались без оценки.")
        } else {
            set.note = ""
        }
        log(
            cancelled || failed > 0 ? .warning : .info,
            "Оценка",
            "Оценка чат-моделью «\(model)»: \(set.judgements.count) оценок, вызовов \(measuredCalls), сбоев \(failed)"
        )
        return set
    }

    /// Разбор ответа по схеме.
    ///
    /// Схема гарантирует форму, но не то, что перед нами вообще JSON: модель
    /// без поддержки Structured Output ответит прозой, и разбор обязан это
    /// пережить, а не уронить прогон.
    static func parse(_ answer: String) -> (grade: RelevanceGrade, reason: String)? {
        guard let data = answer.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["grade"] as? String
        else { return nil }
        guard let grade = gradeFromModel(raw) else { return nil }
        return (grade, (object["reason"] as? String) ?? "")
    }

    /// Слова модели — английские, потому что английский `enum` в схеме
    /// стабильнее для модели, чем русский; на экран же попадает русское
    /// название градации.
    static func gradeFromModel(_ raw: String) -> RelevanceGrade? {
        switch raw.lowercased() {
        case "relevant": return .relevant
        case "partial": return .partial
        case "irrelevant": return .irrelevant
        default: return nil
        }
    }
}
