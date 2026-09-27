import BinsCore
import SwiftUI
import WidgetKit

@main
struct BromleyBinsWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextCollectionWidget()
        BinDayLiveActivity()
    }
}

struct NextCollectionWidget: Widget {
    let kind = "NextCollection"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ScheduleProvider()) { entry in
            NextCollectionWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next collection")
        .description("Which bins go out next, and when.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct ScheduleEntry: TimelineEntry {
    let date: Date
    let state: BinsState

    var today: CollectionDay { CollectionDay(containing: date) }
    var next: CollectionGroup? { state.upcomingGroups(from: today).first }
}

/// Reads only the schedule the app saved to the App Group — widgets never call
/// the network. One entry per London midnight for the next week keeps
/// "Tomorrow"/"Today" correct without any reloads; the app reloads timelines
/// whenever the schedule or preferences change.
struct ScheduleProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScheduleEntry {
        ScheduleEntry(date: .now, state: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
        let state = BinsStore.shared().load()
        let useSample = context.isPreview && state.property == nil
        completion(ScheduleEntry(date: .now, state: useSample ? .sample : state))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
        let state = BinsStore.shared().load()
        let today = CollectionDay(containing: .now)
        var entries = [ScheduleEntry(date: .now, state: state)]
        for offset in 1...7 {
            entries.append(ScheduleEntry(date: today.adding(days: offset).startDate, state: state))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct NextCollectionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ScheduleEntry

    var body: some View {
        if let next = entry.next {
            switch family {
            case .accessoryInline:
                Text("\(ScheduleFormatting.relative(next.day, from: entry.today)): \(next.collections.map(\.label).joined(separator: ", "))")
            case .accessoryCircular:
                CircularView(group: next, today: entry.today)
            case .accessoryRectangular:
                RectangularView(group: next, today: entry.today)
            case .systemMedium:
                MediumView(group: next, today: entry.today)
            default:
                SmallView(group: next, today: entry.today)
            }
        } else {
            EmptyWidgetView(hasProperty: entry.state.property != nil, family: family)
        }
    }
}

private struct DayHeading: View {
    let group: CollectionGroup
    let today: CollectionDay

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ScheduleFormatting.relative(group.day, from: today).uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.binsBrand)
            Text(ScheduleFormatting.short(group.day))
                .font(.headline)
        }
    }
}

private struct SmallView: View {
    let group: CollectionGroup
    let today: CollectionDay

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DayHeading(group: group, today: today)
            Spacer(minLength: 0)
            ForEach(group.collections.prefix(3)) { collection in
                HStack(spacing: 6) {
                    BinBadge(collection.normalizedType, size: 24)
                    Text(collection.label)
                        .font(.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            if group.collections.count > 3 {
                Text("+\(group.collections.count - 3) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MediumView: View {
    let group: CollectionGroup
    let today: CollectionDay

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Next collection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ScheduleFormatting.relative(group.day, from: today))
                    .font(.title2.bold())
                    .foregroundStyle(Color.binsBrand)
                Text(ScheduleFormatting.long(group.day))
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.collections.prefix(4)) { collection in
                    HStack(spacing: 8) {
                        BinBadge(collection.normalizedType, size: 28)
                        Text(collection.label)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RectangularView: View {
    let group: CollectionGroup
    let today: CollectionDay

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(ScheduleFormatting.relative(group.day, from: today)) · \(ScheduleFormatting.short(group.day))")
                .font(.headline)
                .widgetAccentable()
            ForEach(group.collections.prefix(2)) { collection in
                Label(collection.label, systemImage: collection.normalizedType.symbolName)
                    .font(.caption)
                    .lineLimit(1)
            }
            if group.collections.count > 2 {
                Text("+\(group.collections.count - 2) more")
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CircularView: View {
    let group: CollectionGroup
    let today: CollectionDay

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: group.collections.first?.normalizedType.symbolName ?? "trash.fill")
                    .font(.title3)
                Text(group.day.startDate, format: .dateTime.weekday(.abbreviated))
                    .font(.caption2.bold())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ScheduleFormatting.relative(group.day, from: today)): \(ScheduleFormatting.list(group.collections.map(\.label)))")
    }
}

private struct EmptyWidgetView: View {
    let hasProperty: Bool
    let family: WidgetFamily

    var body: some View {
        let message = hasProperty ? "No upcoming collections" : "Open Bromley Bins to choose your address"
        switch family {
        case .accessoryInline, .accessoryCircular:
            Image(systemName: "trash")
                .accessibilityLabel(message)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "trash")
                    .font(.title2)
                    .foregroundStyle(Color.binsBrand)
                Text(message)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private extension BinsState {
    /// Gallery preview only; never shown as real data.
    static var sample: BinsState {
        let today = CollectionDay(containing: .now)
        return BinsState(
            property: SavedProperty(propertyId: "0", displayAddress: "", postcode: ""),
            collections: [
                BinCollection(date: today.adding(days: 1), type: "food", label: "Food Waste", normalizedType: .food),
                BinCollection(date: today.adding(days: 1), type: "recycling", label: "Mixed Recycling", normalizedType: .recycling),
            ]
        )
    }
}

#Preview(as: .systemSmall) {
    NextCollectionWidget()
} timeline: {
    ScheduleEntry(date: .now, state: .sample)
}
