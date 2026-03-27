// NOAA_WeatherApp.swift
// White Weather

import SwiftUI
import Combine
import AVFoundation

extension Notification.Name {
    static let refreshAllLocations = Notification.Name("refreshAllLocations")
}

@main
struct NOAA_WeatherApp: App {
    @State private var locationStore = LocationStore()
    @State private var locationManager = LocationManager()
    @State private var selectedLocationID: String? = "current"

    init() {
        // .ambient mixes with other audio — videos are muted, we have no reason to own the session.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(selectedID: $selectedLocationID)
                .environment(locationStore)
                .environment(locationManager)
                .onOpenURL { handleDeepLink($0) }
                .onAppear { locationManager.requestLocation() }
                .onReceive(Timer.publish(every: 900, on: .main, in: .common).autoconnect()) { _ in
                    locationManager.requestLocation()
                    NotificationCenter.default.post(name: .refreshAllLocations, object: nil)
                }
        }
    }

    // Deep link: wildcat-weather://location/{id}
    // The widget taps this URL; we navigate to that location and warm-start from cache.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "wildcat-weather",
              url.host == "location",
              let id = url.pathComponents.last else { return }
        selectedLocationID = id
    }
}
