import BinsCore
import SwiftUI

struct CollectionsView: View {
    @Environment(AppModel.self) private var model

    private var groups: [CollectionGroup] { model.state.upcomingGroups(from: model.today) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let next = groups.first {
                        NextCollectionCard(group: next, today: model.today)
                        let later = Array(groups.dropFirst().prefix(12))
                        if !later.isEmpty {
                            UpcomingList(groups: later, today: model.today)
                        }
                        StatusFooter()
                    } else {
                        emptyState
                    }
                }
                .padding()
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Bromley Bins")
            .refreshable { await model.refresh() }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isRefreshing {
            ProgressView("Fetching your collections…")
                .frame(maxWidth: .infinity, minHeight: 300)
        } else if let error = model.refreshError, model.state.collections.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load collections", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error.userMessage)
            } actions: {
                Button("Try again") { Task { await model.refresh() } }
                    .buttonStyle(.glassProminent)
            }
        } else if !model.state.collections.isEmpty {
            ContentUnavailableView(
                "No upcoming collections",
                systemImage: "checkmark.circle",
                description: Text("None of the bins you've chosen are due. You can change which bins you follow in Settings.")
            )
        } else {
            ContentUnavailableView(
                "No collections yet",
                systemImage: "calendar",
                description: Text("Bromley Council hasn't published any upcoming collections for this address. Pull down to check again.")
            )
        }
    }
}

private struct NextCollectionCard: View {
    let group: CollectionGroup
    let today: CollectionDay

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ScheduleFormatting.relative(group.day, from: today).uppercased())
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.binsBrand)
                Text(ScheduleFormatting.long(group.day))
                    .font(.title.bold())
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(spacing: 12) {
                ForEach(group.collections) { collection in
                    HStack(spacing: 14) {
                        BinBadge(collection.normalizedType, size: 44)
                        Text(collection.label)
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.binsCard, in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Next collection")
    }
}

private struct UpcomingList: View {
    let groups: [CollectionGroup]
    let today: CollectionDay

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coming up")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    UpcomingRow(group: group, today: today)
                    if group != groups.last {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color.binsCard, in: .rect(cornerRadius: 20))
        }
    }
}

private struct UpcomingRow: View {
    let group: CollectionGroup
    let today: CollectionDay

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ScheduleFormatting.short(group.day))
                    .font(.headline)
                Text(ScheduleFormatting.relative(group.day, from: today))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 96, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.collections) { collection in
                    HStack(spacing: 10) {
                        BinBadge(collection.normalizedType, size: 26)
                        Text(collection.label)
                            .font(.subheadline)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

private struct StatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            if let error = model.refreshError {
                Label("Couldn't refresh. \(error.userMessage)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if model.state.isOutdated(now: .now) {
                Label("Bromley's bin service may be having problems, so this schedule could be out of date.", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if let updated = model.state.lastSuccessfulRefresh {
                Text("Last updated \(updated, format: .relative(presentation: .named))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}
