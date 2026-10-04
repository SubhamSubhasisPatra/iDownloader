import SwiftUI

@main
struct iDownloaderApp: App {
    @State private var taskService = TaskService()
    @State private var isAlertPresented = false
    @State private var appError = ""
    @State private var incomingDraft: TorrentDraft?
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            TasksPage(service: taskService, incomingDraft: $incomingDraft)
                .preferredColorScheme(colorScheme)
                .onOpenURL { url in
                    openIncoming(url)
                }
                .alert("Download Error", isPresented: $isAlertPresented) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(appError)
                }
        }
    }

    /// Magnets and .torrent files handed over by Safari or the Files app open
    /// the add sheet with the metadata preview.
    private func openIncoming(_ url: URL) {
        let isFile = url.isFileURL
        let secured = isFile ? url.startAccessingSecurityScopedResource() : false
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        Task {
            let (draft, error) = await taskService.prepareTorrent(
                text: isFile ? nil : url.absoluteString,
                fileURL: isFile ? url : nil)
            if let error {
                appError = error
                isAlertPresented = true
                return
            }
            guard let draft else { return }
            incomingDraft = draft
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
