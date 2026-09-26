import Foundation
import Testing
@testable import BinsCore

private func day(_ iso: String) -> CollectionDay { CollectionDay(isoString: iso)! }

private func london(_ iso: String, _ hour: Int, _ minute: Int = 0) -> Date {
    day(iso).date(hour: hour, minute: minute)
}

private let property = SavedProperty(propertyId: "3642936", displayAddress: "1 Example Road", postcode: "BR3 1AA")

private func collection(_ date: String, _ type: String, _ kind: BinCollectionType) -> BinCollection {
    BinCollection(date: day(date), type: "\(type) collection", label: type, normalizedType: kind)
}

private let schedule = [
    collection("2026-10-02", "Food Waste", .food),
    collection("2026-10-02", "Mixed Recycling (Cans, Plastics & Glass)", .recycling),
    collection("2026-10-09", "Food Waste", .food),
    collection("2026-10-09", "Paper & Cardboard", .paper),
    collection("2026-10-09", "Non-Recyclable Refuse", .refuse),
    collection("2026-10-16", "Food Waste", .food),
    collection("2026-10-16", "Mixed Recycling (Cans, Plastics & Glass)", .recycling),
]

@Suite struct CollectionDayTests {
    @Test func parsesAndFormatsISODates() {
        #expect(day("2026-10-02").isoString == "2026-10-02")
        #expect(CollectionDay(isoString: "2026-02-30") == nil)
        #expect(CollectionDay(isoString: "2026-10-2") == nil)
        #expect(CollectionDay(isoString: "20261002") == nil)
    }

    @Test func todayIsLondonsToday() {
        // 23:30 UTC on 27 June is 00:30 on 28 June in London (BST).
        let lateUTC = Date(timeIntervalSince1970: 1_782_603_000) // 2026-06-27T23:30:00Z
        #expect(CollectionDay(containing: lateUTC) == day("2026-06-28"))
        // In winter London is on UTC.
        let winter = Date(timeIntervalSince1970: 1_798_761_000) // 2026-12-31T23:50:00Z
        #expect(CollectionDay(containing: winter) == day("2026-12-31"))
    }

    @Test func dayArithmeticAcrossDSTChanges() {
        // Clocks go back on 25 Oct 2026 and forward on 28 Mar 2027.
        #expect(day("2026-10-24").days(until: day("2026-10-26")) == 2)
        #expect(day("2027-03-27").adding(days: 2) == day("2027-03-29"))
        #expect(day("2026-12-31").adding(days: 1) == day("2027-01-01"))
    }

    @Test func decodesFromAPIJSONWithoutShifting() throws {
        let json = #"{"date":"2027-01-01","type":"Food Waste collection","label":"Food Waste","normalizedType":"food"}"#
        let decoded = try JSONDecoder().decode(BinCollection.self, from: Data(json.utf8))
        #expect(decoded.date == day("2027-01-01"))
        #expect(decoded.normalizedType == .food)
    }

    @Test func unknownTypesDecodeAsOther() throws {
        let json = #"{"date":"2027-01-01","type":"Bulky Items collection","normalizedType":"bulky"}"#
        let decoded = try JSONDecoder().decode(BinCollection.self, from: Data(json.utf8))
        #expect(decoded.normalizedType == .other)
        #expect(decoded.label == "Bulky Items collection")
    }
}

@Suite struct ScheduleTests {
    @Test func groupsByDayFromToday() {
        let state = BinsState(property: property, collections: schedule)
        let groups = state.upcomingGroups(from: day("2026-10-03"))
        #expect(groups.map(\.day) == [day("2026-10-09"), day("2026-10-16")])
        #expect(groups[0].collections.map(\.normalizedType) == [.food, .paper, .refuse])
    }

    @Test func todaysCollectionsStillCount() {
        let state = BinsState(property: property, collections: schedule)
        #expect(state.nextGroup(from: day("2026-10-02"))?.day == day("2026-10-02"))
    }

    @Test func hiddenTypesAreFilteredOut() {
        let state = BinsState(
            property: property,
            collections: schedule,
            hiddenTypes: ["Food Waste collection", "Mixed Recycling (Cans, Plastics & Glass) collection"]
        )
        #expect(state.nextGroup(from: day("2026-10-01"))?.day == day("2026-10-09"))
        #expect(state.knownTypes.count == 4)
    }

    @Test func nextDateByTypeListsEachBinOnce() {
        let state = BinsState(property: property, collections: schedule)
        let later = state.nextDateByType(after: day("2026-10-02"))
        #expect(later.map(\.label) == ["Food Waste", "Paper & Cardboard", "Non-Recyclable Refuse", "Mixed Recycling (Cans, Plastics & Glass)"])
        #expect(later.last?.date == day("2026-10-16"))
    }

    @Test func formatting() {
        #expect(ScheduleFormatting.relative(day("2026-10-02"), from: day("2026-10-02")) == "Today")
        #expect(ScheduleFormatting.relative(day("2026-10-03"), from: day("2026-10-02")) == "Tomorrow")
        #expect(ScheduleFormatting.relative(day("2026-10-08"), from: day("2026-10-02")) == "In 6 days")
        #expect(ScheduleFormatting.long(day("2026-10-02")) == "Friday 2 October")
        #expect(ScheduleFormatting.list(["Food Waste", "Paper & Cardboard"]) == "Food Waste and Paper & Cardboard")
    }
}

@Suite struct StateTests {
    private func response(_ collections: [BinCollection], propertyId: String = "3642936") -> CollectionsResponse {
        CollectionsResponse(propertyId: propertyId, collections: collections, lastUpdated: Date(timeIntervalSince1970: 100), stale: false)
    }

    @Test func applyingAResponseReplacesTheSchedule() {
        let state = BinsState(property: property, collections: Array(schedule.prefix(2)))
        let now = Date(timeIntervalSince1970: 200)
        let next = state.applying(response(schedule), receivedAt: now)
        #expect(next.collections == schedule)
        #expect(next.lastSuccessfulRefresh == now)
    }

    @Test func anEmptyResponseNeverWipesAGoodSchedule() {
        let state = BinsState(property: property, collections: schedule)
        #expect(state.applying(response([]), receivedAt: .now).collections == schedule)
    }

    @Test func aResponseForAnotherPropertyIsIgnored() {
        let state = BinsState(property: property, collections: schedule)
        #expect(state.applying(response([], propertyId: "1"), receivedAt: .now) == state)
    }

    @Test func storeRoundTrips() throws {
        let url = URL.temporaryDirectory.appending(path: "bins-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BinsStore(fileURL: url)
        #expect(store.load() == .empty)

        var state = BinsState(property: property, collections: schedule, lastSuccessfulRefresh: Date(timeIntervalSince1970: 1_000))
        state.hiddenTypes = ["Food Waste collection"]
        state.reminders = ReminderSettings(isEnabled: true, hour: 20, minute: 30)
        try store.save(state)
        #expect(store.load() == state)
    }

    @Test func aCorruptFileLoadsAsEmpty() throws {
        let url = URL.temporaryDirectory.appending(path: "bins-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        #expect(BinsStore(fileURL: url).load() == .empty)
    }
}

@Suite struct ReminderPlannerTests {
    private func state(enabled: Bool = true) -> BinsState {
        BinsState(property: property, collections: schedule, reminders: ReminderSettings(isEnabled: enabled, hour: 19, minute: 0))
    }

    @Test func oneReminderPerDayOnTheEveningBefore() {
        let reminders = ReminderPlanner.plan(for: state(), now: london("2026-09-30", 12))
        #expect(reminders.count == 3)
        #expect(reminders[0].fireDate == london("2026-10-01", 19))
        #expect(reminders[0].collectionDay == day("2026-10-02"))
        #expect(reminders[0].body == "Food Waste and Mixed Recycling (Cans, Plastics & Glass) are being collected tomorrow.")
    }

    @Test func skipsRemindersWhoseTimeHasPassed() {
        let reminders = ReminderPlanner.plan(for: state(), now: london("2026-10-01", 19, 30))
        #expect(reminders.first?.collectionDay == day("2026-10-09"))
    }

    @Test func respectsHiddenTypesAndSingularWording() {
        var state = state()
        state.hiddenTypes = ["Mixed Recycling (Cans, Plastics & Glass) collection"]
        let reminders = ReminderPlanner.plan(for: state, now: london("2026-09-30", 12))
        #expect(reminders[0].body == "Food Waste is being collected tomorrow.")
    }

    @Test func identifiersAreStableAndUnique() {
        let first = ReminderPlanner.plan(for: state(), now: london("2026-09-30", 12)).map(\.id)
        let second = ReminderPlanner.plan(for: state(), now: london("2026-09-30", 13)).map(\.id)
        #expect(first == second)
        #expect(Set(first).count == first.count)
        #expect(first.allSatisfy { $0.hasPrefix(ReminderPlanner.identifierPrefix + "3642936.") })
    }

    @Test func nothingWhenDisabledOrNoProperty() {
        #expect(ReminderPlanner.plan(for: state(enabled: false), now: london("2026-09-30", 12)).isEmpty)
        var noProperty = state()
        noProperty.property = nil
        #expect(ReminderPlanner.plan(for: noProperty, now: london("2026-09-30", 12)).isEmpty)
    }
}

@Suite struct APIClientTests {
    @Test func mapsServerErrorCodes() {
        let body = { (code: String) in Data(#"{"error":{"code":"\#(code)","message":"x"}}"#.utf8) }
        #expect(BinsAPIClient.error(status: 400, body: body("INVALID_POSTCODE")) == .invalidPostcode)
        #expect(BinsAPIClient.error(status: 404, body: body("NO_ADDRESSES_FOUND")) == .noAddressesFound)
        #expect(BinsAPIClient.error(status: 404, body: body("PROPERTY_NOT_FOUND")) == .propertyNotFound)
        #expect(BinsAPIClient.error(status: 504, body: body("UPSTREAM_TIMEOUT")) == .councilUnavailable)
        #expect(BinsAPIClient.error(status: 429, body: Data()) == .rateLimited)
        #expect(BinsAPIClient.error(status: 500, body: Data("<html>".utf8)) == .unexpected("HTTP 500"))
    }

    @Test func decodesCollectionsResponse() throws {
        let json = """
        {"propertyId":"3642936","collections":[{"date":"2026-10-02","type":"Food Waste collection","label":"Food Waste","normalizedType":"food"}],
         "lastUpdated":"2026-09-26T22:30:00.123Z","stale":true}
        """
        let response = try BinsAPIClient.decoder.decode(CollectionsResponse.self, from: Data(json.utf8))
        #expect(response.stale)
        #expect(response.collections.first?.date == day("2026-10-02"))
        #expect(abs(response.lastUpdated.timeIntervalSince1970 - 1_790_461_800.123) < 0.01)
    }
}
