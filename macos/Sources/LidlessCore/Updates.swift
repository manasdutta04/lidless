import Foundation

/// A published release on GitHub.
public struct ReleaseInfo: Sendable, Equatable {
    public var version: String
    public var pageURL: URL
    /// The DMG asset, when the release has one.
    public var downloadURL: URL?
    public var downloadName: String?
    public var notes: String
    public var publishedAt: Date?
}

public enum UpdateCheckResult: Sendable, Equatable {
    case upToDate(latest: String)
    case available(ReleaseInfo)
    case noReleases
}

/// Checks GitHub for a newer release. The only network request Lidless makes;
/// it sends nothing but a plain GET for the public release list.
public enum UpdateChecker {
    public static let repository = "manasdutta04/lidless"
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    static let latestAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    /// Compares dotted versions numerically ("0.10.0" > "0.9.3"); a leading
    /// "v" is ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let trimmed = v.hasPrefix("v") ? String(v.dropFirst()) : v
            let core = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Parses the GitHub "latest release" JSON.
    public static func parse(_ data: Data) throws -> ReleaseInfo {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw LidlessError.system("Unexpected response from GitHub.")
        }
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        let dmg = assets.first { (($0["name"] as? String) ?? "").hasSuffix(".dmg") }
        let published = (obj["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return ReleaseInfo(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            pageURL: page,
            downloadURL: (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:)),
            downloadName: dmg?["name"] as? String,
            notes: (obj["body"] as? String) ?? "",
            publishedAt: published
        )
    }

    public static func check(current: String = LidlessVersion.string) async throws -> UpdateCheckResult {
        var request = URLRequest(url: latestAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lidless/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return .noReleases }
        guard status == 200 else { throw LidlessError.system("GitHub answered with status \(status).") }
        let release = try parse(data)
        return isNewer(release.version, than: current) ? .available(release) : .upToDate(latest: release.version)
    }

    /// Downloads the release DMG into ~/Downloads and returns its location.
    public static func download(_ release: ReleaseInfo) async throws -> URL {
        guard let url = release.downloadURL else {
            throw LidlessError.system("This release has no disk image to download.")
        }
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LidlessError.system("The download failed.")
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let dest = downloads.appendingPathComponent(release.downloadName ?? "Lidless-\(release.version).dmg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
