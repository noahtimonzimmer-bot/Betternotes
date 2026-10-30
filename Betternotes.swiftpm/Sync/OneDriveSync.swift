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
/// STATUS: sign-in, upload, download. Conflict handling (newest `modified` wins,
/// loser kept as "<title> (Konflikt)") is the next step.
@MainActor
final class OneDriveSync: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let clientID = "REPLACE_WITH_AZURE_CLIENT_ID"
    private let redirect = "betternotes://auth"
    private let scopes = "Files.ReadWrite.AppFolder offline_access"
    private let tokenURL = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!

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

    func upload(_ file: URL, to remotePath: String) async throws {
        var req = URLRequest(url: contentURL(remotePath))
        req.httpMethod = "PUT"
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 300 else { throw URLError(.badServerResponse) }
    }

    func download(_ remotePath: String, to file: URL) async throws {
        var req = URLRequest(url: contentURL(remotePath))
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 300 else { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)
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
