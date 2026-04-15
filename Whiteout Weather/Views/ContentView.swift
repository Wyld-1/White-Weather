//
//  ContentView.swift
//  Whiteout Weather

import SwiftUI
import Combine
import UIKit
internal import _LocationEssentials
internal import CoreLocation

// MARK: - Root

struct ContentView: View {
    @Environment(LocationStore.self) private var store
    @Environment(LocationManager.self) private var locationManager
    @Binding var selectedID: String?

    // Whether the GPS/current-location page is shown.
    // Hidden when the user has explicitly denied or restricted location access.
    // Reactive: LocationManager publishes authorizationStatus changes live,
    // so granting permission mid-session shows the page immediately.
    private var showCurrentPage: Bool {
        switch locationManager.authorizationStatus {
        case .denied, .restricted: return false
        default: return true
        }
    }

    // Total dots: optionally Current + Saved + Add Page
    private var pageCount: Int { (showCurrentPage ? 1 : 0) + store.saved.count + 1 }

    // Maps a selectedID string to the dot index, accounting for whether
    // the current-location page is present.
    private var currentIndex: Int {
        if showCurrentPage {
            if selectedID == "current" { return 0 }
            if selectedID == "add" { return pageCount - 1 }
            if let idString = selectedID,
               let idx = store.saved.firstIndex(where: { $0.id.uuidString == idString }) {
                return idx + 1
            }
            return 0
        } else {
            if selectedID == "add" { return pageCount - 1 }
            if let idString = selectedID,
               let idx = store.saved.firstIndex(where: { $0.id.uuidString == idString }) {
                return idx
            }
            return 0
        }
    }

    // Tracks whether the currently-visible page has a light background.
    // NOTE: PageDotsView always uses white indicators on a forced-dark glass,
    // so this state is kept for potential future use but does not affect the bar.
    @State private var isLightBackground = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedID) {
                // Current Location Page — hidden when location access is denied/restricted.
                if showCurrentPage {
                    LocationPageView(savedLocation: nil, onBackgroundChange: { isLightBackground = $0 })
                        .tag("current" as String?)
                }

                // Saved Location Pages
                ForEach(store.saved) { loc in
                    LocationPageView(
                        savedLocation: loc,
                        onBackgroundChange: { isLightBackground = $0 },
                        selectedID: $selectedID,
                        showCurrentPage: showCurrentPage
                    )
                    .tag(loc.id.uuidString as String?)
                }

                // Add Location Page — always dark (clear day gradient)
                AddLocationPage(onAdded: {
                    if let newest = store.saved.last {
                        selectedID = newest.id.uuidString
                    }
                })
                .tag("add" as String?)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            // Reset brightness hint when swiping so there's no stale state
            // while the new page is still loading.
            .onChange(of: selectedID) { /* isLightBackground reset intentionally removed — bar is always dark */ }
            
            HStack {
                Spacer()
                PageDotsView(
                    count: pageCount,
                    currentIndex: currentIndex,
                    isLightBackground: isLightBackground,
                    showCurrentPage: showCurrentPage,
                    onSelectIndex: { newIndex in
                        selectedID = idForIndex(newIndex)
                    }
                )
                Spacer()
            }
        }
        .onAppear {
            locationManager.requestLocation()
        }
    }
    
    private func idForIndex(_ index: Int) -> String? {
        let clamped = min(max(index, 0), pageCount - 1)

        if clamped == pageCount - 1 { return "add" }

        if showCurrentPage {
            if clamped == 0 { return "current" }
            let savedIndex = clamped - 1
            guard store.saved.indices.contains(savedIndex) else { return "current" }
            return store.saved[savedIndex].id.uuidString
        } else {
            guard store.saved.indices.contains(clamped) else { return "add" }
            return store.saved[clamped].id.uuidString
        }
    }
}
// MARK: - Custom Page Dots

struct PageDotsView: View
{
    let count: Int
    let currentIndex: Int
    let isLightBackground: Bool
    let showCurrentPage: Bool
    let onSelectIndex: (Int) -> Void

    @State private var dragPreviewIndex: Int?

    private let itemSpacing: CGFloat = 10
    private let horizontalInset: CGFloat = 18
    private let verticalInset: CGFloat = 10
    private let itemSize: CGFloat = 10
    private let iconSize: CGFloat = 11
    private let tapThreshold: CGFloat = 8

    private var displayIndex: Int
    {
        dragPreviewIndex ?? currentIndex
    }

    private var controlWidth: CGFloat
    {
        let visualItemWidth = max(itemSize, iconSize)
        let contentWidth =
            CGFloat(count) * visualItemWidth +
            CGFloat(max(count - 1, 0)) * itemSpacing

        return contentWidth + (horizontalInset * 2)
    }

    var body: some View
    {
        GeometryReader { geo in
            let width = geo.size.width

            HStack(spacing: itemSpacing)
            {
                ForEach(0..<count, id: \.self) { index in
                    dotView(for: index)
                }
            }
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, verticalInset)
            .frame(maxHeight: .infinity)
            .contentShape(Capsule())
            .background {
                glassBackground
            }
            .overlay {
                glassStroke
            }
            .gesture(pageGesture(width: width))
        }
        .frame(width: controlWidth, height: 42)
    }

    // Indicators are always white — the bar background is always dark.
    private var primaryColor: Color   { .white }
    private var secondaryColor: Color { .white.opacity(0.45) }

    @ViewBuilder
    private func dotView(for index: Int) -> some View
    {
        let isSelected = index == displayIndex

        if index == 0 && showCurrentPage
        {
            Image(systemName: "location.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(isSelected ? primaryColor : secondaryColor)
                .scaleEffect(isSelected ? 1.08 : 1.0)
                .animation(.easeInOut(duration: 0.16), value: displayIndex)
                .animation(.easeInOut(duration: 0.3), value: isLightBackground)
        }
        else if index == count - 1
        {
            Image(systemName: "plus")
                .font(.system(size: iconSize, weight: .heavy))
                .foregroundStyle(isSelected ? primaryColor : secondaryColor)
                .scaleEffect(isSelected ? 1.08 : 1.0)
                .animation(.easeInOut(duration: 0.16), value: displayIndex)
                .animation(.easeInOut(duration: 0.3), value: isLightBackground)
        }
        else
        {
            Circle()
                .fill(isSelected ? primaryColor : secondaryColor)
                .frame(width: itemSize, height: itemSize)
                .scaleEffect(isSelected ? 1.08 : 1.0)
                .animation(.easeInOut(duration: 0.16), value: displayIndex)
                .animation(.easeInOut(duration: 0.3), value: isLightBackground)
        }
    }

    @ViewBuilder
    private var glassBackground: some View
    {
        if #available(iOS 26.0, *)
        {
            // Real liquid glass, forced dark so indicators are always legible
            // regardless of the weather background behind it.
            // .dark tint collapses the adaptive auto-tinting that would make
            // the capsule go light over snow or clear-day backgrounds.
            Capsule()
                .glassEffect(.regular.tint(.black.opacity(0.2)).interactive())
        }
        else
        {
            // Always dark: thin material with a dark overlay keeps indicators visible
            // over snow, clear-day, and every other background.
            Capsule()
                .fill(AnyShapeStyle(Color.black.opacity(0.30)))
                .background {
                    Capsule().fill(.ultraThinMaterial)
                }
        }
    }

    @ViewBuilder
    private var glassStroke: some View
    {
        if #available(iOS 26.0, *)
        {
            // Liquid glass renders its own specular border; no manual stroke needed.
            EmptyView()
        }
        else
        {
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
        }
    }

    private func pageGesture(width: CGFloat) -> some Gesture
    {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let localX = min(max(value.location.x, 0), width)
                let proposedIndex = indexForX(localX, width: width)

                guard abs(value.translation.width) > tapThreshold else { return }

                if dragPreviewIndex != proposedIndex
                {
                    dragPreviewIndex = proposedIndex
                    Haptics.shared.impact(.light)
                }
            }
            .onEnded { value in
                let localX = min(max(value.location.x, 0), width)

                defer
                {
                    dragPreviewIndex = nil
                }

                if abs(value.translation.width) <= tapThreshold
                {
                    let nextIndex =
                        localX < width / 2
                        ? max(currentIndex - 1, 0)
                        : min(currentIndex + 1, count - 1)

                    onSelectIndex(nextIndex)
                    Haptics.shared.impact(.light)
                    return
                }

                let finalIndex = indexForX(localX, width: width)
                onSelectIndex(finalIndex)
                Haptics.shared.impact(.light)
            }
    }

    private func indexForX(_ x: CGFloat, width: CGFloat) -> Int
    {
        guard count > 1, width > 0 else { return 0 }

        let progress = x / width
        let rawIndex = progress * CGFloat(count - 1)
        return min(max(Int(round(rawIndex)), 0), count - 1)
    }
}

// MARK: - Add Location Page

struct AddLocationPage: View {
    @Environment(LocationStore.self) private var store
    @Environment(LocationManager.self) private var locationManager
    var onAdded: (() -> Void)? = nil
    @State private var sunEvent: SunEvent? = nil
    @State private var showSearch = false
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            // Add-location page: clear sky, time-of-day resolved from device clock.
            GradientBackgroundView(
                condition: .clear,
                timeOfDay: WeatherTimeOfDay.from(sun: sunEvent, utcOffsetSeconds: TimeZone.current.secondsFromGMT())
            )

            VStack(spacing: 30) {
                Spacer()
                
                Group {
                    if #available(iOS 26.0, *) {
                        Button(action: {
                            Haptics.shared.impact(.medium)
                            showSearch = true
                        }) {
                            Label("Add Location", systemImage: "plus")
                                .bold()
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.white)
                                .font(.system(size: 50, weight: .ultraLight))
                                .frame(width: 80, height: 80)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.blue)
                        .buttonBorderShape(.circle)
                        .shadow(color: .blue.opacity(0.5), radius: 20)
                    } else {
                        Button {
                            Haptics.shared.impact(.medium)
                            showSearch = true
                        } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 84, height: 84)
                                        .shadow(color: .blue.opacity(0.5), radius: 20)
                                    
                                    Image(systemName: "plus")
                                        .font(.system(size: 36, weight: .light))
                                        .foregroundStyle(.white)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                .padding(.bottom, 120)

                VStack(spacing: 8) {
                    Text("Add Location")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Track your local mountains, \ncities, and favorites.").font(.system(size: 17))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 2)
            .repeatForever(autoreverses: false)) { isAnimating = true } }
        .sheet(isPresented: $showSearch) { LocationSearchView(onAdded: onAdded)
            .environment(store) }
        .task {
            sunEvent = await fetchSunEventForAddPage(coordinate: locationManager.coordinate)
        }
    }
}

// MARK: - Weather Content

struct WeatherContentView: View {
    let viewModel: WeatherViewModel
    @Binding var selectedDay: DailyForecast?
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedAlert: NWSAlert?
    
    var body: some View {
        VStack(spacing: 12) {
            // Alert banners — driven by NWS Alerts API, capped at 2, sorted by severity.
            // Wind alerts use the ski-resort label override (Wind Hold Risk vs High Wind Alert).
            // Background tint opacity scales with severity: Extreme 60%, Severe 40%, Moderate/Minor 15%.
            Group {
                let visibleAlerts = Array(viewModel.alerts.prefix(2))
                if !visibleAlerts.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(visibleAlerts) { alert in
                            let cfg = alert.display
                            // Ski resort override: relabel wind alerts
                            let title: String = {
                                let e = alert.event.lowercased()
                                if e.contains("wind") {
                                    return viewModel.isSkiResort ? "Wind Hold Risk" : cfg.title
                                }
                                return cfg.title
                            }()
                            Button {
                                Haptics.shared.impact(.light)
                                selectedAlert = alert
                            } label: {
                                WeatherAlertBanner(
                                    title:         title,
                                    message:       alert.headline,
                                    tintColor:     cfg.color,
                                    warningSymbol: cfg.symbol,
                                    severity:      alert.severity
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
            }
            .padding(.bottom, 4)
            
            // Hourly Forecast
            if !viewModel.hourly.isEmpty {
                HourlyCard(
                    hours: viewModel.hourly,
                    dayProse: viewModel.daily.first?.dayProse,
                    sunEvent: viewModel.sunEvent
                )
                .padding(.horizontal, 16)
                .onTapGesture {
                    if let today = viewModel.daily.first {
                        Haptics.shared.impact(.light)
                        selectedDay = today
                    }
                }
            }

            if !viewModel.daily.isEmpty {
                DailyCard(
                    days: viewModel.daily,
                    globalLow: viewModel.globalLow,
                    globalHigh: viewModel.globalHigh,
                    onSelect: { selectedDay = $0 }
                )
                .padding(.horizontal, 16)
            }

            if let cur = viewModel.current {
                WindCard(
                    windSpeed:          cur.windSpeed,
                    windSpeedInstant:   cur.windSpeedInstant,
                    windGusts:          cur.windGusts,
                    windDegrees:        cur.windDirection,
                    windDirectionLabel: cur.windDirectionLabel
                )
                .padding(.horizontal, 16)
            }

            if let sun = viewModel.sunEvent {
                SunCard(sunEvent: sun)
                    .padding(.horizontal, 16)
            }

            Spacer(minLength: 40)
        }
        .padding(.top, 8)
        .sheet(item: $selectedAlert) { alert in
            AlertDetailSheet(alert: alert)
        }
    }
}

// MARK: - Current Header

struct CurrentConditionsHeader: View {
    let locationName: String
    let isCurrentLocation: Bool
    let current: CurrentConditions?
    let high: Double?
    let low: Double?
    let isLoading: Bool
    let currentSFSymbol: String
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading) {
            
            // Location name row
            HStack(spacing: 5) {
                if isCurrentLocation {
                    Image(systemName: "location.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Text(locationName.isEmpty ? "—" : locationName)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.bottom, -20)

            HStack(alignment: .center, spacing: 16) {
                VStack {
                    Spacer()
                    Image(systemName: currentSFSymbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 60))
                        .shadow(radius: 6)
                        .opacity(current == nil ? 0.4 : 1.0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // RIGHT — temperature + H/L pills
                VStack(alignment: .trailing, spacing: 8) {
                    Text(current.map { "\(Int(settings.temperature($0.temperature).rounded()))°" } ?? "—")
                        .font(.system(size: 52, weight: .regular, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 6)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    
                    if let h = high, let l = low {
                        HStack(spacing: 10) {
                            Text("L: \(Int(settings.temperature(l).rounded()))°")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.cyan.opacity(0.6), in: Capsule())
                                .overlay(Capsule().stroke(.cyan, lineWidth: 2))
                            
                            Text("H: \(Int(settings.temperature(h).rounded()))°")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.6), in: Capsule())
                                .overlay(Capsule().stroke(.orange, lineWidth: 2))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxHeight: 100)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

// MARK: Alert Card

/* Bottom sheet shown when the user taps a weather alert banner.
 * Displays the full NWS descriptive text with a drag indicator at the top.
 * Presented as a 1/3-height detent, expandable to large.
 */
struct AlertDetailSheet: View {
    let alert: NWSAlert

    var body: some View {
        let cfg = alert.display

        VStack(alignment: .leading, spacing: 0) {

            // Drag indicator
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 16)

            // Header: symbol + title
            HStack(spacing: 12) {
                Image(systemName: cfg.symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(cfg.color)

                VStack(alignment: .leading, spacing: 2) {
                    Text(cfg.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(alert.severity == .unknown ? "Weather Alert" : alert.severity.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(cfg.color)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider().padding(.horizontal, 20)

            // Full description text
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if !alert.headline.isEmpty {
                        Text(alert.headline)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    if !alert.description.isEmpty {
                        let sections = parseAlertSections(alert.description)
                        if sections.isEmpty {
                            Text(alert.description)
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(sections, id: \.0) { header, body in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(header)
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(cfg.color)
                                        Text(body)
                                            .font(.system(size: 15))
                                            .foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    } else {
                        Text("No additional details available.")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .presentationDetents([.fraction(0.4), .large])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(20)
    }
}

struct WeatherAlertBanner: View {
    let title: String
    let message: String
    let tintColor: Color
    let warningSymbol: String
    var severity: NWSAlertSeverity = .unknown
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: warningSymbol)
                .font(.system(size: 20))
                .foregroundStyle(tintColor)
                .padding(.top, 6)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tintColor)
                
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(tintColor.opacity(severity.backgroundOpacity))
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tintColor.opacity(severity.borderOpacity), lineWidth: 3)
        )
    }
}

// MARK: - Hourly Card

struct HourlyCard: View {
    let hours: [HourlyForecast]
    let dayProse: String?
    var sunEvent: SunEvent? = nil

    private var timeline: [HourlySlot] {
        var slots: [HourlySlot] = hours.map { .forecast($0) }
        if let sun = sunEvent {
            let start = hours.first?.time ?? Date()
            let end   = hours.last?.time  ?? Date()

            if sun.sunrise > start && sun.sunrise <= end { slots.append(.sunrise(sun.sunrise)) }
            if sun.sunset  > start && sun.sunset  <= end { slots.append(.sunset(sun.sunset)) }

            if let tmrwRise = Calendar.current.date(byAdding: .day, value: 1, to: sun.sunrise), tmrwRise > start && tmrwRise <= end { slots.append(.sunrise(tmrwRise)) }
            if let tmrwSet = Calendar.current.date(byAdding: .day, value: 1, to: sun.sunset), tmrwSet > start && tmrwSet <= end { slots.append(.sunset(tmrwSet)) }
        }
        return slots.sorted { $0.time < $1.time }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                // Detailed Forecast Text at the top
                if let prose = dayProse, !prose.isEmpty {
                    Text(prose)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 12)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Divider()
                        .background(.white.opacity(0.15))
                        .padding(.horizontal, 16)
                }

                CardHeader(icon: "clock", title: "HOURLY FORECAST")
                Divider()
                    .background(.white.opacity(0.2))
                    .padding(.horizontal, 16)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(timeline) { slot in
                            switch slot {
                            case .forecast(let h): HourlyCell(hour: h)
                            case .sunrise(let t):  SunEventCell(time: t, isRise: true)
                            case .sunset(let t):   SunEventCell(time: t, isRise: false)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.vertical, 8)
            }
        }
    }
}

enum HourlySlot: Identifiable {
    case forecast(HourlyForecast)
    case sunrise(Date)
    case sunset(Date)

    var id: String {
        switch self {
        case .forecast(let h): return h.id.uuidString
        case .sunrise(let t):  return "rise-\(t.timeIntervalSince1970)"
        case .sunset(let t):   return "set-\(t.timeIntervalSince1970)"
        }
    }
    var time: Date {
        switch self {
        case .forecast(let h): return h.time
        case .sunrise(let t), .sunset(let t): return t
        }
    }
}

struct SunEventCell: View {
    let time: Date
    let isRise: Bool
    @EnvironmentObject private var settings: AppSettings
    private var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = settings.is24Hour ? "HH:mm" : "h:mm"
        return f.string(from: time).lowercased()
    }
    var body: some View {
        VStack(spacing: 6) {
            Text(timeLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Image(systemName: isRise ? "sunrise.fill" : "sunset.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 22))
                .frame(height: 26)
            Text(isRise ? "Sunrise" : "Sunset")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(width: 58)
        .padding(.vertical, 6)
    }
}

struct HourlyCell: View {
    let hour: HourlyForecast
    @EnvironmentObject private var settings: AppSettings
    var timeLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(hour.time), cal.component(.hour, from: hour.time) == cal.component(.hour, from: Date()) { return "Now" }
        let f = DateFormatter()
        f.dateFormat = settings.is24Hour ? "HH" : "ha"
        return f.string(from: hour.time).lowercased()
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(timeLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Image(systemName: hour.resolvedSymbol
                              ?? noaaSFSymbol(condition: hour.shortForecast, isDay: hour.isDay)
                              ?? wmoSFSymbol(code: 2, isDay: hour.isDay))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 22))
                .frame(height: 26)
            Text("\(Int(settings.temperature(hour.temperature).rounded()))°")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(width: 58)
        .padding(.vertical, 6)
    }
}

// MARK: - Daily Card

struct DailyCard: View {
    let days: [DailyForecast]
    let globalLow: Double
    let globalHigh: Double
    let onSelect: (DailyForecast) -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(icon: "calendar", title: "7-DAY FORECAST")
                Divider()
                    .background(.white.opacity(0.2))
                    .padding(.horizontal, 16)
                VStack(spacing: 0) {
                    ForEach(Array(days.prefix(7).enumerated()), id: \.offset) { idx, day in
                        Button {
                            Haptics.shared.impact(.light)
                            onSelect(day)
                        } label: {
                            DailyRow(day: day, globalLow: globalLow, globalHigh: globalHigh)
                        }
                        .buttonStyle(.plain)
                        
                        if idx < min(days.count, 7) - 1 {
                            Divider()
                                .background(.white.opacity(0.15))
                                .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
}

struct DailyRow: View {
    let day: DailyForecast
    let globalLow: Double
    let globalHigh: Double
    @EnvironmentObject private var settings: AppSettings
    
    private var dayName: String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        f.timeZone = TimeZone(identifier: day.timeZoneIdentifier) ?? .current
        return f.string(from: day.date)
    }

    var body: some View {
        // Convert raw imperial values to display values once, reactively.
        let dispHigh   = settings.temperature(day.high)
        let dispLow    = settings.temperature(day.low)
        let dispGHigh  = settings.temperature(globalHigh)
        let dispGLow   = settings.temperature(globalLow)

        HStack(spacing: 0) {
            Text(isToday(day) ? "Today" : dayName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 52, alignment: .leading)

            HStack(spacing: -2) {
                VStack {
                    Image(systemName: day.daySymbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 22))
                        .frame(width: 42)
                    
                    if day.precipProbability >= 20 {
                        HStack(spacing: 3) {
                            // Use raindrop for rain and mixed (rain+snow).
                            // Only pure snow gets the snowflake.
                            Image(systemName: day.precipType == .snow ? "snowflake" : "drop.fill")
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 9))
                                .foregroundStyle(.cyan)
                            Text("\(day.precipProbability)%")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.cyan)
                        }
                        .frame(width: 42, alignment: .center)
                    }
                }
                
                if let nightSym = day.rowNightSymbol {
                    Image(systemName: nightSym)
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.system(size: 18))
                        .offset(x: 9)
                }
            }
            .frame(width: 60, alignment: .leading)

            Spacer()

            if day.accumulation.hasAccumulation {
                HStack(spacing: 6) {
                    // Same logic as the probability icon: only pure snow gets the snowflake.
                    Image(systemName: day.precipType == .snow ? "snowflake" : "drop.fill")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.cyan)
                    Text(day.accumulation.displayString(settings: settings))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.cyan)
                    Text("\(Int(dispLow.rounded()))° | \(Int(dispHigh.rounded()))°")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 60, alignment: .trailing)
                }
            } else {
                Text("\(Int(dispLow.rounded()))°")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .frame(width: 36, alignment: .trailing)
                TempRangeBar(low: dispLow, high: dispHigh, globalLow: dispGLow, globalHigh: dispGHigh)
                    .frame(width: 72, height: 8).padding(.horizontal, 6)
                Text("\(Int(dispHigh.rounded()))°")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 36, alignment: .leading)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
                .padding(.leading, 6)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - Temp Range Bar

struct TempRangeBar: View {
    let low, high, globalLow, globalHigh: Double
    var body: some View {
        GeometryReader { geo in
            let range = max(globalHigh - globalLow, 1)
            let s = max(0, min(1, (low  - globalLow) / range))
            let e = max(0, min(1, (high - globalLow) / range))
            let w = geo.size.width
            
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule()
                    .fill(LinearGradient(colors: [.cyan, .yellow, .orange],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, (e - s) * w), height: 7)
                    .offset(x: s * w)
            }
        }
    }
}

// MARK: - Wind Card & Compass

struct WindCard: View {
    let windSpeed: Double        // NOAA prose average — Wind row
    let windSpeedInstant: Double // OM instantaneous — compass center
    let windGusts: Double
    let windDegrees: Double
    let windDirectionLabel: String
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(icon: "wind", title: "WIND")
                Divider()
                    .background(.white.opacity(0.2))
                    .padding(.horizontal, 16)

                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 0) {
                        WindStatRow(
                            label: "Wind",
                            value: "\(Int(settings.windSpeed(windSpeed).rounded())) \(settings.windUnit)"
                        )
                        Divider().background(.white.opacity(0.12))
                        WindStatRow(
                            label: "Gusts",
                            value: "\(Int(settings.windSpeed(windGusts).rounded())) \(settings.windUnit)"
                        )
                        Divider().background(.white.opacity(0.12))
                        WindStatRow(
                            label: "Direction",
                            value: "\(Int(windDegrees.rounded()))° \(windDirectionLabel)"
                        )
                    }
                    .frame(maxWidth: .infinity)

                    CompassRose(
                        degrees:    windDegrees,
                        speedLabel: "\(Int(settings.windSpeed(windSpeedInstant).rounded()))",
                        unitLabel:  settings.windUnit
                    )
                    .frame(width: 120, height: 120)
                    .padding(.trailing, 8)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }
}

struct WindStatRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
            Spacer()
            Text(value).font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.vertical, 11)
    }
}

struct CompassRose: View {
    let degrees: Double
    let speedLabel: String
    let unitLabel: String

    var body: some View {
        GeometryReader { geo in
            let cx = geo.size.width  / 2
            let cy = geo.size.height / 2
            let r  = min(cx, cy) - 10

            // Shared geometry — all distances from compass center along the arrow axis.
            let centerGap:  CGFloat = 25   // clear zone on each side of center for the speed label
            let dotR:       CGFloat = 5    // tail dot radius
            let tailR:      CGFloat = r    // tail dot sits on the ring
            let iconSize:   CGFloat = 14   // location.fill pt size
            // The icon's geometric center sits at iconCenterR so the visual tip
            // (top of the ~14pt glyph) lands flush with the ring at radius r.
            let iconCenterR: CGFloat = r - iconSize / 2

            ZStack {
                // ── Tick marks ──────────────────────────────────────────────
                Canvas { ctx, _ in
                    for i in 0..<36 {
                        let isCardinalZone = [0, 1, 35, 8, 9, 10, 17, 18, 19, 26, 27, 28].contains(i)
                        if isCardinalZone { continue }
                        let angle  = Double(i) * (10 * .pi / 180)
                        let isMed  = i % 3 == 0
                        let innerR = r - (isMed ? 7 : 4)
                        var path = Path()
                        path.move(to: CGPoint(x: cx + CGFloat(cos(angle - .pi/2)) * r,
                                              y: cy + CGFloat(sin(angle - .pi/2)) * r))
                        path.addLine(to: CGPoint(x: cx + CGFloat(cos(angle - .pi/2)) * innerR,
                                                 y: cy + CGFloat(sin(angle - .pi/2)) * innerR))
                        ctx.stroke(path, with: .color(.white.opacity(isMed ? 0.3 : 0.15)), lineWidth: 1)
                    }
                }

                // ── Cardinal labels ─────────────────────────────────────────
                ForEach([("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)], id: \.0) { label, deg in
                    let rad = (deg - 90) * .pi / 180
                    Text(label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .position(x: cx + CGFloat(cos(rad)) * r,
                                  y: cy + CGFloat(sin(rad)) * r)
                }

                // ── Arrow shaft + tail — Canvas, rotated as a group ────────────
                //
                // Drawn in local space where -Y = head direction, +Y = tail direction.
                // A single CTM rotate around the compass center spins everything
                // together so shaft/tail always align with the icon above.
                Canvas { ctx, _ in
                    let shaftW: CGFloat = 4

                    ctx.translateBy(x: cx, y: cy)
                    ctx.rotate(by: .degrees(degrees))

                    // Tail dot on the ring
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: -dotR, y: tailR - dotR,
                                               width: dotR * 2, height: dotR * 2)),
                        with: .color(.white)
                    )

                    // Tail shaft: from top of tail dot up to center gap
                    var tailSeg = Path()
                    tailSeg.move(to: CGPoint(x: 0, y: tailR - dotR))
                    tailSeg.addLine(to: CGPoint(x: 0, y: centerGap))
                    ctx.stroke(tailSeg, with: .color(.white),
                               style: StrokeStyle(lineWidth: shaftW, lineCap: .round))

                    // Head shaft: from center gap up to the base of the icon
                    var headSeg = Path()
                    headSeg.move(to: CGPoint(x: 0, y: -centerGap))
                    headSeg.addLine(to: CGPoint(x: 0, y: -iconCenterR))
                    ctx.stroke(headSeg, with: .color(.white),
                               style: StrokeStyle(lineWidth: shaftW, lineCap: .round))
                }

                let headRad = (degrees - 90) * .pi / 180   // screen angle for head direction
                Image(systemName: "location.fill")
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(degrees - 45))  // orient tip along head direction
                    .position(
                        x: cx + CGFloat(cos(headRad)) * iconCenterR,
                        y: cy + CGFloat(sin(headRad)) * iconCenterR
                    )

                // ── Center speed label ───────────────────────────────────────
                VStack(spacing: -2) {
                    Text(speedLabel)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(unitLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}

// MARK: - Sun Card & Arc

struct SunCard: View {
    let sunEvent: SunEvent
    @EnvironmentObject private var settings: AppSettings
    private var fmt: DateFormatter {
        settings.is24Hour
            ? { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
            : { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                // Build the header time string. In 12-hour mode append AM/PM; in 24-hour just use the formatted time.
                let rawTime = fmt.string(from: sunEvent.nextTime)
                let sunEventTime = settings.is24Hour
                    ? " — " + rawTime
                    : " — " + rawTime.prefix(while: { $0 != " " }) + rawTime.suffix(2)
                
                CardHeader(icon: sunEvent.nextIsRise ? "sunrise.fill" : "sunset.fill",
                           title: sunEvent.nextIsRise ? "SUNRISE" + sunEventTime : "SUNSET" + sunEventTime)
                Divider().background(.white.opacity(0.2)).padding(.horizontal, 16)

                
                VStack(alignment: .center, spacing: 16) {
                    
                    Spacer()

                    SunOrbitalView(sunrise: sunEvent.sunrise, sunset: sunEvent.sunset)
                        .frame(height: 50)
                        .padding(.horizontal, 24)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sunrise").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            Text(fmt.string(from: sunEvent.sunrise)).font(.system(size: 13, weight: .medium))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Sunset").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            Text(fmt.string(from: sunEvent.sunset)).font(.system(size: 13, weight: .medium))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.bottom, 4)
                }
                .padding([.horizontal, .bottom], 20)
            }
        }
    }
}

struct SunOrbitalView: View {
    let sunrise: Date
    let sunset: Date
    
    private var progress: Double {
        let total = sunset.timeIntervalSince(sunrise)
        guard total > 0 else { return 0 }
        return max(0, min(1.0, Date().timeIntervalSince(sunrise) / total))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let radius: CGFloat = w * 0.8
            let center = CGPoint(x: w / 2, y: radius + 10)
            
            let startAngle: Double = 240
            let endAngle: Double = 300
            let currentAngle = startAngle + (progress * (endAngle - startAngle))
            
            let sunPos = CGPoint(
                x: center.x + radius * cos(CGFloat(currentAngle) * .pi / 180),
                y: center.y + radius * sin(CGFloat(currentAngle) * .pi / 180)
            )
            
            ZStack {
                // Background path
                Path { p in
                    p.addArc(center: center, radius: radius, startAngle: .degrees(startAngle), endAngle: .degrees(endAngle), clockwise: false)
                }
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 6, lineCap: .round))

                // Active path glow
                Path { p in
                    p.addArc(center: center, radius: radius, startAngle: .degrees(startAngle), endAngle: .degrees(currentAngle), clockwise: false)
                }
                .stroke(
                    LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .blur(radius: 3)

                // Active path (core)
                Path { p in
                    p.addArc(center: center, radius: radius, startAngle: .degrees(startAngle), endAngle: .degrees(currentAngle), clockwise: false)
                }
                .stroke(
                    LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )

                // Sun orb
                ZStack {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 25, height: 25)
                        .blur(radius: 7)
                    
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .shadow(color: .white, radius: 4)
                        .blur(radius: 2)
                }
                .position(sunPos)
            }
        }
    }
}

// MARK: - Day Detail Sheet
// Paged across the full 7-day forecast. Opens at the tapped day.
// Date strip at top shows the current day centred with neighbours.

struct DayDetailSheet: View {
    let days: [DailyForecast]
    let startIndex: Int
    let globalLow: Double
    let globalHigh: Double
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var tabSelection: Int

    init(days: [DailyForecast], startIndex: Int, globalLow: Double, globalHigh: Double) {
        self.days = days
        self.startIndex = startIndex
        self.globalLow = globalLow
        self.globalHigh = globalHigh
        self._currentIndex = State(initialValue: startIndex)
        self._tabSelection  = State(initialValue: startIndex)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DateStrip(days: days, currentIndex: $currentIndex)
                    .padding(.top, 8)

                ZStack(alignment: .bottom) {
                    TabView(selection: $tabSelection) {
                        ForEach(days.indices, id: \.self) { i in
                            DayDetailPage(
                                day: days[i],
                                globalLow: globalLow,
                                globalHigh: globalHigh
                            )
                            .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .onChange(of: currentIndex) { _, newValue in
                        withAnimation(.easeInOut) { tabSelection = newValue }
                    }
                    .onChange(of: tabSelection) { _, newValue in
                        if newValue != currentIndex { currentIndex = newValue }
                    }

                    // Fade content into the home indicator area.
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.3)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 80)
                    .allowsHitTesting(false)
                }
                .ignoresSafeArea(edges: .bottom)
            }
            .navigationTitle("Forecast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Date Strip
// Shows the current day centred with up to 3 neighbours on each side. Tappable.

struct DateStrip: View {
    let days: [DailyForecast]
    @Binding var currentIndex: Int

    private let shortDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
    private let shortDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d"; return f
    }()

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let cellWidth = totalWidth / CGFloat(days.count)
            
            VStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    HStack(spacing: 0) {
                        ForEach(days.indices, id: \.self) { i in
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    currentIndex = i
                                }
                            } label: {
                                VStack(spacing: 3) {
                                    Text(isToday(days[i]) ? "Today" : {
                                        let f = DateFormatter(); f.dateFormat = "EEE"
                                        f.timeZone = TimeZone(identifier: days[i].timeZoneIdentifier) ?? .current
                                        return f.string(from: days[i].date)
                                    }())
                                        .font(.system(size: 11, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.6))
                                    Text({
                                        let f = DateFormatter(); f.dateFormat = "d"
                                        f.timeZone = TimeZone(identifier: days[i].timeZoneIdentifier) ?? .current
                                        return f.string(from: days[i].date)
                                    }())
                                        .font(.system(size: 17, weight: .regular))
                                        .foregroundStyle(.white)
                                    
                                    // Empty space to reserve room for the bar below
                                    Color.clear.frame(height: 4)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    // Sliding indicator bar
                    Capsule()
                    .fill(Color.orange)
                    .frame(width: 28, height: 4)
                        .offset(x: (CGFloat(currentIndex) * cellWidth) + (cellWidth / 2) - 14)
                        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: currentIndex)
                        .padding(.bottom, 4)
                }
                
                Divider()
                    .background(.white.opacity(0.2))
            }
        }
        .frame(height: 60)
        .padding(.horizontal, 16)
    }
    
}

// MARK: - Single Day Page (inside the paged TabView)

struct DayDetailPage: View {
    let day: DailyForecast
    let globalLow: Double
    let globalHigh: Double
    @EnvironmentObject private var settings: AppSettings

    private var fullDayName: String {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"
        f.timeZone = TimeZone(identifier: day.timeZoneIdentifier) ?? .current
        return f.string(from: day.date)
    }

    var body: some View {
        let dispHigh  = settings.temperature(day.high)
        let dispLow   = settings.temperature(day.low)
        let dispGHigh = settings.temperature(globalHigh)
        let dispGLow  = settings.temperature(globalLow)

        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {

                // Header: day name, H/L, symbol
                let dayProseIsSubstituted = isToday(day)
                    && !day.nightProse.isEmpty
                    && day.dayProse == day.nightProse
                let headerSymbol = dayProseIsSubstituted
                    ? (day.nightSymbol ?? "moon.stars.fill")
                    : day.daySymbol

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fullDayName).font(.system(size: 22, weight: .semibold))
                        HStack(spacing: 16) {
                            Label("\(Int(dispLow.rounded()))°", systemImage: "arrow.down")
                                .font(.system(size: 17))
                                .foregroundStyle(.cyan)
                            Label("\(Int(dispHigh.rounded()))°", systemImage: "arrow.up")
                                .font(.system(size: 17))
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Image(systemName: headerSymbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 48))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // Hourly temperature graph
                if !day.hourlyTemps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TEMPERATURE")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        InteractiveTempGraph(points: day.hourlyTemps, globalLow: dispGLow, globalHigh: dispGHigh)
                            .frame(height: 160)
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                }

                // Accumulation callout
                if day.accumulation.hasAccumulation {
                    HStack(spacing: 8) {
                        Image(systemName: day.precipType == .snow ? "snowflake" : "drop.fill")
                            .foregroundStyle(.cyan)
                        Text("Accumulation: \(day.accumulation.displayString(settings: settings))")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.cyan)
                    }
                    .padding(.horizontal, 20)
                }

                // Day prose
                if !day.dayProse.isEmpty {
                    ForecastProseCard(
                        symbol: day.daySymbol,
                        label: "DAY",
                        prose: day.dayProse
                    )
                        .padding(.horizontal, 16)
                }

                // Night prose
                if !day.nightProse.isEmpty {
                    ForecastProseCard(
                        symbol: day.nightSymbol ?? "moon.stars.fill",
                        label: "NIGHT",
                        prose: day.nightProse
                    )
                    .padding(.horizontal, 16)
                }

                Spacer(minLength: 32)
            }
        }
    }
}

struct ForecastProseCard: View {
    let symbol: String
    let label: String
    let prose: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 17))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(prose)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Interactive Graph

struct InteractiveTempGraph: View {
    let points: [HourlyForecast]
    let globalLow: Double
    let globalHigh: Double
    @EnvironmentObject private var settings: AppSettings
    @State private var dragX: CGFloat? = nil

    private let topPad:    CGFloat = 32
    private let bottomPad: CGFloat = 20
    private let leftPad:   CGFloat = 36
    private let rightPad:  CGFloat = 8

    private var hourlyPoints: [HourlyForecast] {
        var seen = Set<String>()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMddHH"
        return points.filter { seen.insert(fmt.string(from: $0.time)).inserted }
    }

    // Instance-method helpers
    private func cx(i: Int, count: Int, lp: CGFloat, pw: CGFloat) -> CGFloat {
        lp + pw * CGFloat(i) / CGFloat(max(count - 1, 1))
    }
    private func cy(temp: Double, lo: Double, rng: Double, tp: CGFloat, ph: CGFloat) -> CGFloat {
        tp + ph * CGFloat(1.0 - (temp - lo) / rng)
    }

    var body: some View {
        GeometryReader { geo in
            let w  = geo.size.width,  h  = geo.size.height
            let pw = w - leftPad - rightPad
            let ph = h - topPad - bottomPad
            let pts = hourlyPoints
            let rng = max(globalHigh - globalLow, 1)

            if pts.count > 1 {
                let cp: [(CGFloat, CGFloat)] = pts.indices.map { i in
                    (cx(i: i, count: pts.count, lp: leftPad, pw: pw),
                     cy(temp: settings.temperature(pts[i].temperature),
                        lo: globalLow, rng: rng, tp: topPad, ph: ph))
                }

                let fracIdx: Double? = dragX.map { dx in
                    Double(max(leftPad, min(w - rightPad, dx)) - leftPad) / Double(pw) * Double(pts.count - 1)
                }
                let dragPos: CGPoint? = fracIdx.map { f in
                    let lo = max(0, Int(f)), hi = min(pts.count - 1, lo + 1)
                    let t  = CGFloat(f - Double(lo))
                    return CGPoint(x: cp[lo].0 + (cp[hi].0 - cp[lo].0) * t,
                                   y: catmullRomY(pts: cp, i: lo, t: t))
                }
                let dragTemp: Double? = fracIdx.map { f in
                    let lo = max(0, Int(f)), hi = min(pts.count - 1, lo + 1)
                    let t  = f - Double(lo)
                    return (settings.temperature(pts[lo].temperature) * (1 - t)
                          + settings.temperature(pts[hi].temperature) * t).rounded()
                }

                let dispTemps = pts.map { settings.temperature($0.temperature) }
                let maxT = dispTemps.max() ?? globalHigh
                let minT = dispTemps.min() ?? globalLow
                let maxI = dispTemps.firstIndex(of: maxT) ?? 0
                let minI = dispTemps.firstIndex(of: minT) ?? 0

                let yRefs: [Double] = {
                    let step = (globalHigh - globalLow) / 3
                    return [globalLow + step, globalLow + step * 2]
                        .map { (($0 / 5).rounded() * 5) }
                }()

                ZStack(alignment: .topLeading) {
                    // Y-axis grid + labels
                    ForEach(yRefs, id: \.self) { temp in
                        let y = cy(temp: temp, lo: globalLow, rng: rng, tp: topPad, ph: ph)
                        Path { p in
                            p.move(to: CGPoint(x: leftPad, y: y))
                            p.addLine(to: CGPoint(x: w - rightPad, y: y))
                        }
                        .stroke(Color.white.opacity(0.08),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        Text("\(Int(temp.rounded()))°")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .position(x: leftPad / 2, y: y)
                    }

                    // Stroke
                    Path { path in
                        path.move(to: CGPoint(x: cp[0].0, y: cp[0].1))
                        catmullRomPath(into: &path, pts: cp)
                    }
                    .stroke(
                        LinearGradient(colors: [.orange, .cyan], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                    )

                    // High marker
                    let hx = cp[maxI].0, hy = cp[maxI].1
                    Circle().fill(Color.orange.opacity(0.85))
                        .frame(width: 9, height: 9)
                        .position(x: hx, y: hy)
                    Text("H:\(Int(maxT.rounded()))°")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                        .position(x: min(max(hx, leftPad + 16), w - rightPad - 16), y: hy - 13)

                    // Low marker
                    let lx = cp[minI].0, ly = cp[minI].1
                    Circle().fill(Color.cyan.opacity(0.85))
                        .frame(width: 9, height: 9)
                        .position(x: lx, y: ly)
                    Text("L:\(Int(minT.rounded()))°")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.cyan)
                        .position(x: min(max(lx, leftPad + 16), w - rightPad - 16), y: ly + 13)

                    // Hour labels (every 3rd)
                    ForEach(pts.indices, id: \.self) { i in
                        if i % 3 == 0 {
                            Text(hourLabel(pts[i].time))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .position(x: cp[i].0, y: h - bottomPad / 2)
                        }
                    }

                    // Drag scrubber
                    if let pos = dragPos, let temp = dragTemp {
                        Path { p in
                            p.move(to: CGPoint(x: pos.x, y: topPad))
                            p.addLine(to: CGPoint(x: pos.x, y: topPad + ph))
                        }
                        .stroke(Color.white.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        Circle().fill(Color.white)
                            .frame(width: 10, height: 10)
                            .position(x: pos.x, y: pos.y)
                        Circle().fill(.orange)
                            .frame(width: 6, height: 6)
                            .position(x: pos.x, y: pos.y)
                        let bubbleX = min(max(pos.x, leftPad + 20), w - rightPad - 20)
                        Text("\(Int(temp))°")
                            .font(.system(size: 13, weight: .bold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.regularMaterial, in: Capsule())
                            .position(x: bubbleX, y: pos.y - 22)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { dragX = $0.location.x }
                        .onEnded   { _ in withAnimation(.easeOut(duration: 0.25)) { dragX = nil } }
                )
            }
        }
    }

    private func catmullRomPath(into path: inout Path, pts: [(CGFloat, CGFloat)]) {
        guard pts.count >= 2 else { return }
        let ghost0 = CGPoint(x: 2*pts[0].0 - pts[1].0,           y: 2*pts[0].1 - pts[1].1)
        let ghostN = CGPoint(x: 2*pts.last!.0 - pts[pts.count-2].0,
                             y: 2*pts.last!.1 - pts[pts.count-2].1)
        let ext: [CGPoint] = [ghost0] + pts.map { CGPoint(x: $0.0, y: $0.1) } + [ghostN]
        let steps = 12
        for i in 0..<(ext.count - 3) {
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps)
                path.addLine(to: crPoint(ext[i], ext[i+1], ext[i+2], ext[i+3], t))
            }
        }
    }

    private func crPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let t2 = t*t, t3 = t2*t
        return CGPoint(
            x: 0.5*((2*p1.x)+(-p0.x+p2.x)*t+(2*p0.x-5*p1.x+4*p2.x-p3.x)*t2+(-p0.x+3*p1.x-3*p2.x+p3.x)*t3),
            y: 0.5*((2*p1.y)+(-p0.y+p2.y)*t+(2*p0.y-5*p1.y+4*p2.y-p3.y)*t2+(-p0.y+3*p1.y-3*p2.y+p3.y)*t3)
        )
    }

    private func catmullRomY(pts: [(CGFloat, CGFloat)], i: Int, t: CGFloat) -> CGFloat {
        let n = pts.count
        let p0 = CGPoint(x: pts[max(0,i-1)].0,       y: pts[max(0,i-1)].1)
        let p1 = CGPoint(x: pts[i].0,                 y: pts[i].1)
        let p2 = CGPoint(x: pts[min(n-1,i+1)].0,     y: pts[min(n-1,i+1)].1)
        let p3 = CGPoint(x: pts[min(n-1,i+2)].0,     y: pts[min(n-1,i+2)].1)
        return crPoint(p0, p1, p2, p3, t).y
    }

    private func hourLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "ha"; return f.string(from: d).lowercased()
    }
}

// MARK: - Utilities

// Whiteout brand accent — barrel red, sampled from Whiteout's keg.
extension Color {
    static let barrelRed = Color(red: 0.62, green: 0.13, blue: 0.13)
    static let barrelRedLight = Color(red: 0.82, green: 0.28, blue: 0.22)
}

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.thinMaterial).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.15), lineWidth: 1)
            )
    }
}

struct CardHeader: View {
    let icon: String; let title: String
    var body: some View {
        Label(title, systemImage: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }
}

private func fetchSunEventForAddPage(coordinate: CLLocationCoordinate2D?) async -> SunEvent? {
    var lat: Double
    var lon: Double

    if let coord = coordinate {
        lat = coord.latitude
        lon = coord.longitude
    } else {
        // IP geolocation fallback — no key required
        guard let url = URL(string: "https://ipapi.co/json/"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ipLat = json["latitude"] as? Double,
              let ipLon = json["longitude"] as? Double
        else { return nil }
        lat = ipLat
        lon = ipLon
    }

    guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&daily=sunrise,sunset&forecast_days=1&timezone=auto"),
          let (data, _) = try? await URLSession.shared.data(from: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let daily = json["daily"] as? [String: Any],
          let sunriseArr = daily["sunrise"] as? [String],
          let sunsetArr  = daily["sunset"]  as? [String],
          let sunriseStr = sunriseArr.first,
          let sunsetStr  = sunsetArr.first
    else { return nil }

    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
    fmt.locale = Locale(identifier: "en_US_POSIX")
    guard let sunrise = fmt.date(from: sunriseStr),
          let sunset  = fmt.date(from: sunsetStr)
    else { return nil }

    return SunEvent(sunrise: sunrise, sunset: sunset)
}

private func isToday(_ day: DailyForecast) -> Bool {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: day.timeZoneIdentifier) ?? .current
    return cal.isDateInToday(day.date)
}

private func parseAlertSections(_ text: String) -> [(String, String)] {
    // NWS structured alerts use "* LABEL..." bullet format
    let pattern = "\\*\\s*([A-Z][A-Z ]+?)\\.\\.\\.(.*?)(?=\\n\\s*\\*|\\z)"
    guard let regex = try? NSRegularExpression(
        pattern: pattern,
        options: [.dotMatchesLineSeparators]
    ) else { return [] }

    let range = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, range: range)
    guard !matches.isEmpty else { return [] }

    return matches.compactMap { match in
        guard let headerRange = Range(match.range(at: 1), in: text),
              let bodyRange   = Range(match.range(at: 2), in: text)
        else { return nil }
        let header = String(text[headerRange])
            .trimmingCharacters(in: .whitespaces)
        let body = String(text[bodyRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return (header, body)
    }
}

#Preview {
    ContentView(selectedID: .constant("current"))
        .environment(LocationStore())
        .environment(LocationManager())
}
