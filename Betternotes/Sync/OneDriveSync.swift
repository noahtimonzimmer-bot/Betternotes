import Foundation
import MSAL

/// Two-way sync of the Notebooks folder with OneDrive (Microsoft Graph, app folder
/// `Apps/Betternotes`). Needs an Azure app registration; put its client id below.
///
/// STATUS: sign-in and upload/download primitives. Conflict handling (newest
/// `modified` wins, loser kept as "<title> (Konflikt)") is the next step.
@MainActor
final class OneDriveSync: ObservableObject {
    static let clientID = "REPLACE_WITH_AZURE_CLIENT_ID"
    private let scopes = ["Files.ReadWrite.AppFolder", "offline_access"]
    private var app: MSALPublicClientApplication?
    private var account: MSALAccount?

    func signIn(from viewController: UIViewController) async throws {
        let cfg = MSALPublicClientApplicationConfig(clientId: Self.clientID)
        let app = try MSALPublicClientApplication(configuration: cfg)
        self.app = app
        let params = MSALInteractiveTokenParameters(scopes: scopes,
                                                    webviewParameters: MSALWebviewParameters(authPresentationViewController: viewController))
        let result = try await app.acquireToken(with: params)
        account = result.account
    }

    private func token() async throws -> String {
        guard let app, let account else { throw URLError(.userAuthenticationRequired) }
        let params = MSALSilentTokenParameters(scopes: scopes, account: account)
        return try await app.acquireTokenSilent(with: params).accessToken
    }

    func upload(_ file: URL, to remotePath: String) async throws {
        let enc = remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remotePath
        var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(enc):/content")!)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 300 else { throw URLError(.badServerResponse) }
    }

    func download(_ remotePath: String, to file: URL) async throws {
        let enc = remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remotePath
        var req = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(enc):/content")!)
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 300 else { throw URLError(.badServerResponse) }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)
    }
}
