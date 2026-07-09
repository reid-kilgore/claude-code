// M0
// M0 stub: renders nothing when no episode is loaded (which is always
// true in M0, since there is no real playback yet). M2 replaces the body
// with the real miniplayer bar driven by `container.playerEngine.state`.
import SwiftUI

struct MiniPlayerView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        EmptyView()
    }
}
