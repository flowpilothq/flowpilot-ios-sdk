import Foundation

// MARK: - Event Service

/// Service for sending analytics events to the FlowPilot API
final class EventService: @unchecked Sendable {
    private let apiClient: APIClient
    let appId: String

    init(apiClient: APIClient, appId: String) {
        self.apiClient = apiClient
        self.appId = appId
    }

    // MARK: - Send Events

    /// Send a batch of events to the API
    func sendEvents(_ events: [AnalyticsEvent]) async throws -> EventResponse {
        guard !events.isEmpty else {
            return EventResponse(accepted: 0, rejected: 0)
        }

        Logger.shared.debug("Sending \(events.count) events to API")

        let response: EventResponse = try await apiClient.request(
            method: .POST,
            path: "/apps/\(appId)/events",
            body: events,
            timeout: 10
        )

        Logger.shared.debug("Events sent: \(response.accepted) accepted, \(response.rejected) rejected")

        return response
    }

    /// Send a single event
    func sendEvent(_ event: AnalyticsEvent) async throws -> EventResponse {
        return try await sendEvents([event])
    }
}

// MARK: - Event Response

/// Response from the events API
struct EventResponse: Decodable, Sendable {
    /// Number of events accepted
    let accepted: Int

    /// Number of events rejected
    let rejected: Int
}
