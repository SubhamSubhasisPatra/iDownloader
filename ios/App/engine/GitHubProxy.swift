import Foundation

enum GitHubProxy {
    static let autoKey = "__auto__"
    static let customKey = "__custom__"

    static let sites: [String] = [
        "https://gh-proxy.com",
        "https://gh-proxy.org",
        "https://cdn.gh-proxy.org",
        "https://edgeone.gh-proxy.org",
        "https://hk.gh-proxy.org",
        "https://ghfast.top",
        "https://ghfile.geekertao.top",
        "https://gh.chjina.com",
        "https://gh.monlor.com",
        "https://gh.jasonzeng.dev",
        "https://ghproxy.monkeyray.net",
        "https://github.ednovas.xyz",
        "https://gh.nxnow.top",
        "https://ghproxy.cxkpro.top",
        "https://fastgit.cc",
        "https://gh.zwy.one",
        "https://gitproxy.mrhjx.cn",
        "https://github.boki.moe",
        "https://gh.xxooo.cf",
        "https://gh.llkk.cc",
        "https://wget.la",
    ]

    private static let hosts: Set<String> = [
        "github.com",
        "raw.githubusercontent.com",
        "gist.githubusercontent.com",
        "codeload.github.com",
        "objects.githubusercontent.com",
    ]

    static func isGitHub(_ url: URL) -> Bool {
        hosts.contains(url.host?.lowercased() ?? "")
    }

    /// Auto Site: races the direct connection against every proxy site and takes the first qualified response; the winner is never remembered across tasks.
    static func resolve(_ url: URL, enabled: Bool, site: String, customSite: String) async -> URL {
        guard enabled, isGitHub(url) else { return url }
        if site == autoKey {
            return await raceSite(url)
        }
        let base = site == customKey ? toProxySite(customSite) : site
        guard !base.isEmpty, let proxied = URL(string: "\(base)/\(url.absoluteString)") else {
            return url
        }
        return proxied
    }

    private static func toProxySite(_ site: String) -> String {
        var value = site.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty, !value.contains("://") {
            value = "https://\(value)"
        }
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    private static func raceSite(_ url: URL) async -> URL {
        var candidates: [URL] = []
        for site in sites {
            if let candidate = URL(string: "\(site)/\(url.absoluteString)") {
                candidates.append(candidate)
            }
        }
        candidates.append(url)

        return await withTaskGroup(of: URL?.self) { group in
            for candidate in candidates {
                group.addTask {
                    var request = URLRequest(url: candidate)
                    request.timeoutInterval = 8
                    request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                    guard let (_, response) = try? await URLSession.shared.data(for: request),
                          let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else { return nil }
                    return candidate
                }
            }
            while let winner = await group.next() {
                if let winner {
                    group.cancelAll()
                    return winner
                }
            }
            return url
        }
    }
}
