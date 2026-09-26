import BinsCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var confirmingChange = false
    @State private var notificationsDenied = false

    var body: some View {
        NavigationStack {
            Form {
                addressSection
                binsSection
                remindersSection
                aboutSection
            }
            .navigationTitle("Settings")
            .task { notificationsDenied = await model.reminderAuthorizationDenied() }
            .confirmationDialog(
                "Change your address?",
                isPresented: $confirmingChange,
                titleVisibility: .visible
            ) {
                Button("Change address", role: .destructive) {
                    Task { await model.forgetAddress() }
                }
            } message: {
                Text("Your saved address and schedule will be removed from this device.")
            }
        }
    }

    @ViewBuilder
    private var addressSection: some View {
        if let property = model.state.property {
            Section("Your address") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(property.displayAddress)
                    if !property.displayAddress.localizedStandardContains(property.postcode) {
                        Text(property.postcode)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Button("Change address") { confirmingChange = true }
            }
        }
    }

    @ViewBuilder
    private var binsSection: some View {
        let types = model.state.knownTypes
        if !types.isEmpty {
            Section {
                ForEach(types) { collection in
                    Toggle(isOn: Binding(
                        get: { !model.state.hiddenTypes.contains(collection.type) },
                        set: { visible in Task { await model.setType(collection.type, visible: visible) } }
                    )) {
                        HStack(spacing: 12) {
                            BinBadge(collection.normalizedType, size: 28)
                            Text(collection.label)
                        }
                    }
                }
            } header: {
                Text("Bins I'm interested in")
            } footer: {
                Text("Hidden bins are left out of the schedule, reminders and widgets.")
            }
        }
    }

    private var remindersSection: some View {
        Section {
            Toggle("Remind me the evening before", isOn: Binding(
                get: { model.state.reminders.isEnabled },
                set: { enabled in
                    Task {
                        let allowed = await model.setRemindersEnabled(enabled)
                        notificationsDenied = !allowed
                    }
                }
            ))
            if model.state.reminders.isEnabled {
                DatePicker("Reminder time", selection: reminderTime, displayedComponents: .hourAndMinute)
                    .environment(\.timeZone, CollectionDay.calendar.timeZone)
            }
        } header: {
            Text("Reminders")
        } footer: {
            if notificationsDenied {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notifications are turned off for Bromley Bins.")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .font(.footnote.weight(.semibold))
                }
            } else {
                Text("You'll get one notification the evening before each collection day.")
            }
        }
    }

    private var reminderTime: Binding<Date> {
        Binding(
            get: {
                CollectionDay(containing: .now).date(hour: model.state.reminders.hour, minute: model.state.reminders.minute)
            },
            set: { date in
                let parts = CollectionDay.calendar.dateComponents([.hour, .minute], from: date)
                Task { await model.setReminderTime(hour: parts.hour ?? 19, minute: parts.minute ?? 0) }
            }
        )
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.displayVersion)
            Link("Bromley Council bin collections", destination: URL(string: "https://recyclingservices.bromley.gov.uk/waste")!)
            Link("Privacy policy", destination: URL(string: "https://skynolimit.dev/privacy_policy")!)
            Link("Terms of use", destination: URL(string: "https://skynolimit.dev/terms_of_use")!)
        } header: {
            Text("About")
        } footer: {
            Text("Collection dates come from Bromley Council. Bromley Bins is an independent app and is not affiliated with Bromley Council. Your address is only stored on this device.")
        }
    }
}

private extension Bundle {
    var displayVersion: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
