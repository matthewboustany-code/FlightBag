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
}

extension HTTPGetting {
    public func get(_ url: URL, headers: [String: String]) async throws -> Data {
        try await get(url)
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
        var request = URLRequest(url: url)
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
