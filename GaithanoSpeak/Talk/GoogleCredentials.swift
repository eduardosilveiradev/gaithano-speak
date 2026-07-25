import Foundation
import SpeakCore

/// Reads gcloud Application Default Credentials and exchanges the stored refresh
/// token for short-lived access tokens.
///
/// Only the `authorized_user` ADC type is supported — the one `gcloud auth
/// application-default login` writes. Service-account keys are deliberately not
/// handled: they would require RS256 JWT signing, and a desktop app has no business
/// carrying a service-account private key around.
actor GoogleCredentials {
    /// Where `gcloud auth application-default login` writes its credentials.
    static let adcPath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/gcloud/application_default_credentials.json")

    private struct ADC: Decodable {
        let type: String?
        let clientID: String?
        let clientSecret: String?
        let refreshToken: String?
        let quotaProjectID: String?

        enum CodingKeys: String, CodingKey {
            case type
            case clientID = "client_id"
            case clientSecret = "client_secret"
            case refreshToken = "refresh_token"
            case quotaProjectID = "quota_project_id"
        }
    }

    private var cachedToken: String?
    private var cachedExpiry: Date?
    private var cachedADC: ADC?

    /// Whether usable credentials exist, without performing a network exchange.
    /// Used by Settings to show status, and by the coordinator to decide whether to
    /// fall back to the local provider before paying for a round trip.
    static var isConfigured: Bool {
        guard let data = try? Data(contentsOf: adcPath),
              let adc = try? JSONDecoder().decode(ADC.self, from: data) else { return false }
        return adc.type == "authorized_user" && adc.refreshToken?.isEmpty == false
    }

    /// The project ADC was set up against, used when the user hasn't overridden it.
    static var defaultProjectID: String? {
        guard let data = try? Data(contentsOf: adcPath),
              let adc = try? JSONDecoder().decode(ADC.self, from: data) else { return nil }
        return adc.quotaProjectID
    }

    private func loadADC() throws -> ADC {
        if let cachedADC { return cachedADC }
        guard let data = try? Data(contentsOf: Self.adcPath) else {
            throw TalkError.notConfigured("no gcloud credentials — run `gcloud auth application-default login`")
        }
        guard let adc = try? JSONDecoder().decode(ADC.self, from: data) else {
            throw TalkError.notConfigured("gcloud credentials file is unreadable")
        }
        guard adc.type == "authorized_user" else {
            throw TalkError.notConfigured("unsupported credential type '\(adc.type ?? "unknown")' — run `gcloud auth application-default login`")
        }
        guard adc.clientID != nil, adc.clientSecret != nil, adc.refreshToken != nil else {
            throw TalkError.notConfigured("gcloud credentials are missing required fields")
        }
        cachedADC = adc
        return adc
    }

    /// A valid access token, exchanging the refresh token only when the cached one
    /// is absent or within the expiry skew. Google's tokens last an hour, so in
    /// practice this hits the network roughly once per session.
    func accessToken() async throws -> String {
        if let cachedToken, let cachedExpiry, cachedExpiry.timeIntervalSinceNow > Self.expirySkew {
            return cachedToken
        }
        let adc = try loadADC()

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": adc.clientID!,
            "client_secret": adc.clientSecret!,
            "refresh_token": adc.refreshToken!,
            "grant_type": "refresh_token",
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw TalkError.unreachable("token exchange failed: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            // A revoked or expired refresh token lands here; treat it as
            // not-configured so the caller falls back rather than nagging.
            throw TalkError.notConfigured("gcloud token exchange failed (HTTP \(code)) — try `gcloud auth application-default login` again")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else {
            throw TalkError.notConfigured("gcloud token exchange returned no access token")
        }

        let lifetime = (json["expires_in"] as? Double) ?? 3600
        cachedToken = token
        cachedExpiry = Date().addingTimeInterval(lifetime)
        Log.talk.info("Refreshed GCP access token (valid \(Int(lifetime))s)")
        return token
    }

    /// Refresh a little before the token actually dies, so a request that starts
    /// just under the wire doesn't fail mid-stream.
    private static let expirySkew: TimeInterval = 120

    /// Drop the cached token, forcing the next call to re-exchange. Called when a
    /// request comes back 401 despite a token we believed was live.
    func invalidate() {
        cachedToken = nil
        cachedExpiry = nil
        cachedADC = nil
    }
}
