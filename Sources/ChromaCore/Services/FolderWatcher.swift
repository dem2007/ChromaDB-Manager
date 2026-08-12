import Foundation

/// Watches a folder tree with FSEvents and reports once the changes settle.
///
/// Two protections, both required by the spec: a debounce window so a save does
/// not start a sync per keystroke, and a burst guard so copying hundreds of files
/// results in one run instead of hundreds. The stream itself already coalesces
/// events; the debounce is what turns a copy operation into a single callback.
public final class FolderWatcher {
    private let url: URL
    private let debounce: TimeInterval
    private let handler: () -> Void
    private let queue = DispatchQueue(label: "app.chromadbmanager.folderwatcher")
    private var stream: FSEventStreamRef?
    private var pendingWork: DispatchWorkItem?
    /// Latest event time, so a steady stream of changes keeps postponing the run
    /// instead of firing in the middle of a large copy.
    private var lastEvent = Date.distantPast

    public init(url: URL, debounce: TimeInterval = 5, handler: @escaping () -> Void) {
        self.url = url
        self.debounce = max(1, debounce)
        self.handler = handler
    }

    deinit { stop() }

    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.eventArrived()
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // the stream's own coalescing window; the debounce does the rest
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            return false
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    public func stop() {
        queue.sync {
            pendingWork?.cancel()
            pendingWork = nil
        }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Exposed for tests: the debounce logic is worth checking without FSEvents.
    func eventArrived(now: Date = Date()) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastEvent = now
            self.pendingWork?.cancel()

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Another event landed while we were waiting: let the new timer win.
                guard Date().timeIntervalSince(self.lastEvent) >= self.debounce - 0.25 else { return }
                self.pendingWork = nil
                self.handler()
            }
            self.pendingWork = work
            self.queue.asyncAfter(deadline: .now() + self.debounce, execute: work)
        }
    }
}
