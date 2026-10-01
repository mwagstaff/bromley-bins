import ActivityKit
import BinsCore
import SwiftUI
import WidgetKit

struct BinDayLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BinDayActivityAttributes.self) { context in
            BinDayLockScreenView(attributes: context.attributes, items: context.state.items, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let items = context.state.items
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "trash.fill")
                        .font(.title2)
                        .foregroundStyle(Color.binsBrand)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.phase.headline(isStale: context.isStale))
                            .font(.headline)
                        Text(ScheduleFormatting.long(context.attributes.day))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    BinItemsList(items: items, badgeSize: 28)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: "trash.fill")
                    .foregroundStyle(Color.binsBrand)
                    .accessibilityLabel(context.attributes.phase.headline(isStale: context.isStale))
            } compactTrailing: {
                HStack(spacing: 2) {
                    ForEach(items.prefix(3), id: \.self) { item in
                        BinBadge(item.type, size: 20)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ScheduleFormatting.list(items.map(\.label)))
            } minimal: {
                Image(systemName: "trash.fill")
                    .foregroundStyle(Color.binsBrand)
                    .accessibilityLabel(context.attributes.phase.headline(isStale: context.isStale))
            }
            .keylineTint(Color.binsBrand)
        }
    }
}

private struct BinDayLockScreenView: View {
    let attributes: BinDayActivityAttributes
    let items: [BinDayItem]
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(attributes.phase.headline(isStale: isStale), systemImage: "trash.fill")
                    .font(.headline)
                    .foregroundStyle(Color.binsBrand)
                Spacer()
                Text(ScheduleFormatting.short(attributes.day))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if attributes.phase.showsItems(isStale: isStale) {
                BinItemsList(items: items, badgeSize: 32)
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

private struct BinItemsList: View {
    let items: [BinDayItem]
    let badgeSize: CGFloat

    /// Live Activities have a fixed maximum height, so beyond three bins
    /// switch from one row per bin to a row of icons and a combined label.
    private static let maximumListedItems = 3

    var body: some View {
        Group {
            if items.count <= Self.maximumListedItems {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 10) {
                            BinBadge(item.type, size: badgeSize)
                            Text(item.label)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ForEach(items, id: \.self) { BinBadge($0.type, size: badgeSize) }
                    }
                    Text(ScheduleFormatting.list(items.map(\.label)))
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Evening", as: .content, using: BinDayActivityAttributes(key: "preview", day: CollectionDay(containing: .now).adding(days: 1), phase: .eveningBefore)) {
    BinDayLiveActivity()
} contentStates: {
    BinDayActivityAttributes.ContentState(items: [
        BinDayItem(label: "Food Waste", type: .food),
        BinDayItem(label: "Mixed Recycling (Cans, Plastics & Glass)", type: .recycling),
    ])
}
