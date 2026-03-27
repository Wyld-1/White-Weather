//
//  LocationStore.swift
//  NOAA Weather
//
//  Single source of truth for the location list.
//  Index 0 is always the current GPS location (never saved, never removable).
//  Indices 1+ are user-saved locations, persisted to UserDefaults.

import Foundation
import CoreLocation
import WidgetKit

struct SavedLocation: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String          // Display name e.g. "Seattle, WA" or "Crystal Mountain, WA"
    var latitude: Double
    var longitude: Double
    var isSkiResort: Bool = false

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@Observable
@MainActor
final class LocationStore {
    private(set) var saved: [SavedLocation] = []
    var currentLocationName: String = "My Location"
    private let key = "savedLocations"
    private let groupID = "group.weather.widgetinfo" // The shared App Group

    init() { load() }

    func add(_ location: SavedLocation) {
        guard !saved.contains(where: {
            abs($0.latitude  - location.latitude)  < 0.05 &&
            abs($0.longitude - location.longitude) < 0.05
        }) else { return }
        saved.append(location)
        persist()
        syncToWidget() // Sync every time the list changes
    }

    func delete(_ location: SavedLocation) {
        saved.removeAll { $0.id == location.id }
        persist()
        syncToWidget() // Sync every time the list changes
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func syncToWidget() {
        syncLocationRegistry()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedLocation].self, from: data)
        else { return }
        saved = decoded
        // Sync location metadata (names/coords) but don't reload timelines on launch —
        // the weather data itself isn't loaded yet, so widget data is unchanged.
        syncLocationRegistry()
    }

    // Writes only the location list metadata (names, coords, order) to the shared container.
    // Does not reload widget timelines — call syncToWidget() for that after data changes.
    private func syncLocationRegistry() {
        guard let defaults = UserDefaults(suiteName: groupID) else { return }
        var names: [String: String] = [:]
        var coords: [String: String] = [:]
        for loc in saved {
            names[loc.id.uuidString]  = loc.name
            coords[loc.id.uuidString] = "\(loc.latitude),\(loc.longitude)"
        }
        defaults.set(names,               forKey: "saved_location_names")
        defaults.set(coords,              forKey: "saved_location_coords")
        defaults.set(saved.map { $0.id.uuidString }, forKey: "ordered_location_ids")
    }
}
