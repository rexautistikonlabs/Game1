//
//  StripeConnectOAuth.swift
//  FieldForge
//
//  Express OAuth for downloading orgs. The iPhone opens Stripe's hosted
//  onboarding; Azure exchanges the code and redirects to fieldforge:// with
//  acct_…. This app never sees ca_, sk_, or the Azure URL in the normal UI.
//

import AuthenticationServices
import Foundation
import UIKit

@MainActor
final class StripeConnectOAuth: NSObject {

    static let callbackScheme = "fieldforge"

    enum Outcome: Equatable {
        case connected(accountID: String)
        case cancelled
        case failed(String)
    }

    private var session: ASWebAuthenticationSession?
    private let presenter = AuthPresenter()

    func connect(businessName: String, backendOrigin: String) async -> Outcome {
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        guard let startURL = Self.oauthStartURL(backendOrigin: backendOrigin) else {
            return .failed("Could not start Stripe Connect.")
        }

        var request = URLRequest(url: startURL, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let state: String
            let businessName: String
        }
        request.httpBody = try? JSONEncoder().encode(Body(state: state, businessName: businessName))

        let authorizeURL: URL
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failed("Connect is not configured on the server yet.")
            }
            struct Reply: Decodable { var url: String? }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
                  let raw = reply.url, let url = URL(string: raw) else {
                return .failed("Connect is not configured on the server yet.")
            }
            authorizeURL = url
        } catch {
            return .failed("Could not reach Stripe Connect. Try again on a connection.")
        }

        let callbackURL: URL
        do {
            callbackURL = try await startSession(authorizeURL: authorizeURL)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }

        return Self.parseCallback(callbackURL, expectedState: state)
    }

    func handleIncomingURL(_ url: URL) -> Outcome? {
        guard url.scheme == Self.callbackScheme else { return nil }
        return Self.parseCallback(url, expectedState: nil)
    }

    private func startSession(authorizeURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: Self.callbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: URLError(.badURL))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self.presenter
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: URLError(.unknown))
            }
        }
    }

    nonisolated static func oauthStartURL(backendOrigin: String) -> URL? {
        StripePaymentSettings.resolveAPIURL(backendOrigin, path: "/api/connect/oauth/start")
    }

    nonisolated static func parseCallback(_ url: URL, expectedState: String?) -> Outcome {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        if let error = value("error"), !error.isEmpty {
            if error == "access_denied" { return .cancelled }
            return .failed("Stripe Connect was not completed.")
        }
        if let expectedState, let returned = value("state"), !returned.isEmpty, returned != expectedState {
            return .failed("Connect could not be verified. Try again.")
        }
        guard let account = value("account"), StripeConnectAccount.isValidIdentifier(account) else {
            return .failed("Stripe did not return a connected account.")
        }
        return .connected(accountID: account)
    }
}

private final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return key
        }
        return scenes.flatMap(\.windows).first ?? ASPresentationAnchor()
    }
}
