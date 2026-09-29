import SwiftUI

struct LicensesPage: View {
    var body: some View {
        List {
            Section {
                Text("iDownloader is free software: you can use, study, share and improve it under the GNU General Public License v3. It is a fork of Ghost-Downloader-3 by XiaoYouChR; this fork is not endorsed by the original authors.")
                LabeledContent("License", value: "GNU GPL v3")
                NavigationLink("License Text") {
                    NoticeTextPage(resource: "LICENSE", title: "GNU GPL v3")
                }
                NavigationLink("Third-Party Notices") {
                    NoticeTextPage(resource: "THIRD-PARTY-NOTICES.md", title: "Third-Party Notices")
                }
                Link("Get Source Code", destination: URL(string: "https://github.com/SubhamSubhasisPatra/iDownloader")!)
            } header: {
                Text("This App")
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NoticeTextPage: View {
    let resource: String
    let title: String

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: resource, withExtension: nil),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                ScrollView {
                    Text(text)
                        .font(.caption2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else {
                ContentUnavailableView(
                    "Not Found",
                    systemImage: "doc.questionmark",
                    description: Text("The bundled \(resource) file is missing.")
                )
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
