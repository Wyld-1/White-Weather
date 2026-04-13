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
import BackgroundTasks
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
        Haptics.shared.prepareAll()
        // Register the background refresh task. Must happen before the app finishes
        // launching — this is the only valid registration window.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.wildcat.weather.refresh",
            using: nil
        ) { task in
            WhiteoutWeatherApp.handleBackgroundRefresh(task: task as! BGAppRefreshTask)
        }
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
                        WhiteoutWeatherApp.scheduleBackgroundRefresh()
                        // Re-sync location registry on every foreground in case
                        // the App Group was cleared or the widget was freshly installed.
                        locationStore.syncRegistryToWidget()
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

// MARK: - Background App Refresh

// UIColor RGBA helper — mirrors the identical extension in the widget target.
private extension UIColor {
    var rgbaComponents: (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }
}

extension WhiteoutWeatherApp {

    /* Schedules the next BGAppRefreshTask wakeup.
     * Call on every app foreground and at the end of each background execution
     * so the chain never breaks. iOS may delay or deny the request based on
     * battery, network, and usage patterns — that's expected.
     */
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.wildcat.weather.refresh")
        // Ask to be woken in ~30 minutes. iOS uses this as a hint, not a guarantee.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /* Executed by iOS when the system decides to honor our BGAppRefreshTask request.
     * Fetches weather for every saved location + current location, writes each
     * result to the shared App Group, then reloads widget timelines.
     * This is the "push" path: the app does the work and hands the data to the
     * widget, bypassing the widget's own timeline budget entirely.
     */
    static func handleBackgroundRefresh(task: BGAppRefreshTask) {
        // Immediately reschedule so the chain continues even if this run fails.
        scheduleBackgroundRefresh()

        // BGAppRefreshTask gives us a short execution window. If we overrun it,
        // the task is killed. Set the expiry handler to mark the task failed cleanly.
        let fetchTask = Task {
            await performBackgroundFetch()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            fetchTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    /* Fetches weather for all locations and pushes results to the App Group.
     * Runs concurrently across all locations so the total time stays short.
     * Reloads widget timelines at the end so the widget picks up fresh data
     * without spending any of its own refresh budget.
     */
    private static func performBackgroundFetch() async {
        let defaults   = UserDefaults(suiteName: WidgetWeatherData.groupID)
        let coordDict  = defaults?.dictionary(forKey: "saved_location_coords") as? [String: String] ?? [:]
        let namesDict  = defaults?.dictionary(forKey: "saved_location_names")  as? [String: String] ?? [:]
        let orderedIDs = defaults?.stringArray(forKey: "ordered_location_ids") ?? []

        // Build a list of (id, lat, lon) tuples to fetch.
        var locations: [(id: String, lat: Double, lon: Double, name: String)] = []
        for (id, coordStr) in coordDict {
            let parts = coordStr.split(separator: ",")
            guard parts.count == 2,
                  let lat = Double(parts[0]),
                  let lon = Double(parts[1]) else { continue }
            let name: String
            if id == "current" {
                name = defaults?.string(forKey: "current_location_name") ?? ""
            } else {
                name = namesDict[id] ?? ""
            }
            locations.append((id: id, lat: lat, lon: lon, name: name))
        }

        guard !locations.isEmpty else { return }

        // Fetch all locations concurrently.
        await withTaskGroup(of: Void.self) { group in
            for loc in locations {
                group.addTask {
                    await fetchAndCache(id: loc.id, lat: loc.lat, lon: loc.lon, name: loc.name)
                }
            }
        }

        // Push the fresh data to the widget.
        WidgetCenter.shared.reloadAllTimelines()
    }

    /* Fetches weather for a single location and writes it to the App Group cache.
     * Mirrors the logic in the widget's fetchEntry() so data is always consistent.
     */
    private static func fetchAndCache(id: String, lat: Double, lon: Double, name: String) async {
        guard let (cur, days, allHourly, _, _, _, alerts, _) =
                try? await WeatherRepository.shared.fetchAll(lat: lat, lon: lon),
              let firstDay = days.first else { return }

        let cal      = Calendar.current
        let nowHour  = allHourly.first(where: {
            cal.isDateInToday($0.time) &&
            cal.component(.hour, from: $0.time) == cal.component(.hour, from: Date())
        })
        let symbol: String = {
            if let h = nowHour, let sym = noaaSFSymbol(condition: h.shortForecast, isDay: h.isDay) {
                return sym
            }
            if let sym = noaaSFSymbol(condition: cur.description, isDay: cur.isDay) {
                return sym
            }
            return wmoSFSymbol(code: cur.weatherCode, isDay: cur.isDay)
        }()

        let topAlert  = alerts.first
        let alertCfg  = topAlert.map { NWSAlert.displayConfig(for: $0.event) }
        let alertRGBA = alertCfg.map { UIColor($0.color).rgbaComponents }

        let fresh = WidgetWeatherData(
            id:                 id,
            lat:                lat,
            lon:                lon,
            temperature:        cur.temperature,
            high:               firstDay.high,
            low:                firstDay.low,
            condition:          cur.description,
            sfSymbol:           symbol,
            precipProbability:  firstDay.precipProbability,
            locationName:       name.isEmpty ? id : name,
            windGusts:          cur.windGusts,
            isDay:              cur.isDay,
            accumDisplayString: firstDay.accumulation.hasAccumulation
                                    ? firstDay.accumulation.displayString() : nil,
            dayProse:           firstDay.dayProse,
            nightProse:         firstDay.nightProse,
            fetchedAt:          Date(),
            alertSymbol:        alertCfg?.symbol,
            alertColorRed:      alertRGBA?.r,
            alertColorGreen:    alertRGBA?.g,
            alertColorBlue:     alertRGBA?.b
        )
        fresh.save()
    }
}
