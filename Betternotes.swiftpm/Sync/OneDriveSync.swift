import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Two-way sync of the Notebooks folder with OneDrive (Microsoft Graph, app folder
/// `Apps/Betternotes`). Sign-in via OAuth 2 + PKCE in a system web sheet, so no
/// Microsoft SDK is needed (works in Swift Playgrounds).
///
/// Setup: portal.azure.com › App registrations › New, account type "personal Microsoft
/// accounts", platform "Mobile and desktop", redirect URI `betternotes://auth`.
/// Put the Application (client) ID below.
///
/// Sync is file based: every file under the Notebooks folder is mirrored to the app folder.
/// A file changed on one side only is copied over; changed on both sides, the newer one wins.
/// Deletions are not propagated (nothing is ever removed remotely).
@MainActor
final class OneDriveSync: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let clientID = "REPLACE_WITH_AZURE_CLIENT_ID"
    private let redirect = "betternotes://auth"
    private let scopes = "Files.ReadWrite.AppFolder offline_access"
    private let tokenURL = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!

    @Published private(set) var status: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var isSignedIn = UserDefaults.standard.string(forKey: "onedrive.refresh") != nil
    private var accessToken: String?
    private var expires = Date.distantPast

    func signIn() async throws {
        let verifier = Self.randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var c = URLComponents(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "betternotes") { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? URLError(.cancelled)) }
            }
            session.presentationContextProvider = self
            session.start()
        }
        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else { throw URLError(.userAuthenticationRequired) }
        try await requestToken(["grant_type": "authorization_code", "code": code, "code_verifier": verifier])
    }

    func signOut() {
        UserDefaults.standard.removeObject(forKey: "onedrive.refresh")
        accessToken = nil
        isSignedIn = false
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    private func requestToken(_ params: [String: String]) async throws {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let all = params.merging(["client_id": Self.clientID, "redirect_uri": redirect, "scope": scopes]) { a, _ in a }
        req.httpBody = all.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Token: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double }
        let t = try JSONDecoder().decode(Token.self, from: data)
        accessToken = t.access_token
        expires = Date().addingTimeInterval(t.expires_in - 60)
        if let r = t.refresh_token { UserDefaults.standard.set(r, forKey: "onedrive.refresh") }
        isSignedIn = true
    }

    private func token() async throws -> String {
        if let a = accessToken, Date() < expires { return a }
        guard let refresh = UserDefaults.standard.string(forKey: "onedrive.refresh") else {
            throw URLError(.userAuthenticationRequired)
        }
        try await requestToken(["grant_type": "refresh_token", "refresh_token": refresh])
        return accessToken!
    }

    private func contentURL(_ remotePath: String) -> URL {
        let enc = remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remotePath
        return URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(enc):/content")!
    }

    @discardableResult
    func upload(_ file: URL, to remotePath: String) async throws -> RemoteItem {
        var req = URLRequest(url: contentURL(remotePath))
        req.httpMethod = "PUT"
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 300 else { throw URLError(.badServerResponse) }
        return try Self.decoder.decode(RemoteItem.self, from: data)
    }

    func download(_ remotePath: String, to file: URL) async throws {
        var req = URLRequest(url: contentURL(remotePath))
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 300 else { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)
    }

    // MARK: Two-way sync

    struct RemoteItem: Decodable {
        let name: String
        let lastModifiedDateTime: Date
        let folder: FolderFacet?
        struct FolderFacet: Decodable { let childCount: Int }
    }

    private struct Page: Decodable {
        let value: [RemoteItem]
        let next: String?
        enum CodingKeys: String, CodingKey { case value, next = "@odata.nextLink" }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = frac.date(from: s) ?? plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: s))
        }
        return d
    }()

    /// Lists a remote folder (relative to the app folder) recursively: relative path -> modified date.
    private func remoteFiles(_ path: String) async throws -> [String: Date] {
        let base = "https://graph.microsoft.com/v1.0/me/drive/special/approot"
        let enc = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var next: String? = path.isEmpty ? "\(base)/children" : "\(base):/\(enc):/children"
        var out: [String: Date] = [:]
        while let urlString = next, let url = URL(string: urlString) {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return [:] }
            guard code < 300 else { throw URLError(.badServerResponse) }
            let page = try Self.decoder.decode(Page.self, from: data)
            for item in page.value {
                let rel = path.isEmpty ? item.name : "\(path)/\(item.name)"
                if item.folder != nil {
                    out.merge(try await remoteFiles(rel)) { a, _ in a }
                } else {
                    out[rel] = item.lastModifiedDateTime
                }
            }
            next = page.next
        }
        return out
    }

    private func localFiles(_ root: URL) -> [String: Date] {
        var out: [String: Date] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return out }
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let date = v.contentModificationDate else { continue }
            out[String(url.standardizedFileURL.path.dropFirst(prefix.count))] = date
        }
        return out
    }

    /// Mirrors `root` (the Notebooks folder) with OneDrive in both directions.
    func sync(root: URL) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let stateKey = "onedrive.state"
        var state = (UserDefaults.standard.dictionary(forKey: stateKey) as? [String: [Double]]) ?? [:]
        do {
            status = "Vergleiche…"
            let remote = try await remoteFiles("Notebooks")
            let local = localFiles(root)
            var up = 0, down = 0
            for rel in Set(remote.keys.map { String($0.dropFirst("Notebooks/".count)) }).union(local.keys) {
                let l = local[rel], r = remote["Notebooks/\(rel)"]
                let known = state[rel] ?? []
                let localChanged = l.map { known.count < 1 || abs($0.timeIntervalSince1970 - known[0]) > 1 } ?? false
                let remoteChanged = r.map { known.count < 2 || abs($0.timeIntervalSince1970 - known[1]) > 1 } ?? false
                let fileURL = root.appendingPathComponent(rel)
                var upload = false, download = false
                if let l, let r {
                    if localChanged && remoteChanged { upload = l > r; download = !upload }
                    else { upload = localChanged; download = remoteChanged }
                } else {
                    upload = l != nil
                    download = r != nil
                }
                if upload {
                    status = "Hochladen: \(rel)"
                    let item = try await self.upload(fileURL, to: "Notebooks/\(rel)")
                    state[rel] = [l!.timeIntervalSince1970, item.lastModifiedDateTime.timeIntervalSince1970]
                    up += 1
                } else if download {
                    status = "Herunterladen: \(rel)"
                    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await self.download("Notebooks/\(rel)", to: fileURL)
                    let m = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                    state[rel] = [m.timeIntervalSince1970, r!.timeIntervalSince1970]
                    down += 1
                }
                UserDefaults.standard.set(state, forKey: stateKey)
            }
            status = "Fertig: \(up) hochgeladen, \(down) heruntergeladen"
        } catch {
            status = "Fehler: \(error.localizedDescription)"
        }
    }

    private static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
