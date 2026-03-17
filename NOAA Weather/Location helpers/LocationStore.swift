//
//  LocationStore.swift
//  NOAA Weather
//
//  Single source of truth for the location list.
//  Index 0 is always the current GPS location (never saved, never removable).
//  Indices 1+ are user-saved locations, persisted to UserDefaults.

import Foundation
import CoreLocation

struct SavedLocation: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String          // Display name e.g. "Seattle, WA" or "Crystal Mountain, WA"
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// LocationStore.swift

@Observable
@MainActor
final class LocationStore {
    private(set) var saved: [SavedLocation] = []
    var currentLocationName: String = "My Location"
    private let key = "savedLocations"

    init() { load() }

    // MARK: - Public API

    func add(_ location: SavedLocation) {
        guard !saved.contains(where: {
            abs($0.latitude  - location.latitude)  < 0.05 &&
            abs($0.longitude - location.longitude) < 0.05
        }) else { return }
        saved.append(location)
        persist()
    }

    func delete(_ location: SavedLocation) {
        saved.removeAll { $0.id == location.id }
        persist()
    }

    // MARK: - Persistence
    private func persist() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedLocation].self, from: data)
        else { return }
        saved = decoded
    }
}
