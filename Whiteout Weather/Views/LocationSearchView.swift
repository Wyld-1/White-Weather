//
//  LocationSearchView.swift
//  Whiteout Weather
//
//  Immersive search overlay — slides up from the bottom with the keyboard,
//  results fill the full background, previews show a live weather card.

import SwiftUI
import MapKit
internal import CoreLocation

// MARK: - Search Completer

@Observable
final class LocationCompleter: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address]
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
            span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 70)
        )
    }

    func search(_ query: String) {
        if query.isEmpty { results = []; return }
        completer.queryFragment = query
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results.filter { completion in
            // Reject street-level results (start with a house number)
            if let first = completion.title.first, first.isNumber { return false }
            return isUSCompletion(completion)
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
    
    private let usStateAbbreviations: Set<String> = [
        "AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA","HI","ID","IL","IN",
        "IA","KS","KY","LA","ME","MD","MA","MI","MN","MS","MO","MT","NE","NV",
        "NH","NJ","NM","NY","NC","ND","OH","OK","OR","PA","RI","SC","SD","TN",
        "TX","UT","VT","VA","WA","WV","WI","WY","DC","PR","GU","VI","AS","MP"
    ]

    private func isUSCompletion(_ completion: MKLocalSearchCompletion) -> Bool {
        let sub = completion.subtitle.trimmingCharacters(in: .whitespaces)
        guard !sub.isEmpty else { return true } // no subtitle, allow through
        // Split on comma — last token should be a US state abbreviation or "United States"
        let parts = sub.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let last = parts.last ?? ""
        return usStateAbbreviations.contains(last) || last == "United States"
    }
}

// MARK: - Resolved Location (for preview)

struct ResolvedLocation {
    let savedLocation: SavedLocation
    let isSkiResort: Bool
}

// MARK: - Weather Search Overlay

struct WeatherSearchOverlay: View {
    @Environment(LocationStore.self) private var store
    let isActive: Bool
    let onDismiss: () -> Void
    let onAdded: (String) -> Void

    @State private var query = ""
    @State private var completer = LocationCompleter()
    @State private var preview: ResolvedLocation? = nil
    @State private var isResolving = false
    @FocusState private var fieldFocused: Bool

    private var hasResults: Bool {
        !query.isEmpty && (!completer.results.isEmpty || !searchSkiResorts(query).isEmpty)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Dark background covers everything including behind keyboard when results showing
            if hasResults && preview == nil {
                Color(red: 0.08, green: 0.08, blue: 0.10)
                    .ignoresSafeArea()
            }

            // Full-screen tap to dismiss when empty
            if !hasResults && preview == nil {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { close() }
            }

            // Results list
            if hasResults && preview == nil {
                resultsView
                    .transition(.opacity)
            }

            // Preview card
            if let preview {
                previewCard(for: preview)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Search bar
            if preview == nil {
                searchBarContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: hasResults)
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: preview != nil)
        .onChange(of: query) { _, new in completer.search(new) }
        .onChange(of: isActive) { _, active in
            if active { fieldFocused = true }
            else { fieldFocused = false }
        }
    }

    // MARK: - Search Bar

    private var searchBarContent: some View {
        HStack(spacing: 2) {
            searchFieldCapsule
            xButton
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var searchFieldCapsule: some View {
        let inner = HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white)
                .font(.system(size: 17))

            TextField("City, town, or ski resort...", text: $query)
                .focused($fieldFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .foregroundStyle(.white)
                .tint(.white)
                .font(.system(size: 17))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)

        if #available(iOS 26.0, *) {
            inner.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            inner
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
        }
    }

    @ViewBuilder
    private var xButton: some View {
        if #available(iOS 26.0, *) {
            Button {
                if query.isEmpty { close() } else { query = ""; fieldFocused = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        } else {
            Button {
                if query.isEmpty { close() } else { query = ""; fieldFocused = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Results

    private var resultsView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                let skiResults = searchSkiResorts(query)

                if !skiResults.isEmpty {
                    resultSectionHeader("Ski Resorts")
                    ForEach(skiResults, id: \.name) { resort in
                        SearchResultRow(
                            icon: "snowflake",
                            iconColor: .cyan,
                            title: resort.name,
                            subtitle: "\(resort.state) · Ski Resort"
                        ) {
                            selectSkiResort(resort)
                        }
                    }
                }

                if !completer.results.isEmpty {
                    resultSectionHeader("Cities & Towns")
                    ForEach(completer.results, id: \.self) { completion in
                        SearchResultRow(
                            icon: "mappin.and.ellipse",
                            iconColor: .white.opacity(0.7),
                            title: completion.title,
                            subtitle: completion.subtitle.isEmpty ? nil : completion.subtitle
                        ) {
                            Task { await selectCompletion(completion) }
                        }
                    }
                }

                // Keyboard clearance
                Color.clear.frame(height: 400)
            }
            .padding(.top, 60)
        }
        .ignoresSafeArea()
        .background(Color.clear)
    }

    private func resultSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    // MARK: - Preview Card

    private func previewCard(for resolved: ResolvedLocation) -> some View {
        ZStack(alignment: .top) {
            // Card with rounded corners floating off screen edges
            LocationPageView(
                savedLocation: resolved.savedLocation,
                onBackgroundChange: { _ in }
            )
            .safeAreaInset(edge: .top) {
                // Push weather content below the button row
                Color.clear.frame(height: 50)
            }
            .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .ignoresSafeArea(edges: .bottom)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)

            // Buttons concentric with card corners
            HStack {
                if #available(iOS 26.0, *) {
                    Button {
                        withAnimation { preview = nil }
                        fieldFocused = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)

                    Spacer()

                    Button {
                        saveAndClose(resolved)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                } else {
                    Button {
                        withAnimation { preview = nil }
                        fieldFocused = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        saveAndClose(resolved)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: - Actions

    private func selectSkiResort(_ resort: SkiResort) {
        Haptics.shared.impact(.light)
        let loc = SavedLocation(
            id: UUID(),
            name: resort.name,
            latitude: resort.coordinate.latitude,
            longitude: resort.coordinate.longitude,
            isSkiResort: true
        )
        withAnimation { preview = ResolvedLocation(savedLocation: loc, isSkiResort: true) }
    }

    private func selectCompletion(_ completion: MKLocalSearchCompletion) async {
        isResolving = true
        Haptics.shared.impact(.light)
        let req = MKLocalSearch.Request(completion: completion)
        if let resp = try? await MKLocalSearch(request: req).start(),
           let item = resp.mapItems.first,
           item.placemark.isoCountryCode == "US" {
            let city  = item.placemark.locality ?? ""
            let state = item.placemark.administrativeArea ?? ""
            let name  = city.isEmpty ? (item.name ?? completion.title) : "\(city), \(state)"
            let loc = SavedLocation(
                id: UUID(),
                name: name,
                latitude: item.placemark.coordinate.latitude,
                longitude: item.placemark.coordinate.longitude,
                isSkiResort: false
            )
            withAnimation { preview = ResolvedLocation(savedLocation: loc, isSkiResort: false) }
        }
        isResolving = false
    }

    private func saveAndClose(_ resolved: ResolvedLocation) {
        Haptics.shared.impact(.medium)
        store.add(resolved.savedLocation)
        let id = resolved.savedLocation.id.uuidString
        close()
        onAdded(id)
    }

    private func close() {
        fieldFocused = false
        onDismiss()
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 15))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Divider()
            .background(.white.opacity(0.08))
            .padding(.leading, 56)
    }
}

