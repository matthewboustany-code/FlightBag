import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP abstraction so provider code is transport-agnostic: the app
/// injects URLSession, the server can inject AsyncHTTPClient, tests inject
/// canned fixtures.
public protocol HTTPGetting: Sendable {
    func get(_ url: URL) async throws -> Data
    /// With extra request headers, for providers that authenticate by header
    /// (openAIP's `x-openaip-api-key`). Conformers that don't care inherit the
    /// default, which drops them — existing fixture clients keep working
    /// unchanged.
    func get(_ url: URL, headers: [String: String]) async throws -> Data

    /// POST, for the one thing GET can't express: an OAuth token exchange
    /// (the FAA NMS `client_credentials` grant). The default throws rather
    /// than silently returning nothing, so a transport that hasn't
    /// implemented it fails loudly at the call site instead of looking like
    /// an empty response.
    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> Data
}

extension HTTPGetting {
    public func get(_ url: URL, headers: [String: String]) async throws -> Data {
        try await get(url)
    }

    public func post(_ url: URL, body: Data, headers: [String: String]) async throws -> Data {
        throw HTTPError(statusCode: 405, url: url)
    }
}

public struct HTTPError: Error, Sendable {
    public let statusCode: Int
    public let url: URL

    public init(statusCode: Int, url: URL) {
        self.statusCode = statusCode
        self.url = url
    }
}

public struct URLSessionHTTPClient: HTTPGetting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(_ url: URL) async throws -> Data {
        try await get(url, headers: [:])
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> Data {
        try await send(url, method: "GET", body: nil, headers: headers)
    }

    public func post(_ url: URL, body: Data, headers: [String: String]) async throws -> Data {
        try await send(url, method: "POST", body: body, headers: headers)
    }

    private func send(_ url: URL, method: String, body: Data?, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("FlightBag/1.0", forHTTPHeaderField: "User-Agent")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(statusCode: http.statusCode, url: url)
        }
        return data
    }
}
