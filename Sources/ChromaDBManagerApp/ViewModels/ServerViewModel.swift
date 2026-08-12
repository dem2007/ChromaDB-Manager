import Foundation
import SwiftUI
import AppKit
import ChromaCore

/// The «Сервер» screen: start / stop / restart, what is running
/// right now, and the server's own output.
///
/// Starting and stopping go through `AppEnvironment`, not straight to the
/// process manager: for a local database the process and the client are one
/// thing, and two ways of starting a server would eventually disagree.
@MainActor
final class ServerViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var isBusy = false

    /// Log panel state.
    @Published var filter = ""
    @Published var followsTail = true
    @Published var pastRuns: [ServerLogStore.Run] = []

    func start(_ app: AppEnvironment, collectionsModel: CollectionsViewModel) async {
        await perform(app) {
            await app.connect()
            await collectionsModel.refresh(app)
        }
    }

    func stop(_ app: AppEnvironment) async {
        await perform(app) { await app.disconnect() }
    }

    func restart(_ app: AppEnvironment, collectionsModel: CollectionsViewModel) async {
        // A local database comes back on a different port, so a proxy that was
        // running has to be pointed at the new one rather than left forwarding
        // into nothing.
        let proxyWasRunning = app.proxy.state.isRunning
        await perform(app) {
            await app.reconnect()
            await collectionsModel.refresh(app)
        }
        if proxyWasRunning, app.client != nil {
            startProxy(app)
        }
    }

    // MARK: - Proxy

    /// Clients talk to the proxy; the real server stays on its private port.
    func startProxy(_ app: AppEnvironment) {
        do {
            try app.startProxy()
            errorMessage = nil
        } catch {
            errorMessage = app.describe(error)
        }
    }

    func stopProxy(_ app: AppEnvironment) {
        app.proxy.stop()
    }

    private func perform(_ app: AppEnvironment, _ body: () async -> Void) async {
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        await body()
        isBusy = false
        // `connect()` reports its own failures through `connection`; surface the
        // process-level reason too, because it is the one that explains why.
        if let failure = app.processManager.lastFailure {
            errorMessage = [failure.message, failure.suggestion].compactMap { $0 }.joined(separator: "\n")
        } else if case .failed(let reason) = app.connection {
            errorMessage = reason
        }
        refreshRuns(app)
    }

    func stopOrphan(_ record: RunningServerRecord, app: AppEnvironment) async {
        await app.processManager.stopOrphan(record)
        statusMessage = String(localized: "Процессу PID \(record.pid.plainDigits) отправлен сигнал завершения.")
    }

    // MARK: - Log panel

    /// Lines shown in the panel. An empty filter shows everything.
    func visibleLines(_ lines: [String]) -> [String] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return lines }
        return lines.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    func refreshRuns(_ app: AppEnvironment) {
        pastRuns = app.processManager.serverLog.runs()
    }

    func copyLog(_ lines: [String]) {
        let text = visibleLines(lines).joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = String(localized: "Вывод сервера скопирован в буфер обмена.")
    }

    func revealRun(_ run: ServerLogStore.Run) {
        NSWorkspace.shared.activateFileViewerSelecting([run.url])
    }
}
