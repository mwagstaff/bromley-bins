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

@Suite struct BinDayActivityPlannerTests {
    private func state(liveActivity: Bool = true, enabled: Bool = true) -> BinsState {
        BinsState(
            property: property,
            collections: schedule,
            reminders: ReminderSettings(isEnabled: enabled, hour: 19, minute: 0, showsLiveActivity: liveActivity)
        )
    }

    @Test func schedulesEveningAndMorningActivitiesForTheNextCollection() {
        let plan = BinDayActivityPlanner.plan(for: state(), now: london("2026-09-30", 12))
        #expect(plan.map(\.phase) == [.eveningBefore, .collectionDay])
        #expect(plan[0].start == london("2026-10-01", 19))
        #expect(plan[1].start == london("2026-10-02", 7))
        // Evening card goes stale at midnight (then reads "Bin day today"); bin-day card at day end.
        #expect(plan[0].staleDate == day("2026-10-02").startDate)
        #expect(plan[1].staleDate == day("2026-10-03").startDate)
        #expect(plan[0].items.map(\.type) == [.food, .recycling])
        #expect(plan[0].key == "3642936.2026-10-02.eveningBefore")
    }

    @Test func startsImmediatelyInsideTheWindow() {
        let evening = BinDayActivityPlanner.plan(for: state(), now: london("2026-10-01", 21))
        #expect(evening.map(\.phase) == [.eveningBefore, .collectionDay])
        #expect(evening[0].start == nil)
        #expect(evening[1].start == london("2026-10-02", 7))

        let morning = BinDayActivityPlanner.plan(for: state(), now: london("2026-10-02", 9))
        #expect(morning.map(\.phase) == [.collectionDay])
        #expect(morning[0].start == nil)
    }

    @Test func movesOnOnceBinDayIsOver() {
        let plan = BinDayActivityPlanner.plan(for: state(), now: london("2026-10-03", 0, 5))
        #expect(plan.first?.day == day("2026-10-09"))
    }

    @Test func respectsHiddenTypes() {
        var state = state()
        state.hiddenTypes = ["Food Waste collection", "Mixed Recycling (Cans, Plastics & Glass) collection"]
        #expect(BinDayActivityPlanner.plan(for: state, now: london("2026-09-30", 12)).first?.day == day("2026-10-09"))
    }

    @Test func nothingWhenRemindersOrLiveActivitiesAreOff() {
        #expect(BinDayActivityPlanner.plan(for: state(enabled: false), now: london("2026-09-30", 12)).isEmpty)
        #expect(BinDayActivityPlanner.plan(for: state(liveActivity: false), now: london("2026-09-30", 12)).isEmpty)
    }

    @Test func oldSavedSettingsDefaultToShowingLiveActivities() throws {
        let json = #"{"isEnabled":true,"hour":19,"minute":30}"#
        let settings = try JSONDecoder().decode(ReminderSettings.self, from: Data(json.utf8))
        #expect(settings.showsLiveActivity)
        #expect(settings.minute == 30)
    }
}

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct AddressLookupTests {
    @Test func normalisesPostcodes() {
        for input in ["BR31AA", "br31aa", "BR3 1AA", "BR3   1AA", " br3 1aa ", "Br3\t1Aa"] {
            #expect(Postcode.normalize(input) == "BR3 1AA", "\(input)")
        }
        #expect(Postcode.normalize("se96ab") == "SE9 6AB")
        #expect(Postcode.normalize("SW1A1AA") == "SW1A 1AA")
        for input in ["", "BR3", "12345", "BR3 1AAA", "BR3-1AA", "<script>", "BR3 1A"] {
            #expect(Postcode.normalize(input) == nil, "\(input)")
        }
    }

    @Test func parsesTheResultsPage() throws {
        let addresses = try WasteWorksAddressParser.parse(fixture("wasteworks-address-results"))
        #expect(addresses.count == 6)
        #expect(addresses.allSatisfy { $0.propertyId.allSatisfy(\.isNumber) })
        #expect(addresses.first { $0.propertyId == "6150011" }?.address == "Ground Floor Shop, 1 Sample Road, Bromley, BR1 1AA")
        // Natural order, with the blank and "can't find my address" options ignored.
        #expect(addresses.prefix(5).map { $0.address.split(separator: ",")[0] } == ["Flat 1", "Flat 2", "Flat 3", "Flat 4", "Flat 10"])
    }

    @Test func noResultsPageIsEmptyNotAnError() throws {
        #expect(try WasteWorksAddressParser.parse(fixture("wasteworks-address-none")).isEmpty)
    }

    @Test func markupChangesAreErrors() throws {
        let html = try fixture("wasteworks-address-results")
        #expect(throws: WasteWorksAddressParser.ParseError.addressSelectMissing) {
            try WasteWorksAddressParser.parse(html.replacingOccurrences(of: "id=\"address\"", with: "id=\"property\""))
        }
        #expect(throws: WasteWorksAddressParser.ParseError.addressSelectMissing) {
            try WasteWorksAddressParser.parse("<html>Service unavailable</html>")
        }
        #expect(throws: WasteWorksAddressParser.ParseError.noNumericOptions) {
            try WasteWorksAddressParser.parse(html.replacing(/value="([0-9]+)"/) { "value=\"uprn-\($0.output.1)\"" })
        }
    }

    @Test func decodesEntitiesAndDeduplicates() throws {
        let html = """
        <select class="x" id="address"><option value="">Pick</option>
        <option value="42">1  St Mary&#39;s   Road &amp; Annex</option>
        <option value="42">duplicate</option>
        <option value="43">Flat&nbsp;2, O&#x2019;Neill House</option></select>
        """
        #expect(try WasteWorksAddressParser.parse(html) == [
            BinAddress(propertyId: "42", address: "1 St Mary's Road & Annex"),
            BinAddress(propertyId: "43", address: "Flat 2, O\u{2019}Neill House"),
        ])
    }

    @Test func invalidPostcodeNeverReachesTheNetwork() async {
        await #expect(throws: BinsAPIError.invalidPostcode) {
            try await CouncilAddressLookup(baseURL: URL(string: "https://invalid.example")!).addresses(postcode: "nope")
        }
    }
}

@Suite struct DeviceRegistrationTests {
    @Test func encodesWithoutAnyAddressData() throws {
        let registration = DeviceRegistration(
            apnsToken: "aa",
            liveActivityToken: nil,
            environment: .sandbox,
            propertyId: "3642936",
            reminders: ReminderSettings(isEnabled: true, hour: 19, minute: 30, showsLiveActivity: false),
            hiddenTypes: ["Food Waste collection", "A collection"]
        )
        let json = try #require(String(data: JSONEncoder().encode(registration), encoding: .utf8))
        #expect(json.contains(#""propertyId":"3642936""#))
        #expect(json.contains(#""hiddenTypes":["A collection","Food Waste collection"]"#))
        #expect(json.contains(#""environment":"sandbox""#))
        #expect(!json.localizedCaseInsensitiveContains("postcode"))
        #expect(!json.localizedCaseInsensitiveContains("address"))
    }

    @Test func liveActivityAttributesDecodeFromServerJSON() throws {
        #if os(iOS)
        let json = #"{"key":"3642936.2026-10-02.eveningBefore","day":"2026-10-02","phase":"eveningBefore","isTest":false}"#
        let attributes = try JSONDecoder().decode(BinDayActivityAttributes.self, from: Data(json.utf8))
        #expect(attributes.day == day("2026-10-02"))
        #endif
        let state = #"{"items":[{"label":"Food Waste","type":"food"},{"label":"Bulky","type":"bulky"}]}"#
        struct ContentState: Decodable { let items: [BinDayItem] }
        let decoded = try JSONDecoder().decode(ContentState.self, from: Data(state.utf8))
        #expect(decoded.items.map(\.type) == [.food, .other])
    }
}

@Suite struct BinDayPhaseTests {
    @Test func wordingSwitchesWhenStale() {
        #expect(BinDayPhase.eveningBefore.headline(isStale: false) == "Bins out tonight")
        #expect(BinDayPhase.eveningBefore.headline(isStale: true) == "Bin day today")
        #expect(BinDayPhase.collectionDay.headline(isStale: false) == "Bin day today")
        #expect(BinDayPhase.collectionDay.headline(isStale: true) == "Collection day has passed")
        #expect(BinDayPhase.eveningBefore.showsItems(isStale: true))
        #expect(!BinDayPhase.collectionDay.showsItems(isStale: true))
    }

    @Test func handOverIsTwelveHoursAfterTheEveningCard() {
        let collection = day("2026-10-02")
        #expect(BinDayActivityPlanner.collectionDayStart(eveningStart: london("2026-10-01", 19), day: collection) == london("2026-10-02", 7))
        #expect(BinDayActivityPlanner.collectionDayStart(eveningStart: london("2026-10-01", 21), day: collection) == london("2026-10-02", 9))
        // Never before collection day starts.
        #expect(BinDayActivityPlanner.collectionDayStart(eveningStart: london("2026-10-01", 10), day: collection) == collection.startDate)
        // Elapsed time, so the night the clocks go back is 06:00 by the clock.
        #expect(BinDayActivityPlanner.collectionDayStart(eveningStart: london("2026-10-24", 19), day: day("2026-10-25")) == london("2026-10-25", 6))
    }
}
