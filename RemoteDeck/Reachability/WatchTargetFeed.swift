import Foundation
import SwiftData
import RemoteDeckCore

/// Hands the watched machines to `ReachabilityMonitor` from the store itself, at launch and after
/// every save of the app's context, so a Watch or address change takes effect wherever it was made
/// (the Library Window, or the Machine Editor opened by a session's Edit credentials while the
/// Library Window is closed: review M2).
@MainActor
final class WatchTargetFeed {
    private let context: ModelContext
    private let monitor: ReachabilityMonitor
    private var observer: (any NSObjectProtocol)?

    init(context: ModelContext, monitor: ReachabilityMonitor, notificationCenter: NotificationCenter = .default) {
        self.context = context
        self.monitor = monitor
        observer = notificationCenter.addObserver(forName: ModelContext.didSave, object: context,
                                                  queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let watched = (try? context.fetch(FetchDescriptor<Machine>(predicate: #Predicate { $0.isWatched }))) ?? []
        monitor.update(watched.map { WatchTarget(machineID: $0.id, name: $0.name, host: $0.host, port: $0.port) })
    }
}
