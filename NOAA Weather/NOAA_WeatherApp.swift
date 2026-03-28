/* NOAA_WeatherApp.swift
 * White Weather
 *
 * App entry point. Sets up the audio session, injects environment objects,
 * handles deep links from widget taps, and fires a 15-minute background refresh.
 */

import SwiftUI
import Combine
import AVFoundation

extension Notification.Name {
    static let refreshAllLocations = Notification.Name("refreshAllLocations")
}

@main
struct NOAA_WeatherApp: App {
    @State private var locationStore    = LocationStore()
    @State private var locationManager  = LocationManager()
    @State private var selectedLocationID: String? = "current"
    @State private var showWelcome      = !UserDefaults.standard.bool(forKey: "hasLaunched")

    init() {
        // .ambient mixes with other audio — the background videos are muted
        // so there's no reason to claim the audio session exclusively.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView(selectedID: $selectedLocationID)
                    .environment(locationStore)
                    .environment(locationManager)
                    .onOpenURL { handleDeepLink($0) }
                    .onAppear { locationManager.requestLocation() }
                    .onReceive(Timer.publish(every: 900, on: .main, in: .common).autoconnect()) { _ in
                        locationManager.requestLocation()
                        NotificationCenter.default.post(name: .refreshAllLocations, object: nil)
                    }

                if showWelcome {
                    WelcomeView {
                        UserDefaults.standard.set(true, forKey: "hasLaunched")
                        withAnimation(.easeInOut(duration: 0.5)) { showWelcome = false }
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
        }
    }

    /* Handles widget tap deep links: wildcat-weather://location/{id}
     * Navigates to the tapped location; LocationPageView warm-starts from cache.
     */
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "wildcat-weather",
              url.host  == "location",
              let id    = url.pathComponents.last else { return }
        selectedLocationID = id
    }
}
