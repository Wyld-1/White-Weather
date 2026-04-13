//
//  LocationPageView.swift
//  Whiteout Weather
//
//  One page in the swipe carousel. Owns its own WeatherViewModel.

import SwiftUI
import MapKit

struct LocationPageView: View {
    @Environment(LocationStore.self) private var store
    @Environment(LocationManager.self) private var locationManager
    
    @State private var viewModel = WeatherViewModel()
    @State private var selectedDay: DailyForecast?
    @State private var showDeleteConfirm = false
    #if DEBUG
    @State private var showDebugReset = false
    #endif
    
    let savedLocation: SavedLocation?
    let onBackgroundChange: ((Bool) -> Void)?
    // Injected by ContentView so delete can navigate to the correct page.
    var selectedID: Binding<String?>? = nil
    var showCurrentPage: Bool = true
    private var isCurrentLocation: Bool { savedLocation == nil }
    
    private var coordinate: CLLocationCoordinate2D? {
        savedLocation?.coordinate ?? locationManager.coordinate
    }

    var body: some View {
        ZStack {
            // Background gradient — condition + time-of-day resolved live
            GradientBackgroundView(
                condition: viewModel.weatherCondition,
                timeOfDay: viewModel.weatherTimeOfDay
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                CurrentConditionsHeader(
                    locationName:      viewModel.locationName,
                    isCurrentLocation: viewModel.isCurrentLocation,
                    current:           viewModel.current,
                    high:              viewModel.daily.first?.high,
                    low:               viewModel.daily.first?.low,
                    isLoading:         viewModel.daily.isEmpty,
                    currentSFSymbol:   viewModel.currentSFSymbol
                )
                .padding(.top, 8)

                Capsule()
                    .fill(.black.opacity(0.3))
                    .frame(width: 300, height: 4)

                if let error = viewModel.errorMessage {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack {
                            Spacer(minLength: 0)
                            ErrorView(message: error) {
                                guard let coord = coordinate else { return }
                                Task {
                                    await viewModel.load(
                                        coordinate:   coord,
                                        locationID:   savedLocation?.id.uuidString,
                                        skipGeocode:  savedLocation != nil,
                                        forceRefresh: true
                                    )
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: UIScreen.main.bounds.height * 0.6)
                    }
                    .refreshable {
                        guard let coord = coordinate else { return }
                        let locationID  = savedLocation?.id.uuidString
                        let skipGeocode = savedLocation != nil
                        await Task.detached(priority: .userInitiated) {
                            await viewModel.load(
                                coordinate:   coord,
                                locationID:   locationID,
                                skipGeocode:  skipGeocode,
                                forceRefresh: true
                            )
                        }.value
                    }

                } else if viewModel.daily.isEmpty {
                    Spacer()
                    Image("WhiteoutSearching")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .shadow(radius: 6)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 18)

                } else {
                    // Scroll content extends under the home indicator; the gradient
                    // overlay fades it out so nothing collides with system chrome.
                    ZStack(alignment: .bottom) {
                        ScrollView(.vertical, showsIndicators: false) {
                            Spacer(minLength: 8)
                            WeatherContentView(viewModel: viewModel, selectedDay: $selectedDay)

                            if !isCurrentLocation {
                                deleteButton
                            }
                            #if DEBUG
                            debugResetButton
                            #endif

                            Text("Weather provided by NOAA and Open-Meteo")
                                .font(.caption2)
                                .bold()
                                .foregroundStyle(.white.opacity(0.8))
                                .shadow(color: .black, radius: 1)
                                .padding(.bottom, 95)
                        }
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear,         location: 0.00),
                                    .init(color: .black,         location: 0.02),
                                    .init(color: .black,         location: 1.00),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .ignoresSafeArea(edges: .bottom)
                        .refreshable {
                            guard let coord = coordinate else { return }
                            let locationID  = savedLocation?.id.uuidString
                            let skipGeocode = savedLocation != nil
                            await Task.detached(priority: .userInitiated) {
                                await viewModel.load(
                                    coordinate:  coord,
                                    locationID:  locationID,
                                    skipGeocode: skipGeocode,
                                    forceRefresh: true
                                )
                            }.value
                        }

                        // Bottom fade — covers the home indicator area with a soft
                        // gradient that matches the weather background color.
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.45)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 80)
                        .allowsHitTesting(false)
                        .ignoresSafeArea(edges: .bottom)
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .sheet(item: $selectedDay) { day in
            DayDetailSheet(
                days:       Array(viewModel.daily.prefix(7)),
                startIndex: viewModel.daily.prefix(7).firstIndex(where: { $0.id == day.id }) ?? 0,
                globalLow:  viewModel.globalLow,
                globalHigh: viewModel.globalHigh
            )
        }
        .alert("Delete Location?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let loc = savedLocation {
                    // Navigate left first, then delete. Setting selectedID before
                    // the deletion prevents TabView from snapping back to "current"
                    // while trying to render the now-gone page ID.
                    let dest = store.delete(
                        loc,
                        currentSelectedID: selectedID?.wrappedValue,
                        hasCurrentPage: showCurrentPage
                    )
                    selectedID?.wrappedValue = dest
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Remove \(savedLocation?.name ?? "this location")?")
        }
        .task(id: coordinate?.latitude) {
            triggerFetch()
        }

        // Notify ContentView when background brightness changes so PageDotsView
        // can adapt its colors. Fire on both condition and time-of-day changes.
        .onChange(of: viewModel.isLightBackground) { _, newValue in
            onBackgroundChange?(newValue)
        }
        .onAppear {
            onBackgroundChange?(viewModel.isLightBackground)
        }
        // Refresh on the 15-min timer and on settings changes (units, time format).
        // skipGeocode only for saved locations whose name is already known.
        .onReceive(NotificationCenter.default.publisher(for: .refreshAllLocations)) { _ in
            guard let coord = coordinate else { return }
            Task {
                await viewModel.load(
                    coordinate: coord,
                    locationID: savedLocation?.id.uuidString,
                    skipGeocode: savedLocation != nil,
                    forceRefresh: true
                )
            }
        }
        #if DEBUG
        let _ = printTelemetry()
        #endif
    }
    
    private func printTelemetry() {
        let cal = Calendar.current
        let now = Date()
        
        // Safety check: Find the entries
        let nowEntry = viewModel.hourlyTable.first(where: {
            cal.isDateInToday($0.date) &&
            cal.component(.hour, from: $0.date) == cal.component(.hour, from: now)
        })
        let nowHour = viewModel.hourly.first(where: {
            cal.isDateInToday($0.time) &&
            cal.component(.hour, from: $0.time) == cal.component(.hour, from: now)
        })

        let e = nowEntry
        print("--- Phase 2 (Table) Telemetry ---")
        print("Sky cover: \(e?.skyCoverPct.description ?? "—")%")
        print("Precip potential: \(e?.precipPotentialPct.description ?? "—")%")
        print("Rain: \(e?.rainPct.description ?? "—")%")
        print("Snow: \(e?.snowPct.description ?? "—")%")
        print("Thunder: \(e?.thunderPct.description ?? "—")%")
        print("Fz rain: \(e?.freezingRainPct.description ?? "—")%")
        print("Sleet: \(e?.sleetPct.description ?? "nil")%")
        print("Humidity: \(e?.humidity.map { "\($0)%" } ?? "—")")
        print("Wind: \(e?.windSpeedMph.map { "\($0) mph" } ?? "—")")
        print("Gusts: \(e?.windGustMph.map { "\($0) mph" } ?? "—")")
        print("Wind dir: \(e?.windDirection ?? "—")")
        print("shortForecast: \(e?.shortForecast ?? "—")")
        print("sfSymbol (tbl): \(e?.sfSymbol(isDay: nowHour?.isDay ?? true) ?? "—")")
        
        let h = nowHour
        print("--- Phase 1 (Hourly) Telemetry ---")
        print("resolvedSymbol: \(h?.resolvedSymbol ?? "—")")
        print("shortForecast: \(h?.shortForecast ?? "—")")
        print("isDay: \(h == nil ? "—" : (h!.isDay ? "true" : "false"))")

        print("--- ViewModel State ---")
        print("currentSFSymbol: \(viewModel.currentSFSymbol)")
        print("weatherCondition: \(viewModel.weatherCondition.assetSuffix)")
        print("timeOfDay: \(viewModel.weatherTimeOfDay.rawValue)")
        print("Phase 2 loaded? \(viewModel.hourlyTable.isEmpty ? "NO" : "YES (\(viewModel.hourlyTable.count) hrs)")")
    }

    private func triggerFetch() {
        guard let coord = coordinate else { return }

        let locationID = savedLocation?.id.uuidString

        viewModel.isCurrentLocation = savedLocation == nil
        if let savedLoc = savedLocation {
            viewModel.setLocationName(savedLoc.name)
            viewModel.setSkiResort(savedLoc.isSkiResort)
        }

        // Warm-start: only populate from cache when there's no live data yet.
        // Calling loadFromCache when the viewModel already has current data
        // (e.g. on swipe-back within the cache window) would overwrite live
        // state with stale widget cache, producing the wrong weather display.
        let cacheID = locationID ?? "current"
        if viewModel.current == nil {
            viewModel.loadFromCache(id: cacheID)
        }

        Task {
            await viewModel.load(
                coordinate: coord,
                locationID: locationID,
                skipGeocode: savedLocation != nil
            )
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "trash.fill")
                    .foregroundStyle(.red)
                Text("Delete Location")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.red)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
    }

    #if DEBUG
    private var debugResetButton: some View {
        Button {
            showDebugReset = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(.orange)
                Text("Reset App Data")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.orange)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 15)
        .confirmationDialog("Reset App Data", isPresented: $showDebugReset, titleVisibility: .visible) {
            Button("Welcome screen only", role: .destructive) {
                NotificationCenter.default.post(
                    name: .debugResetApp,
                    object: DebugResetScope.welcomeOnly
                )
            }
            Button("All (incl. saved locations)", role: .destructive) {
                NotificationCenter.default.post(
                    name: .debugResetApp,
                    object: DebugResetScope.all
                )
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone.")
        }
    }
    #endif
}

// MARK: - Supporting Views

struct ErrorView: View {
    let message: String
    let retry: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image("WhiteoutSleeping")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 250)
                .padding(.vertical, -50)
            Text(message)
                .font(.system(size: 15))
                .bold()
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") {
                Haptics.shared.impact(.rigid)
                retry()
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .shadow(radius: 3)
        }
    }
}
