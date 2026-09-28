import SwiftUI

struct SettingsPage: View {
    let service: TaskService

    @AppStorage("maxConcurrentTask") private var maxConcurrentTask = 3
    @AppStorage("subworkerCount") private var subworkerCount = 8
    @AppStorage("autoStart") private var autoStart = true
    @AppStorage("categoryFolders") private var categoryFolders = true
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("githubEnabled") private var githubEnabled = true
    @AppStorage("githubSite") private var githubSite = GitHubProxy.autoKey
    @AppStorage("githubCustomSite") private var githubCustomSite = ""
    @AppStorage("dhtEnabled") private var dhtEnabled = true
    @AppStorage("speedLimitKbps") private var speedLimitKbps = 0

    var body: some View {
        Form {
            Section {
                Stepper(value: $maxConcurrentTask, in: 1...10) {
                    Text("Max Concurrent Tasks: \(maxConcurrentTask)")
                }
                Stepper(value: $subworkerCount, in: 1...32) {
                    Text("Connections per Task: \(subworkerCount)")
                }
                Toggle("Start Downloads Automatically", isOn: $autoStart)
                Toggle("Save into Category Folders", isOn: $categoryFolders)
            } header: {
                Text("Download")
            } footer: {
                Text("Connections split one file across parallel byte ranges. More connections can be faster, but some servers limit them.")
            }

            Section {
                Toggle("Enable DHT Network", isOn: $dhtEnabled)
                Picker("Speed Limit", selection: $speedLimitKbps) {
                    Text("Unlimited").tag(0)
                    Text("512 KB/s").tag(512)
                    Text("2 MB/s").tag(2048)
                    Text("5 MB/s").tag(5120)
                    Text("10 MB/s").tag(10240)
                }
                .onChange(of: speedLimitKbps) { _, _ in
                    service.applyEngineSettings()
                }
            } header: {
                Text("BitTorrent")
            } footer: {
                Text("DHT change takes effect after restarting the app. The speed limit applies to BitTorrent only.")
            }

            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }

            Section {
                Toggle("Enable GitHub Acceleration", isOn: $githubEnabled)
                if githubEnabled {
                    Picker("Proxy Site", selection: $githubSite) {
                        Text("Auto Site").tag(GitHubProxy.autoKey)
                        ForEach(GitHubProxy.sites, id: \.self) { site in
                            Text(String(site.dropFirst("https://".count))).tag(site)
                        }
                        Text("Custom Site").tag(GitHubProxy.customKey)
                    }
                    if githubSite == GitHubProxy.customKey {
                        TextField("https://example.com", text: $githubCustomSite)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            } header: {
                Text("GitHub Acceleration")
            } footer: {
                Text("Download GitHub files through a proxy site when the direct connection is slow.")
            }

            Section("About") {
                LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (iOS)")
                Link("GitHub Repository", destination: URL(string: "https://github.com/XiaoYouChR/Ghost-Downloader-3")!)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: maxConcurrentTask) { _, _ in
            service.scheduleNext()
        }
    }
}
