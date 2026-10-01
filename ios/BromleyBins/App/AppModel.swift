import BinsCore
import Foundation
import Observation
import os
import WidgetKit

/// App-wide state: the saved address, its schedule and the user's preferences.
/// Shows persisted data immediately, refreshes in the background, and keeps
/// reminders and widgets in step with every change.
@MainActor
@Observable
final class AppModel {
    private(set) var state: BinsState
    private(set) var isRefreshing = false
    /// The most recent refresh failure, cleared by the next success.
    private(set) var refreshError: BinsAPIError?
    /// London's "today"; advanced when the day changes while the app is open.
    private(set) var today = CollectionDay(containing: .now)

    let api: any BinsAPI
    /// Postcode lookups go straight to the council, never to our server.
    let addressLookup: any AddressLookup
    private let store: BinsStore
    private let reminders: ReminderScheduler
    private let liveActivities = LiveActivityScheduler.shared
    private let push = PushRegistrar.shared
    private let logger = Logger(subsystem: "dev.skynolimit.bromleybins", category: "model")

    /// Refreshing more often than this on foregrounding adds nothing: the API
    /// caches the council's calendar for hours.
    private static let foregroundRefreshInterval: TimeInterval = 30 * 60

    init(
        api: any BinsAPI = BinsAPIClient(baseURL: AppModel.apiBaseURL),
        addressLookup: any AddressLookup = CouncilAddressLookup(),
        store: BinsStore = .shared(),
        reminders: ReminderScheduler = ReminderScheduler()
    ) {
        self.api = api
        self.addressLookup = addressLookup
        self.store = store
        self.reminders = reminders
        self.state = store.load()
    }

    var hasProperty: Bool { state.property != nil }

    /// Registers for pushes; re-syncs with the server whenever a token arrives.
    func startPush() {
        push.onTokensChanged = { [weak self] in
            Task { await self?.syncReminders() }
        }
        push.start()
    }

    /// Debug builds can point at a local API with the BINS_API_BASE_URL
    /// environment variable; release builds always use production.
    nonisolated static var apiBaseURL: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["BINS_API_BASE_URL"], let url = URL(string: override) {
            return url
        }
        #endif
        return BinsAPIClient.productionBaseURL
    }

    // MARK: - Refreshing

    func refreshIfDue() async {
        today = CollectionDay(containing: .now)
        // Catch up on every foregrounding: re-confirm the server registration
        // and, where the server isn't handling them, local reminders.
        await syncReminders()
        let lastRefresh = state.lastSuccessfulRefresh ?? .distantPast
        guard Date.now.timeIntervalSince(lastRefresh) > Self.foregroundRefreshInterval else { return }
        await refresh()
    }

    func refresh() async {
        guard let property = state.property, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        today = CollectionDay(containing: .now)

        do {
            let response = try await api.collections(propertyId: property.propertyId)
            // The user may have changed address while the request was in flight.
            guard state.property == property else { return }
            refreshError = nil
            await update(state.applying(response, receivedAt: .now))
        } catch {
            logger.notice("Refresh failed: \(String(describing: error), privacy: .public)")
            refreshError = error
        }
        await liveActivities.reconcile(with: state, allowRequests: !push.serverStartsLiveActivities)
    }

    func dayDidChange() {
        today = CollectionDay(containing: .now)
    }

    // MARK: - Address

    func choose(_ address: BinAddress, postcode: String) async {
        let property = SavedProperty(propertyId: address.propertyId, displayAddress: address.address, postcode: postcode)
        var next = BinsState(property: property, reminders: state.reminders)
        next.hiddenTypes = []
        refreshError = nil
        await update(next)
        await refresh()
    }

    func forgetAddress() async {
        refreshError = nil
        await update(BinsState(reminders: state.reminders))
    }

    // MARK: - Preferences

    func setType(_ type: String, visible: Bool) async {
        var next = state
        if visible {
            next.hiddenTypes.remove(type)
        } else {
            next.hiddenTypes.insert(type)
        }
        await update(next)
    }

    /// Returns false if the user has declined notification permission.
    @discardableResult
    func setRemindersEnabled(_ enabled: Bool) async -> Bool {
        if enabled, await !reminders.requestAuthorization() {
            return false
        }
        var next = state
        next.reminders.isEnabled = enabled
        await update(next)
        return true
    }

    func setReminderTime(hour: Int, minute: Int) async {
        var next = state
        next.reminders.hour = hour
        next.reminders.minute = minute
        await update(next)
    }

    func setShowsLiveActivity(_ shows: Bool) async {
        var next = state
        next.reminders.showsLiveActivity = shows
        await update(next)
    }

    func reminderAuthorizationDenied() async -> Bool {
        await reminders.isDenied()
    }

    // MARK: - Persistence

    /// Saves, then brings reminders and widgets in line with the new state.
    private func update(_ next: BinsState) async {
        guard next != state else { return }
        state = next
        do {
            try store.save(next)
        } catch {
            logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
        await syncReminders()
        WidgetCenter.shared.reloadAllTimelines()
        BackgroundRefresh.schedule()
    }

    /// Tells the server, then schedules locally only what it isn't sending.
    private func syncReminders() async {
        await push.sync(with: state, api: api)
        await reminders.reschedule(for: state, serverSends: push.serverSendsNotifications)
        await liveActivities.reconcile(with: state, allowRequests: !push.serverStartsLiveActivities)
    }

    #if DEBUG
    func resyncReminders() async { await syncReminders() }
    var installationId: UUID { push.installationId }
    var serverSendsNotifications: Bool { push.serverSendsNotifications }
    var serverStartsLiveActivities: Bool { push.serverStartsLiveActivities }
    #endif
}
