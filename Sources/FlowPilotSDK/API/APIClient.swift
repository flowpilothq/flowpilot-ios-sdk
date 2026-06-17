import Foundation

// MARK: - API Client

/// HTTP client for FlowPilot API
final class APIClient: @unchecked Sendable {
    private let baseURL: String
    private let apiKey: String
    private let appId: String
    private let session: URLSession
    private let retryQueue = DispatchQueue(label: "io.flowpilot.api.retry")

    // Retry configuration
    private let maxRetries = 3
    private let baseRetryDelay: TimeInterval = 1.0
    private let maxRetryDelay: TimeInterval = 60.0

    init(baseURL: String, apiKey: String, appId: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.appId = appId

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - Request Methods

    func request<T: Decodable>(
        method: HTTPMethod,
        path: String,
        body: Encodable? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            // A malformed base URL (e.g. a bad `.custom` environment string) must
            // surface as a catchable error, never a force-unwrap trap that crashes
            // the host app.
            throw FlowPilotError(
                code: .internalError,
                message: "Invalid request URL constructed from baseURL '\(baseURL)' and path '\(path)'"
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("FlowPilotSDK/\(FlowPilotSDK.version) iOS", forHTTPHeaderField: "User-Agent")

        if let timeout = timeout {
            request.timeoutInterval = timeout
        }

        if let body = body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            // Backend uses Go time.Time which expects RFC3339 strings; without
            // this, Date encodes as a number and the whole request body fails
            // to unmarshal server-side (HTTP 400, events silently dropped).
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(body)
        }

        Logger.shared.debug("API Request: \(method.rawValue) \(path)")

        return try await executeWithRetry(request: request)
    }

    // MARK: - Retry Logic

    private func executeWithRetry<T: Decodable>(request: URLRequest, attempt: Int = 0) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw FlowPilotError.networkError(NSError(domain: "FlowPilot", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
            }

            Logger.shared.debug("API Response: \(httpResponse.statusCode)")

            // Handle different status codes
            switch httpResponse.statusCode {
            case 200...299:
                // Log raw response for debugging
                if let rawJson = String(data: data, encoding: .utf8) {
                    Logger.shared.verbose("API Raw Response: \(rawJson)")
                }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(T.self, from: data)

            case 400:
                let errorMessage = String(data: data, encoding: .utf8) ?? "Bad request"
                throw FlowPilotError.apiError(statusCode: 400, message: errorMessage)

            case 401:
                throw FlowPilotError.invalidApiKey(apiKey)

            case 404:
                throw FlowPilotError(code: .placementNotFound, message: "Resource not found")

            case 429:
                // Rate limited - check for retry-after header
                let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { Double($0) } ?? calculateRetryDelay(attempt: attempt)

                if attempt < maxRetries {
                    Logger.shared.warn("Rate limited, retrying after \(retryAfter)s")
                    try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                    return try await executeWithRetry(request: request, attempt: attempt + 1)
                }
                throw FlowPilotError.rateLimited(retryAfter: retryAfter)

            case 500...599:
                // Server error - retry with exponential backoff
                if attempt < maxRetries {
                    let delay = calculateRetryDelay(attempt: attempt)
                    Logger.shared.warn("Server error \(httpResponse.statusCode), retrying after \(delay)s")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    return try await executeWithRetry(request: request, attempt: attempt + 1)
                }
                let errorMessage = String(data: data, encoding: .utf8) ?? "Server error"
                throw FlowPilotError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)

            default:
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw FlowPilotError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
            }

        } catch let error as FlowPilotError {
            throw error
        } catch let error as DecodingError {
            // Log detailed decoding error for debugging
            Logger.shared.error("JSON decoding error: \(error)")
            throw FlowPilotError(
                code: .invalidFlowSchema,
                message: "Failed to decode API response: \(error.localizedDescription)",
                underlyingError: error
            )
        } catch let error as URLError {
            if error.code == .timedOut {
                throw FlowPilotError.timeout()
            }

            // Network error - retry if possible
            if attempt < maxRetries && isRetryableError(error) {
                let delay = calculateRetryDelay(attempt: attempt)
                Logger.shared.warn("Network error, retrying after \(delay)s: \(error.localizedDescription)")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await executeWithRetry(request: request, attempt: attempt + 1)
            }

            throw FlowPilotError.networkError(error)
        } catch {
            throw FlowPilotError.networkError(error)
        }
    }

    private func calculateRetryDelay(attempt: Int) -> TimeInterval {
        // Exponential backoff with jitter
        let exponentialDelay = baseRetryDelay * pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...0.5)
        return min(exponentialDelay + jitter, maxRetryDelay)
    }

    private func isRetryableError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}

// MARK: - HTTP Method

enum HTTPMethod: String {
    case GET
    case POST
    case PUT
    case DELETE
    case PATCH
}
