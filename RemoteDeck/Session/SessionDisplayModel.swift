import RFBKit

/// Feeds a session's events to its `FramebufferRenderer`, on the main actor.
///
/// With `RFBSessionEvents`, taking an update from the sequence is what asks the server for the next
/// one, so events are handled as soon as they arrive, and handling one costs only the copy of its
/// changed pixels (the GPU upload is asynchronous, see `FramebufferRenderer`).
@MainActor
final class SessionDisplayModel {
    let renderer: FramebufferRenderer

    init(renderer: FramebufferRenderer) {
        self.renderer = renderer
    }

    /// Runs until the sequence ends (`nil` after `close()` or cancellation) or throws its `RFBError`.
    func consume(_ events: some AsyncSequence<RFBEvent, any Error>) async throws {
        for try await event in events {
            handle(event)
        }
    }

    func handle(_ event: RFBEvent) {
        switch event {
        case .framebufferUpdate(let update):
            renderer.apply(update)
        case .desktopResized(let width, let height):
            renderer.resize(width: width, height: height)
        case .bell, .serverCutText, .cursor:
            break   // cursor shape: not drawn yet (the local arrow stays); clipboard: T4.1
        }
    }
}
