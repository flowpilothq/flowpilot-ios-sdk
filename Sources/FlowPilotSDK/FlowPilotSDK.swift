// FlowPilot iOS SDK
// Version: 1.0.0
// Copyright (c) 2024 FlowPilot

/// FlowPilot SDK for iOS
///
/// A cross-platform SDK for rendering dynamic in-app flows, onboarding experiences,
/// and A/B tested UI without app store releases.
///
/// ## Getting Started
///
/// ```swift
/// // 1. Configure the SDK at app launch
/// FlowPilot.configure(FlowPilotConfiguration(
///     apiKey: "fp_live_xxx",
///     appId: "your-app-id",
///     environment: .production
/// ))
///
/// // 2. Present a flow from a placement
/// if let flowPilot = FlowPilot.shared {
///     try await flowPilot.presentPlacement(
///         "onboarding",
///         from: viewController
///     )
/// }
/// ```
///
/// ## SwiftUI Integration
///
/// ```swift
/// struct ContentView: View {
///     @State private var flowSession: FlowSession?
///
///     var body: some View {
///         Button("Start Flow") {
///             Task {
///                 flowSession = try? await FlowPilot.shared?.createSession(
///                     placementKey: "onboarding"
///                 )
///             }
///         }
///         .flowPresenter(session: $flowSession) { result in
///             print("Flow completed: \(result.outcome)")
///         }
///     }
/// }
/// ```

// MARK: - Core
@_exported import Foundation

// Re-exported short-prefix aliases.
//
// The SDK standardised on the `FlowPilot*` naming. The `FP*` aliases are kept
// for source compatibility with v1.0 integrators and are marked deprecated so
// existing call sites surface a renaming hint in Xcode.
@available(*, deprecated, renamed: "FlowPilotConfiguration")
public typealias FPConfiguration = FlowPilotConfiguration

@available(*, deprecated, renamed: "FlowPilotEnvironment")
public typealias FPEnvironment = FlowPilotEnvironment

@available(*, deprecated, renamed: "FlowPilotLogLevel")
public typealias FPLogLevel = FlowPilotLogLevel

@available(*, deprecated, renamed: "FlowPilotError")
public typealias FPError = FlowPilotError

@available(*, deprecated, renamed: "FlowPilotErrorCode")
public typealias FPErrorCode = FlowPilotErrorCode
