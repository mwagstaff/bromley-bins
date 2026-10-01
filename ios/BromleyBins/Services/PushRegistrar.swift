import ActivityKit
import BinsCore
import Foundation
import os
import UIKit

/// Registers this device with the server so it can push reminders and start
/// Live Activities at the right time even if the app hasn't run for weeks.
///
/// The server only ever receives push tokens, the council property ID and
/// reminder preferences. Local scheduling stays as a fallback and stands down
/// only for whatever the server has confirmed it will send.
@MainActor
final class PushRegistrar {
    static let shared = PushRegistrar()

    /// Called when a push token arrives or changes, so registration can catch up.
    var onTokensChanged: (() -> Void)?

    private(set) var apnsToken: String?
    private(set) var liveActivityToken: String?
    let installationId: UUID

    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "dev.skynolimit.bromleybins", category: "push")
    private static let installationIdKey = "push.installationId"
    private static let confirmedKey = "push.confirmedRegistration"
    private static let confirmedAtKey = "push.confirmedAt"
    /// Re-registering daily keeps tokens fresh on the server.
    private static let refreshInterval: TimeInterval = 24 * 60 * 60

    private init() {
        if let stored = defaults.string(forKey: Self.installationIdKey), let id = UUID(uuidString: stored) {
            installationId = id
        } else {
            installationId = UUID()
            defaults.set(installationId.uuidString, forKey: Self.installationIdKey)
        }
    }

    static var environment: DeviceRegistration.Environment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }

    /// What the server last accepted, if anything.
    private(set) var confirmed: DeviceRegistration? {
        get {
            defaults.data(forKey: Self.confirmedKey).flatMap { try? JSONDecoder().decode(DeviceRegistration.self, from: $0) }
        }
        set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.confirmedKey)
            defaults.set(newValue == nil ? nil : Date.now, forKey: Self.confirmedAtKey)
        }
    }

    /// The server is sending evening reminder notifications for this device.
    var serverSendsNotifications: Bool {
        guard let confirmed else { return false }
        return confirmed.apnsToken != nil && confirmed.reminders.enabled
    }

    /// The server is starting bin-day Live Activities for this device.
    var serverStartsLiveActivities: Bool {
        guard let confirmed else { return false }
        return confirmed.liveActivityToken != nil && confirmed.reminders.enabled && confirmed.reminders.showsLiveActivity
    }

    func start() {
        UIApplication.shared.registerForRemoteNotifications()
        Task {
            for await token in Activity<BinDayActivityAttributes>.pushToStartTokenUpdates {
                liveActivityToken = token.hexString
                onTokensChanged?()
            }
        }
    }

    func didRegister(deviceToken: Data) {
        let token = deviceToken.hexString
        guard token != apnsToken else { return }
        apnsToken = token
        onTokensChanged?()
    }

    func didFailToRegister(_ error: any Error) {
        logger.notice("Remote notification registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Brings the server in line with `state`. Never throws: on failure the
    /// previous confirmation stands and this is retried on the next change or
    /// foregrounding.
    func sync(with state: BinsState, api: any BinsAPI) async {
        guard let property = state.property else {
            if confirmed != nil {
                do {
                    try await api.unregister(installationId: installationId)
                    confirmed = nil
                } catch {
                    logger.notice("Unregister failed: \(String(describing: error), privacy: .public)")
                }
            }
            return
        }
        guard apnsToken != nil || liveActivityToken != nil else { return }

        let registration = DeviceRegistration(
            apnsToken: apnsToken,
            liveActivityToken: liveActivityToken,
            environment: Self.environment,
            propertyId: property.propertyId,
            reminders: state.reminders,
            hiddenTypes: state.hiddenTypes
        )
        let confirmedAt = defaults.object(forKey: Self.confirmedAtKey) as? Date ?? .distantPast
        if registration == confirmed, Date.now.timeIntervalSince(confirmedAt) < Self.refreshInterval { return }

        do {
            try await api.register(registration, installationId: installationId)
            confirmed = registration
        } catch {
            logger.notice("Register failed: \(String(describing: error), privacy: .public)")
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistrar.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushRegistrar.shared.didFailToRegister(error)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
