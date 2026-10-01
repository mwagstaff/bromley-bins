import BinsCore
import SwiftUI

/// Postcode → address list → saved property.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var postcode = ""
    @State private var isSearching = false
    @State private var error: BinsAPIError?
    @State private var results: AddressesResponse?
    @FocusState private var postcodeFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    postcodeField
                    findButton
                    if let error {
                        Label(error.userMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Error: \(error.userMessage)")
                    }
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationDestination(item: $results) { results in
                AddressPickerView(results: results)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.3.trianglepath")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(Color.binsBrand.gradient, in: .rect(cornerRadius: 24))
                .accessibilityHidden(true)
            Text("Find your collections")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("Enter your Bromley postcode and pick your address to see your bin days.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 32)
    }

    private var postcodeField: some View {
        TextField("Postcode, e.g. BR1 1AA", text: $postcode)
            .textContentType(.postalCode)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($postcodeFocused)
            .onSubmit(search)
            .font(.title3)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.binsCard, in: .rect(cornerRadius: 14))
            .accessibilityLabel("Postcode")
    }

    private var findButton: some View {
        Button(action: search) {
            HStack {
                if isSearching {
                    ProgressView()
                        .tint(.white)
                }
                Text(isSearching ? "Searching…" : "Find my address")
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(isSearching || postcode.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func search() {
        guard !isSearching else { return }
        let query = postcode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        postcodeFocused = false
        isSearching = true
        error = nil
        Task {
            defer { isSearching = false }
            do throws(BinsAPIError) {
                results = try await model.addressLookup.addresses(postcode: query)
            } catch {
                self.error = error
            }
        }
    }
}

struct AddressPickerView: View {
    @Environment(AppModel.self) private var model
    let results: AddressesResponse
    @State private var filter = ""
    @State private var choosing: BinAddress?

    private var filtered: [BinAddress] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return results.addresses }
        return results.addresses.filter { $0.address.localizedStandardContains(query) }
    }

    var body: some View {
        List(filtered) { address in
            Button {
                choose(address)
            } label: {
                HStack {
                    Text(address.address)
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if choosing == address {
                        ProgressView()
                    }
                }
            }
            .disabled(choosing != nil)
        }
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
        .searchable(text: $filter, prompt: "Filter addresses")
        .navigationTitle(results.postcode)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            Text("Choose your address")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 4)
        }
    }

    private func choose(_ address: BinAddress) {
        choosing = address
        Task { await model.choose(address, postcode: results.postcode) }
    }
}
