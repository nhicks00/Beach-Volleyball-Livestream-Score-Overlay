//
//  APIClient.swift
//  MultiCourtScore v2
//
//  Network client for API requests with retry logic
//

import Foundation

actor APIClient {
    private let session: URLSession
    private let maxRetries: Int
    private let retryDelay: TimeInterval
    
    init(
        session: URLSession = .shared,
        maxRetries: Int = NetworkConstants.maxRetries,
        retryDelay: TimeInterval = NetworkConstants.retryDelay
    ) {
        self.session = session
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
    }
    
    // MARK: - Public Methods
    
    func fetchData(from url: URL) async throws -> Data {
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 10
                
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw APIError.invalidResponse
                }
                
                guard (200..<300).contains(httpResponse.statusCode) else {
                    throw APIError.httpError(statusCode: httpResponse.statusCode)
                }
                
                return data
            } catch {
                lastError = error
                
                // Don't retry on certain errors
                if case APIError.httpError(let code) = error, (400..<500).contains(code) {
                    throw error
                }
                
                // Wait before retry (propagate cancellation)
                if attempt < maxRetries - 1 {
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? APIError.unknown
    }
    
    func fetchJSON<T: Decodable>(from url: URL, as type: T.Type) async throws -> T {
        let data = try await fetchData(from: url)
        return try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - API Errors
enum APIError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError(Error)
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .unknown:
            return "Unknown network error"
        }
    }
}
