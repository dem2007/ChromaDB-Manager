import Foundation

/// When a finished background operation is worth a notification.
public enum OperationNotificationPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Every finished operation, including the routine ones nobody was waiting for.
    case always
    /// Only runs that ended with something the user has to look at.
    case problemsOnly
    case never

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .always: return String(localized: "всегда")
        case .problemsOnly: return String(localized: "только при проблемах")
        case .never: return String(localized: "никогда")
        }
    }

    public var explanation: String {
        switch self {
        case .always:
            return String(localized: "Уведомление после каждой фоновой операции, включая те, где ничего не изменилось. Автоматическая синхронизация по таймеру тоже считается.")
        case .problemsOnly:
            return String(localized: "Уведомление только если что-то требует решения: пропавшие файлы, пропуски, неоднородность коллекции или ошибка. Успешный прогон проходит молча.")
        case .never:
            return String(localized: "Итоги фоновых операций не показываются. Уведомления безопасности это не отключает — они о другом.")
        }
    }
}

/// The summary of one finished background operation, in the shape a notification
/// needs.
///
/// One notice per operation, never per file: a notification for every event is a
/// notification for none of them — the same reason `SecurityEvent` is a short
/// list. Each service converts its own report into this; the notifier knows
/// nothing about syncing or re-embedding.
public struct OperationNotice: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case sync
        case reembedding
        case importDocuments
        case benchmark

        var noun: String {
            switch self {
            case .sync: return String(localized: "Синхронизация")
            case .reembedding: return String(localized: "Пересчёт коллекции")
            case .importDocuments: return String(localized: "Импорт")
            case .benchmark: return String(localized: "Измерение скорости")
            }
        }
    }

    public let kind: Kind
    /// Source, collection or model — whatever the operation was about.
    public let subject: String
    public let added: Int
    public let updated: Int
    /// Files that vanished and are waiting for the user's decision:
    /// nothing is deleted automatically, so this is a queue, not a statistic.
    public let needsDecision: Int
    /// Anything the user has to look at: skipped files, heterogeneity, the
    /// reason the operation failed. Already phrased for reading.
    public let problems: [String]
    public let duration: TimeInterval
    /// The operation did not finish. Its counts, if any, are partial.
    public let failed: Bool

    public init(
        kind: Kind,
        subject: String,
        added: Int = 0,
        updated: Int = 0,
        needsDecision: Int = 0,
        problems: [String] = [],
        duration: TimeInterval = 0,
        failed: Bool = false
    ) {
        self.kind = kind
        self.subject = subject
        self.added = added
        self.updated = updated
        self.needsDecision = needsDecision
        self.problems = problems
        self.duration = duration
        self.failed = failed
    }

    /// What «только при проблемах» means, in one place so the setting and the
    /// notification cannot disagree about it.
    public var hasProblems: Bool {
        failed || needsDecision > 0 || !problems.isEmpty
    }

    public func shouldPost(policy: OperationNotificationPolicy) -> Bool {
        switch policy {
        case .never: return false
        case .always: return true
        case .problemsOnly: return hasProblems
        }
    }

    public var title: String {
        failed
            ? String(localized: "\(kind.noun) «\(subject)» прервана")
            : String(localized: "\(kind.noun) «\(subject)» завершена")
    }

    public var body: String {
        var lines: [String] = []
        if added + updated > 0 {
            lines.append(String(localized: "добавлено \(added.plainDigits), обновлено \(updated.plainDigits)"))
        } else if !failed {
            lines.append(String(localized: "изменений нет"))
        }
        if needsDecision > 0 {
            lines.append(String(localized: "требуют решения: \(needsDecision.plainDigits)"))
        }
        // Two problems is where a notification stops being readable; the rest
        // are counted, and the screen has them in full.
        lines.append(contentsOf: problems.prefix(2))
        if problems.count > 2 {
            lines.append(String(localized: "ещё замечаний: \((problems.count - 2).plainDigits)"))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - What each operation reports

public extension SyncSummary {
    /// the summary the user would otherwise have to come back to the window
    /// for. Skipped files and heterogeneity are problems because both mean the
    /// collection is not what the source says it is.
    var notice: OperationNotice {
        var problems: [String] = []
        if !skipped.isEmpty {
            problems.append(String(localized: "пропущено файлов: \(skipped.count.plainDigits)"))
        }
        if let heterogeneity = heterogeneityLine {
            problems.append(heterogeneity)
        }
        if !markedForAttention.isEmpty {
            problems.append(String(localized: "записано с пометкой о схеме: \(markedForAttention.count.plainDigits)"))
        }
        return OperationNotice(
            kind: .sync,
            subject: sourceName,
            added: added,
            updated: updated,
            needsDecision: needsDecision.count,
            problems: problems,
            duration: duration
        )
    }
}

public extension ReembeddingReport {
    /// A re-embedding that verified badly is the case worth waking someone for:
    /// the collection has been rewritten, and the check on it did not pass.
    var notice: OperationNotice {
        var problems: [String] = []
        if !verification.isClean {
            problems.append(verification.line)
        }
        return OperationNotice(
            kind: .reembedding,
            subject: resultCollection,
            added: writtenDocuments,
            problems: problems,
            duration: duration
        )
    }
}

public extension ImportSummary {
    var notice: OperationNotice {
        var problems: [String] = []
        if !skippedTooLong.isEmpty {
            problems.append(String(localized: "не поместились в контекст модели: \(skippedTooLong.count.plainDigits)"))
        }
        if !skippedDuplicates.isEmpty {
            problems.append(String(localized: "пропущено дубликатов: \(skippedDuplicates.count.plainDigits)"))
        }
        if skippedEmpty > 0 {
            problems.append(String(localized: "пустых строк пропущено: \(skippedEmpty.plainDigits)"))
        }
        return OperationNotice(
            kind: .importDocuments,
            subject: model,
            added: written,
            problems: problems,
            duration: duration
        )
    }
}

public extension OperationNotice {
    /// An operation that did not finish. Its counts are unknown, and saying
    /// «изменений нет» about a run that died would be a lie — hence `failed`
    /// rather than an empty summary.
    static func failure(kind: Kind, subject: String, reason: String) -> OperationNotice {
        OperationNotice(kind: kind, subject: subject, problems: [reason], failed: true)
    }
}
