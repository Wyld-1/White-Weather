//
//  LocationSearchView.swift
//  NOAA Weather
//
//  Add location sheet — MapKit completions for cities/zips, instant ski resort matching.

import SwiftUI
import MapKit
import CoreLocation

// MARK: - Search Completer Wrapper

@Observable
final class LocationCompleter: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        // Restrict to addresses only — .pointOfInterest surfaces businesses,
        // restaurants, shops, etc. which are useless for a weather app.
        completer.resultTypes = [.address]
    }

    func search(_ query: String) {
        if query.isEmpty { results = []; return }
        completer.queryFragment = query
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // Drop street-level results ("123 Main St") — keep only city/region/zip entries.
        // A result is street-level when its title starts with a digit (house number)
        // or its subtitle contains a comma after the first token ("City, State" is fine;
        // "123 Street, City, State" is not).
        results = completer.results.filter { completion in
            let title = completion.title
            // Reject if the title starts with a digit (street address number)
            if let first = title.first, first.isNumber { return false }
            return true
        }
    }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}

// MARK: - Search View

struct LocationSearchView: View {
    @Environment(LocationStore.self) private var store
    var onAdded: (() -> Void)? = nil

    @State private var query = ""
    @State private var completer = LocationCompleter()
    @State private var isResolving = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search Bar
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("City, town, or ski resort...", text: $query)
                        .focused($fieldFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                }
                .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16).padding(.vertical, 12)

                if isResolving {
                    ProgressView().padding(.top, 32); Spacer()
                } else if query.isEmpty {
                    Spacer()
                    Text("Search for a city, town,\nor ski resort").font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                } else {
                    List {
                        let skiResults = searchSkiResorts(query)
                        if !skiResults.isEmpty {
                            Section("Ski Resorts") {
                                ForEach(skiResults, id: \.name) { resort in
                                    SkiResultRow(resort: resort) { addSkiResort(resort) }
                                }
                            }
                        }
                        if !completer.results.isEmpty {
                            Section("Cities & Towns") {
                                ForEach(completer.results, id: \.self) { completion in
                                    MapResultRow(completion: completion) {
                                        Task { await resolveAndAdd(completion) }
                                    }
                                }
                            }
                        }
                    }.listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Add Location").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
        }
        .onChange(of: query) { _, new in completer.search(new) }
        .onAppear { fieldFocused = true }
    }

    private func addSkiResort(_ resort: SkiResort) {
        let newLoc = SavedLocation(
            id: UUID(),
            name: resort.name,
            latitude: resort.coordinate.latitude,
            longitude: resort.coordinate.longitude,
            isSkiResort: true
        )
        store.add(newLoc)
        dismiss()
        onAdded?()
    }

    private func resolveAndAdd(_ completion: MKLocalSearchCompletion) async {
        isResolving = true
        let req = MKLocalSearch.Request(completion: completion)
        
        if let resp = try? await MKLocalSearch(request: req).start(),
           let item = resp.mapItems.first,
           item.placemark.isoCountryCode == "US" {
            let city = item.placemark.locality ?? ""
            let state = item.placemark.administrativeArea ?? ""
            let name = (city.isEmpty) ? (item.name ?? completion.title) : "\(city), \(state)"
            
            store.add(SavedLocation(
                id: UUID(),
                name: name,
                latitude: item.placemark.coordinate.latitude,
                longitude: item.placemark.coordinate.longitude,
                isSkiResort: false
            ))
        }
        isResolving = false; dismiss(); onAdded?()
    }
}

// MARK: - Row Views

struct SkiResultRow: View {
    let resort: SkiResort
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "snowflake")
                    .foregroundStyle(.cyan)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(resort.name)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                    Text("\(resort.state) Ski Resort")
                        .font(.system(size: 13))
                        .foregroundStyle(.gray)
                }
            }
        }
    }
}

struct MapResultRow: View {
    let completion: MKLocalSearchCompletion
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(.white)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(completion.title)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                    if !completion.subtitle.isEmpty {
                        Text(completion.subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.gray)
                    }
                }
            }
        }
    }
}

