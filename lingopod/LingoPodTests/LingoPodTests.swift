// M0
import Testing
import SwiftData
@testable import LingoPod

@MainActor
@Test func appContainerInitializes() {
    let container = AppContainer()
    #expect(container.playerEngine.state == .idle)
}
