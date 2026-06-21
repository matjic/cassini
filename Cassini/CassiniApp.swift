import SwiftUI

@main
struct CassiniApp: App {
    @State private var controller = RingController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(controller)
                .onAppear { controller.start() }
        }
    }
}
