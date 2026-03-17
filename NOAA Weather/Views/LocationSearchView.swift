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
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func search(_ query: String) {
        if query.isEmpty { results = []; return }
        completer.queryFragment = query
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}

// MARK: - Search View

struct LocationSearchView: View {
    @Environment(LocationStore.self) private var store
    /// Called after a location is added so the parent can navigate to it
    var onAdded: (() -> Void)? = nil

    @State private var query = ""
    @State private var completer = LocationCompleter()
    @State private var isResolving = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    // Ski results updated instantly from query
    private var skiResults: [SkiResort] {
        query.isEmpty ? [] : searchSkiResorts(query)
    }

    // MapKit completions, filtered to avoid ski-resort duplicates
    private var mapResults: [MKLocalSearchCompletion] {
        completer.results
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("City, zip code, or ski resort…", text: $query)
                        .focused($fieldFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if isResolving {
                    ProgressView().padding(.top, 32)
                    Spacer()
                } else if query.isEmpty {
                    Spacer()
                    Text("Search for a city, zip code,\nor ski resort")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                } else if skiResults.isEmpty && mapResults.isEmpty {
                    Spacer()
                    Text("No results")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List {
                        // Ski resorts first
                        if !skiResults.isEmpty {
                            Section("Ski Resorts") {
                                ForEach(skiResults, id: \.name) { resort in
                                    SkiResultRow(resort: resort) {
                                        addSkiResort(resort)
                                    }
                                }
                            }
                        }
                        // MapKit city/zip results
                        if !mapResults.isEmpty {
                            Section(skiResults.isEmpty ? "" : "Cities & Places") {
                                ForEach(mapResults, id: \.self) { completion in
                                    MapResultRow(completion: completion) {
                                        Task { await resolveAndAdd(completion) }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Add Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onChange(of: query) { _, new in completer.search(new) }
        .onAppear { fieldFocused = true }
    }

    // MARK: - Actions

    private func addSkiResort(_ resort: SkiResort) {
        // Use the resort name directly — never geocode
        store.add(SavedLocation(
            id: UUID(),
            name: resort.name,
            latitude: resort.coordinate.latitude,
            longitude: resort.coordinate.longitude
        ))
        dismiss()
        onAdded?()
    }

    private func resolveAndAdd(_ completion: MKLocalSearchCompletion) async {
        isResolving = true
        let req = MKLocalSearch.Request(completion: completion)
        if let resp = try? await MKLocalSearch(request: req).start(),
           let item = resp.mapItems.first {
            let coord = item.placemark.coordinate
            // Build a clean display name
            let parts = [item.placemark.locality,
                         item.placemark.administrativeArea]
                .compactMap { $0 }
            let name = parts.isEmpty
                ? (item.name ?? completion.title)
                : parts.joined(separator: ", ")
            store.add(SavedLocation(
                id: UUID(),
                name: name,
                latitude: coord.latitude,
                longitude: coord.longitude
            ))
        }
        isResolving = false
        dismiss()
        onAdded?()
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
                    Text(resort.name).font(.system(size: 16)).foregroundStyle(.primary)
                    Text("\(resort.state) Ski Resort").font(.system(size: 13)).foregroundStyle(.secondary)
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
                Image(systemName: "mappin").foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(completion.title).font(.system(size: 16)).foregroundStyle(.primary)
                    if !completion.subtitle.isEmpty {
                        Text(completion.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
