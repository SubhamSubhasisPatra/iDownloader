import SwiftUI

@main
struct iDownloaderApp: App {
    @State private var taskService = TaskService()
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            TasksPage(service: taskService)
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
