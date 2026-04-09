/* WhiteoutWeatherApp.swift
 * Whiteoutout Weather
 *
 * App entry point. Sets up the audio session, injects environment objects,
 * handles deep links from widget taps, and fires the 15-minute background refresh.
 *
 * Settings changes are observed via Combine on AppSettings.@Published properties —
 * NOT via UserDefaults.didChangeNotification, which fires for every UserDefaults
 * write in the entire app and causes a runaway re-fetch loop.
 */

import SwiftUI
import Combine
import AVFoundation
import WidgetKit
internal import CoreLocation

extension Notification.Name {
    static let refreshAllLocations = Notification.Name("refreshAllLocations")
    #if DEBUG
    static let debugResetApp = Notification.Name("debugResetApp")
    #endif
}

@main
struct WhiteoutWeatherApp: App {
    @State private var locationStore      = LocationStore()
    @State private var locationManager    = LocationManager()
    @State private var selectedLocationID: String? = "current"
    @State private var showWelcome        = !UserDefaults.standard.bool(forKey: "hasLaunched")
    @StateObject private var settings     = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    #if DEBUG
    @State private var debugResetScope: DebugResetScope? = nil
    #endif

    // Combine subscription — observes only unitSystem and timeFormat, debounced so
    // the UserDefaults write in their didSet doesn't immediately re-trigger this.
    @State private var settingsCancellable: AnyCancellable? = nil

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        // Pre-warm haptic generators at launch so the first button tap is instant.
        // Generators go cold within seconds of inactivity; calling prepareAll() here
        // covers the WelcomeView case where the user taps "Get Started" right away.
        Haptics.shared.prepareAll()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView(selectedID: $selectedLocationID)
                    .environment(locationStore)
                    .environment(locationManager)
                    .environmentObject(settings)
                    .onOpenURL { handleDeepLink($0) }
                    .onAppear {
                        locationManager.requestLocation()
                        startObservingSettings()
                    }
                    .onReceive(Timer.publish(every: 900, on: .main, in: .common).autoconnect()) { _ in
                        locationManager.requestLocation()
                        NotificationCenter.default.post(name: .refreshAllLocations, object: nil)
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        guard newPhase == .active else { return }
                        Haptics.shared.prepareAll()
                        settings.syncFromStandard()
                        // Tell WidgetKit to re-run timeline() for all widgets immediately.
                        // This is the "user opened their phone" refresh hook — without it
                        // WidgetKit only refreshes on its own schedule, not on app foreground.
                        WidgetCenter.shared.reloadAllTimelines()
                        // If location access was revoked while the app was suspended
                        // and the user was on the current-location page, redirect them.
                        if locationManager.authorizationStatus == .denied ||
                           locationManager.authorizationStatus == .restricted {
                            if selectedLocationID == "current" {
                                selectedLocationID = locationStore.saved.first.map { $0.id.uuidString } ?? "add"
                            }
                        }
                        #if DEBUG
                        if settings.debugResetWasTriggered {
                            debugResetScope = .welcomeOnly
                        }
                        #endif
                    }
                    #if DEBUG
                    .onReceive(NotificationCenter.default.publisher(for: .debugResetApp)) { note in
                        if let scope = note.object as? DebugResetScope {
                            performReset(scope: scope)
                        }
                    }
                    #endif

                if showWelcome {
                    WelcomeView {
                        UserDefaults.standard.set(true, forKey: "hasLaunched")
                        withAnimation(.easeInOut(duration: 0.5)) { showWelcome = false }
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            /*
            #if DEBUG
            .confirmationDialog(
                "Reset App Data",
                isPresented: Binding(
                    get: { debugResetScope != nil },
                    set: { if !$0 { debugResetScope = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Welcome screen only", role: .destructive) { performReset(scope: .welcomeOnly) }
                Button("All (incl. saved locations)", role: .destructive) { performReset(scope: .all) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This cannot be undone.")
            }
            #endif
             */
        }
    }

    /* Subscribes to AppSettings @Published properties via Combine.
     * Debounced by 0.1s so the UserDefaults write inside didSet doesn't
     * immediately re-fire the publisher and cause a tight loop.
     */
    private func startObservingSettings() {
        settingsCancellable = Publishers.CombineLatest(
            settings.$unitSystem,
            settings.$timeFormat
        )
        .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
        .dropFirst()   // skip the initial emission at subscription time
        .sink { _, _ in
            NotificationCenter.default.post(name: .refreshAllLocations, object: nil)
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

    #if DEBUG
    private func performReset(scope: DebugResetScope) {
        UserDefaults.standard.removeObject(forKey: "hasLaunched")
        if scope == .all {
            UserDefaults.standard.removeObject(forKey: "savedLocations")
            locationStore = LocationStore()
        }
        showWelcome = true
    }
    #endif
}

#if DEBUG
enum DebugResetScope { case welcomeOnly, all }
#endif
