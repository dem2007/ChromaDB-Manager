import Foundation

/// When a source syncs by itself. Modes combine: "at startup" and
/// "every 30 minutes" can both be on for the same source.
public struct SyncTriggers: Codable, Hashable, Sendable {
    /// Runs in the background right after launch, without blocking the window.
    public var onLaunch: Bool
    public var scheduled: Bool
    public var schedule: SyncSchedule
    /// Watches the folder with FSEvents and syncs after the changes settle.
    public var onFileChanges: Bool
    /// Quiet period after the last event, in seconds — a save should not start a
    /// sync per keystroke, and copying 500 files should cause one run, not 500.
    public var debounceSeconds: Double

    public init(
        onLaunch: Bool = false,
        scheduled: Bool = false,
        schedule: SyncSchedule = SyncSchedule(),
        onFileChanges: Bool = false,
        debounceSeconds: Double = 5
    ) {
        self.onLaunch = onLaunch
        self.scheduled = scheduled
        self.schedule = schedule
        self.onFileChanges = onFileChanges
        self.debounceSeconds = debounceSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        onLaunch = try container.decodeIfPresent(Bool.self, forKey: .onLaunch) ?? false
        scheduled = try container.decodeIfPresent(Bool.self, forKey: .scheduled) ?? false
        schedule = ((try? container.decodeIfPresent(SyncSchedule.self, forKey: .schedule)) ?? nil) ?? SyncSchedule()
        onFileChanges = try container.decodeIfPresent(Bool.self, forKey: .onFileChanges) ?? false
        debounceSeconds = try container.decodeIfPresent(Double.self, forKey: .debounceSeconds) ?? 5
    }

    public var isAnyEnabled: Bool { onLaunch || scheduled || onFileChanges }

    public var summary: String {
        var parts: [String] = []
        if onLaunch { parts.append(String(localized: "при старте")) }
        if scheduled { parts.append(schedule.summary) }
        if onFileChanges { parts.append(String(localized: "при изменениях в папке (пауза \(Int(debounceSeconds)) с)")) }
        return parts.isEmpty ? String(localized: "только вручную") : parts.joined(separator: ", ")
    }
}

public struct SyncSchedule: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case interval
        case dailyAt

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .interval: return String(localized: "каждые N минут")
            case .dailyAt: return String(localized: "ежедневно в указанное время")
            }
        }
    }

    public var kind: Kind
    /// Interval in minutes; hours are entered as minutes in the UI.
    public var intervalMinutes: Int
    /// Local time of day for the daily mode.
    public var hour: Int
    public var minute: Int

    public init(kind: Kind = .interval, intervalMinutes: Int = 60, hour: Int = 9, minute: Int = 0) {
        self.kind = kind
        self.intervalMinutes = intervalMinutes
        self.hour = hour
        self.minute = minute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = ((try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? nil) ?? .interval
        intervalMinutes = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 60
        hour = try container.decodeIfPresent(Int.self, forKey: .hour) ?? 9
        minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0
    }

    public var summary: String {
        switch kind {
        case .interval:
            let minutes = max(1, intervalMinutes)
            if minutes % 60 == 0 {
                return String(localized: "каждые \(minutes / 60) ч")
            }
            return String(localized: "каждые \(minutes) мин")
        case .dailyAt:
            return String(localized: "ежедневно в \(String(format: "%02d:%02d", hour, minute))")
        }
    }

    /// Next fire time after `reference`, or `nil` if the schedule cannot produce
    /// one (which only happens for a nonsense interval).
    public func nextFireDate(after reference: Date, lastRun: Date?, calendar: Calendar = .current) -> Date? {
        switch kind {
        case .interval:
            let minutes = max(1, intervalMinutes)
            let base = lastRun ?? reference
            let candidate = base.addingTimeInterval(Double(minutes) * 60)
            // A long-overdue interval fires promptly rather than "catching up"
            // with a burst of runs.
            return candidate > reference ? candidate : reference.addingTimeInterval(1)

        case .dailyAt:
            var components = calendar.dateComponents([.year, .month, .day], from: reference)
            components.hour = max(0, min(hour, 23))
            components.minute = max(0, min(minute, 59))
            components.second = 0
            guard let today = calendar.date(from: components) else { return nil }
            if today > reference, !(lastRun.map { calendar.isDate($0, inSameDayAs: today) && $0 >= today } ?? false) {
                return today
            }
            return calendar.date(byAdding: .day, value: 1, to: today)
        }
    }
}

/// Why a sync started — every automatic run says so in the log and in the
/// status bar, because the spec forbids changing the database quietly.
public enum SyncReason: String, Codable, Hashable {
    case manual
    case launch
    case schedule
    case fileChanges

    public var title: String {
        switch self {
        case .manual: return String(localized: "вручную")
        case .launch: return String(localized: "при старте приложения")
        case .schedule: return String(localized: "по расписанию")
        case .fileChanges: return String(localized: "по изменениям в папке")
        }
    }

    public var isAutomatic: Bool { self != .manual }
}
