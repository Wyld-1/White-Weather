//
//  ContentView.swift
//  NOAA Weather

import SwiftUI
import Combine
import UIKit
internal import _LocationEssentials

// MARK: - Root

struct ContentView: View {
    @Environment(LocationStore.self) private var store
    @Environment(LocationManager.self) private var locationManager
    // AnyHashable so we can hold either UUID or the String "add"
    @State private var selectedTab: AnyHashable = AnyHashable(-1)

    // Total page count: 1 (GPS) + saved + 1 (add)
    private var pageCount: Int { 1 + store.saved.count + 1 }

    // Current page index (0-based)
    private var currentIndex: Int {
        if selectedTab == AnyHashable(-1) { return 0 }
        if selectedTab == AnyHashable("add") { return pageCount - 1 }
        if let idx = store.saved.firstIndex(where: { AnyHashable($0.id) == selectedTab }) {
            return idx + 1
        }
        return 0
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                LocationPageView(savedLocation: nil)
                    .tag(AnyHashable(-1))

                ForEach(store.saved) { loc in
                    LocationPageView(savedLocation: loc)
                        .tag(AnyHashable(loc.id))
                }

                AddLocationPage(onAdded: {
                    if let newest = store.saved.last {
                        selectedTab = AnyHashable(newest.id)
                    }
                })
                .tag(AnyHashable("add"))
            }
            .tabViewStyle(.page(indexDisplayMode: .never))  // hide system dots
            .ignoresSafeArea()

            // Custom page dots
            PageDotsView(
                count: pageCount,
                currentIndex: currentIndex
            )
            .padding(.bottom, 8)
        }
        .onAppear { locationManager.requestLocation() }
    }
}

// MARK: - Custom Page Dots

struct PageDotsView: View {
    let count: Int
    let currentIndex: Int

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { i in
                if i == 0 {
                    Image(systemName: "location.fill")
                        .font(.system(size: i == currentIndex ? 14 : 10))
                        .foregroundStyle(i == currentIndex ? .white : .white.opacity(0.45))
                        .animation(.easeInOut(duration: 0.2), value: currentIndex)
                } else if i == count - 1 {
                    Image(systemName: "plus")
                        .font(.system(size: i == currentIndex ? 13 : 9, weight: .semibold))
                        .foregroundStyle(i == currentIndex ? .white : .white.opacity(0.45))
                        .animation(.easeInOut(duration: 0.2), value: currentIndex)
                } else {
                    Circle()
                        .fill(i == currentIndex ? .white : .white.opacity(0.45))
                        .frame(width: i == currentIndex ? 10 : 8,
                               height: i == currentIndex ? 10 : 8)
                        .animation(.easeInOut(duration: 0.2), value: currentIndex)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.black.opacity(0.45), in: Capsule())
    }
}

// MARK: - Add Location Page

struct AddLocationPage: View {
    @Environment(LocationStore.self) private var store
    var onAdded: (() -> Void)? = nil
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGray6), Color(.systemBackground)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                // Blue + button
                Button { showSearch = true } label: {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 72, height: 72)
                        Image(systemName: "plus")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)

                Text("Add a Location")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("City, zip code, or ski resort")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)

                Spacer()
            }
        }
        .sheet(isPresented: $showSearch) {
            LocationSearchView(onAdded: onAdded)
                .environment(store)
        }
    }
}

struct ProgressLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white).scaleEffect(1.5)
            Text(text).foregroundStyle(.white.opacity(0.7)).font(.system(size: 14))
        }
    }
}

// MARK: - Weather Content (pure VStack, no scroll — scroll lives in LocationPageView)

struct WeatherContentView: View {
    let viewModel: WeatherViewModel
    @Binding var selectedDay: DailyForecast?

    var body: some View {
        VStack(spacing: 12) {
            CurrentConditionsHeader(
                locationName: viewModel.locationName,
                current: viewModel.current,
                high: viewModel.dailyHigh,
                low: viewModel.dailyLow
            )
            .padding(.top, 60).padding(.bottom, 12)

            if !viewModel.hourly.isEmpty {
                HourlyCard(hours: viewModel.hourly, sunEvent: viewModel.sunEvent)
                    .padding(.horizontal, 16)
            }

            if !viewModel.daily.isEmpty {
                DailyCard(
                    days: viewModel.daily,
                    globalLow: viewModel.globalLow,
                    globalHigh: viewModel.globalHigh,
                    onSelect: { selectedDay = $0 }
                ).padding(.horizontal, 16)
            }

            if let cur = viewModel.current {
                WindCard(
                    windSpeed: cur.windSpeed,
                    windGusts: cur.windGusts,
                    windDegrees: cur.windDirection,
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
    }
}

// MARK: - Current Header

struct CurrentConditionsHeader: View {
    let locationName: String
    let current: CurrentConditions?
    let high: Double?
    let low: Double?

    var body: some View {
        VStack(spacing: 4) {
            Text(locationName.isEmpty ? "—" : locationName)
                .font(.system(size: 28, weight: .medium)).foregroundStyle(.white).shadow(radius: 4)
            Text(current.map { "\(Int($0.temperature.rounded()))°" } ?? "—")
                .font(.system(size: 96, weight: .thin)).foregroundStyle(.white).shadow(radius: 6)
            Text(current?.description ?? "")
                .font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 3)
            if let h = high, let l = low {
                Text("H:\(Int(h.rounded()))°  L:\(Int(l.rounded()))°")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.85)).shadow(radius: 3)
            } else if let l = low {
                Text("L:\(Int(l.rounded()))°")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.85)).shadow(radius: 3)
            }
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 20)
    }
}

// MARK: - Hourly Card

struct HourlyCard: View {
    let hours: [HourlyForecast]
    var sunEvent: SunEvent? = nil

    /// Build a merged timeline of hourly slots + sun events, sorted by time
    private var timeline: [HourlySlot] {
        var slots: [HourlySlot] = hours.map { .forecast($0) }
        if let sun = sunEvent {
            let start = hours.first?.time ?? Date()
            let end   = hours.last?.time  ?? Date()

            // Check today's events
            if sun.sunrise > start && sun.sunrise <= end { slots.append(.sunrise(sun.sunrise)) }
            if sun.sunset  > start && sun.sunset  <= end { slots.append(.sunset(sun.sunset)) }

            // Also check tomorrow's sunrise/sunset (common when viewing evening hourly)
            if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: sun.sunrise) {
                if tomorrow > start && tomorrow <= end { slots.append(.sunrise(tomorrow)) }
            }
            if let tomorrowSet = Calendar.current.date(byAdding: .day, value: 1, to: sun.sunset) {
                if tomorrowSet > start && tomorrowSet <= end { slots.append(.sunset(tomorrowSet)) }
            }
        }
        return slots.sorted { $0.time < $1.time }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(icon: "clock", title: "HOURLY FORECAST")
                Divider().background(.white.opacity(0.2)).padding(.horizontal, 16)
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
    private var timeLabel: String {
        let f = DateFormatter(); f.dateFormat = "h:mma"
        return f.string(from: time).lowercased()
    }
    var body: some View {
        VStack(spacing: 6) {
            Text(timeLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Image(systemName: isRise ? "sunrise.fill" : "sunset.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 22))
                .frame(height: 26)
            Text(isRise ? "Sunrise" : "Sunset")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(width: 62)
        .padding(.vertical, 6)
    }
}

struct HourlyCell: View {
    let hour: HourlyForecast
    var timeLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(hour.time),
           cal.component(.hour, from: hour.time) == cal.component(.hour, from: Date()) { return "Now" }
        let f = DateFormatter(); f.dateFormat = "ha"
        return f.string(from: hour.time).lowercased()
    }
    var isDay: Bool { let h = Calendar.current.component(.hour, from: hour.time); return h >= 6 && h < 20 }

    var body: some View {
        VStack(spacing: 6) {
            Text(timeLabel).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            Image(systemName: wmoSFSymbol(code: hour.weatherCode, isDay: isDay))
                .symbolRenderingMode(.multicolor).font(.system(size: 22)).frame(height: 26)
            Text("\(Int(hour.temperature.rounded()))°")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
        }
        .frame(width: 58).padding(.vertical, 6)
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
                Divider().background(.white.opacity(0.2)).padding(.horizontal, 16)
                VStack(spacing: 0) {
                    ForEach(Array(days.prefix(7).enumerated()), id: \.offset) { idx, day in
                        Button { onSelect(day) } label: {
                            DailyRow(day: day, globalLow: globalLow, globalHigh: globalHigh)
                        }
                        .buttonStyle(.plain)
                        if idx < min(days.count, 7) - 1 {
                            Divider().background(.white.opacity(0.15)).padding(.leading, 52)
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

    var body: some View {
        HStack(spacing: 0) {
            // Day name — fixed width
            Text(day.dayName)
                .font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
                .frame(width: 48, alignment: .leading)

            // Symbol: prefer NOAA condition string, fall back to WMO code
            let sym = day.noaaCondition.isEmpty
                ? wmoSFSymbol(code: day.weatherCode, isDay: true)
                : (noaaSFSymbol(from: day.noaaCondition, isDay: true).isEmpty
                    ? wmoSFSymbol(code: day.weatherCode, isDay: true)
                    : noaaSFSymbol(from: day.noaaCondition, isDay: true))
            Image(systemName: sym)
                .symbolRenderingMode(.multicolor).font(.system(size: 22))
                .frame(width: 28)
                .padding(.leading, 8)

            // Spacer between symbol and precip detail
            Spacer().frame(width: 10)

            // Precip sub-symbol + % — only ≥ 20%
            if day.precipProbability >= 20 {
                HStack(spacing: 3) {
                    Image(systemName: wmoPrecipSymbol(code: day.weatherCode))
                        .symbolRenderingMode(.multicolor).font(.system(size: 11))
                    Text("\(day.precipProbability)%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.4, green: 0.8, blue: 1.0))
                }
                .frame(width: 48, alignment: .leading)
            } else {
                Spacer().frame(width: 48)
            }

            Spacer()

            if let snow = day.snowAccumulation {
                // Accumulation day: ❄ < 1"  14° | 37°
                HStack(spacing: 6) {
                    Image(systemName: "snowflake")
                        .font(.system(size: 13))
                        .foregroundStyle(.cyan)
                    Text(snow)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.cyan)
                        .lineLimit(1)
                    Text("\(day.low.map { "\(Int($0.rounded()))°" } ?? "—") | \(day.high.map { "\(Int($0.rounded()))°" } ?? "—")")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                }
            } else {
                // Normal day: low ——bar—— high
                Text(day.low.map { "\(Int($0.rounded()))°" } ?? "—")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .frame(width: 36, alignment: .trailing)

                if let h = day.high, let l = day.low {
                    TempRangeBar(low: l, high: h, globalLow: globalLow, globalHigh: globalHigh)
                        .frame(width: 72, height: 4).padding(.horizontal, 6)
                } else {
                    Spacer().frame(width: 84)
                }

                Text(day.high.map { "\(Int($0.rounded()))°" } ?? "—")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 36, alignment: .leading)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.3))
                .padding(.leading, 4)
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
                    .frame(width: max(6, (e - s) * w), height: 4)
                    .offset(x: s * w)
            }
        }
    }
}

// MARK: - Wind Card

struct WindCard: View {
    let windSpeed: Double
    let windGusts: Double
    let windDegrees: Double
    let windDirectionLabel: String

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(icon: "wind", title: "WIND")
                Divider().background(.white.opacity(0.2)).padding(.horizontal, 16)

                HStack(alignment: .center, spacing: 20) {
                    // Stats
                    VStack(alignment: .leading, spacing: 0) {
                        WindStatRow(label: "Wind",      value: "\(Int(windSpeed.rounded())) mph")
                        Divider().background(.white.opacity(0.12))
                        WindStatRow(label: "Gusts",     value: "\(Int(windGusts.rounded())) mph")
                        Divider().background(.white.opacity(0.12))
                        WindStatRow(label: "Direction", value: "\(Int(windDegrees.rounded()))° \(windDirectionLabel)")
                    }
                    .frame(maxWidth: .infinity)

                    // Compass
                    CompassRose(degrees: windDegrees)
                        .frame(width: 110, height: 110)
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
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.vertical, 11)
    }
}

struct CompassRose: View {
    let degrees: Double
    // Needle points the direction wind is blowing TO (opposite of meteorological "from")
    private var needleDeg: Double { (degrees + 180).truncatingRemainder(dividingBy: 360) }

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy = size.height / 2
            let r  = min(cx, cy) - 2

            // ── Tick ring ──────────────────────────────────────────────
            for i in 0..<72 {
                let angle = Double(i) * 5.0 * .pi / 180
                let isMajor = i % 18 == 0   // N/E/S/W
                let isMed   = i % 9 == 0 && !isMajor  // NE/SE/SW/NW
                let tickLen: CGFloat = isMajor ? 8 : isMed ? 5 : 3
                let opacity: CGFloat = isMajor ? 0.6 : isMed ? 0.35 : 0.18
                let outer = r
                let inner = r - tickLen
                let x1 = cx + CGFloat(cos(angle - .pi/2)) * outer
                let y1 = cy + CGFloat(sin(angle - .pi/2)) * outer
                let x2 = cx + CGFloat(cos(angle - .pi/2)) * inner
                let y2 = cy + CGFloat(sin(angle - .pi/2)) * inner
                var tick = Path()
                tick.move(to: CGPoint(x: x1, y: y1))
                tick.addLine(to: CGPoint(x: x2, y: y2))
                ctx.stroke(tick, with: .color(.white.opacity(opacity)),
                           style: StrokeStyle(lineWidth: isMajor ? 1.5 : 1, lineCap: .round))
            }

            // ── Needle ─────────────────────────────────────────────────
            // Long white line from center toward compass edge (direction wind goes TO)
            let needleRad = (needleDeg - 90) * .pi / 180
            let needleLen = r - 10   // stops just inside tick ring
            let tailLen: CGFloat = 12  // short tail opposite direction

            // Tail (dimmer)
            let tailRad = needleRad + .pi
            var tail = Path()
            tail.move(to: CGPoint(x: cx, y: cy))
            tail.addLine(to: CGPoint(x: cx + CGFloat(cos(tailRad)) * tailLen,
                                      y: cy + CGFloat(sin(tailRad)) * tailLen))
            ctx.stroke(tail, with: .color(.white.opacity(0.3)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // Needle shaft
            var needle = Path()
            needle.move(to: CGPoint(x: cx, y: cy))
            needle.addLine(to: CGPoint(x: cx + CGFloat(cos(needleRad)) * needleLen,
                                        y: cy + CGFloat(sin(needleRad)) * needleLen))
            ctx.stroke(needle, with: .color(.white),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))

            // Needle tip triangle
            let tipX = cx + CGFloat(cos(needleRad)) * needleLen
            let tipY = cy + CGFloat(sin(needleRad)) * needleLen
            let perpRad = needleRad + .pi / 2
            let hw: CGFloat = 5
            let backDist: CGFloat = 10
            var head = Path()
            head.move(to: CGPoint(x: tipX, y: tipY))
            head.addLine(to: CGPoint(
                x: tipX + CGFloat(cos(needleRad + .pi)) * backDist + CGFloat(cos(perpRad)) * hw,
                y: tipY + CGFloat(sin(needleRad + .pi)) * backDist + CGFloat(sin(perpRad)) * hw
            ))
            head.addLine(to: CGPoint(
                x: tipX + CGFloat(cos(needleRad + .pi)) * backDist - CGFloat(cos(perpRad)) * hw,
                y: tipY + CGFloat(sin(needleRad + .pi)) * backDist - CGFloat(sin(perpRad)) * hw
            ))
            head.closeSubpath()
            ctx.fill(head, with: .color(.white))

            // Center dot
            let dotR: CGFloat = 4
            ctx.fill(Path(ellipseIn: CGRect(x: cx - dotR, y: cy - dotR,
                                            width: dotR*2, height: dotR*2)),
                     with: .color(.white))
        }
        .overlay {
            // Cardinal labels
            ZStack {
                let labelR: CGFloat = 32
                ForEach([("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)], id: \.0) { label, deg in
                    let rad = (deg - 90) * .pi / 180
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .offset(x: CGFloat(cos(rad)) * labelR,
                                y: CGFloat(sin(rad)) * labelR)
                }
            }
        }
    }
}

// MARK: - Sun Card

struct SunCard: View {
    let sunEvent: SunEvent
    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(icon: sunEvent.nextIsRise ? "sunrise.fill" : "sunset.fill",
                           title: sunEvent.nextIsRise ? "SUNRISE" : "SUNSET")
                Divider().background(.white.opacity(0.2)).padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 8) {
                    Text(fmt.string(from: sunEvent.nextTime))
                        .font(.system(size: 28, weight: .thin)).foregroundStyle(.white)

                    // Elliptical sun arc — fills the card width nicely
                    SunArcView(sunrise: sunEvent.sunrise, sunset: sunEvent.sunset)
                        .frame(height: 70)

                    Text(sunEvent.nextIsRise
                         ? "Sunset \(fmt.string(from: sunEvent.sunset))"
                         : "Sunrise \(fmt.string(from: sunEvent.sunrise))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }
}

struct SunArcView: View {
    let sunrise: Date
    let sunset: Date

    private var progress: Double {
        let now = Date()
        let total = sunset.timeIntervalSince(sunrise)
        guard total > 0 else { return 0 }
        return max(0, min(1.1, now.timeIntervalSince(sunrise) / total))
    }

    private func ellipsePoint(t: Double, cx: CGFloat, base: CGFloat,
                               rx: CGFloat, ry: CGFloat) -> CGPoint {
        let angle = Double.pi - t * Double.pi
        return CGPoint(x: cx + CGFloat(cos(angle)) * rx,
                       y: base - CGFloat(sin(angle)) * ry)
    }

    private func ellipsePath(from t0: Double, to t1: Double,
                              cx: CGFloat, base: CGFloat,
                              rx: CGFloat, ry: CGFloat) -> Path {
        var p = Path()
        let steps = 60
        for i in 0...steps {
            let t = t0 + (t1 - t0) * Double(i) / Double(steps)
            let pt = ellipsePoint(t: t, cx: cx, base: base, rx: rx, ry: ry)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    var body: some View {
        GeometryReader { geo in
            let w    = geo.size.width
            let h    = geo.size.height
            let hPad: CGFloat = 10
            let base = h - 6
            let rx   = (w - hPad * 2) / 2
            let ry   = h - 6 - 2
            let cx   = w / 2
            let prog = progress.clamped(to: 0...1)
            let dotPt = ellipsePoint(t: prog, cx: cx, base: base, rx: rx, ry: ry)

            ZStack {
                // Horizon line
                Path { p in
                    p.move(to:    CGPoint(x: hPad, y: base))
                    p.addLine(to: CGPoint(x: w - hPad, y: base))
                }
                .stroke(Color.white.opacity(0.2), lineWidth: 1)

                // Full ellipse arc — dimmed track
                ellipsePath(from: 0, to: 1, cx: cx, base: base, rx: rx, ry: ry)
                    .stroke(Color.white.opacity(0.15),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))

                // Elapsed portion — bright orange→yellow
                if prog > 0 {
                    ellipsePath(from: 0, to: prog, cx: cx, base: base, rx: rx, ry: ry)
                        .stroke(
                            LinearGradient(colors: [.orange, .yellow],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                }

                // Sun dot
                Circle()
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
                    .shadow(color: .yellow.opacity(0.9), radius: 5)
                    .position(dotPt)
            }
        }
    }
}

// MARK: - Day Detail Sheet

struct DayDetailSheet: View {
    let day: DailyForecast
    let globalLow: Double
    let globalHigh: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Header
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(day.fullDayName).font(.system(size: 24, weight: .semibold))
                                HStack(spacing: 16) {
                                    if let h = day.high {
                                        Label("\(Int(h.rounded()))°", systemImage: "arrow.up")
                                            .font(.system(size: 17)).foregroundStyle(.orange)
                                    }
                                    if let l = day.low {
                                        Label("\(Int(l.rounded()))°", systemImage: "arrow.down")
                                            .font(.system(size: 17)).foregroundStyle(.cyan)
                                    }
                                }
                                Text(day.shortForecast)
                                    .font(.system(size: 15)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            // Use NOAA symbol if available
                            let detailSym: String = {
                                if day.noaaCondition.isEmpty { return wmoSFSymbol(code: day.weatherCode, isDay: true) }
                                let s = noaaSFSymbol(from: day.noaaCondition, isDay: true)
                                return s.isEmpty ? wmoSFSymbol(code: day.weatherCode, isDay: true) : s
                            }()
                            Image(systemName: detailSym)
                                .symbolRenderingMode(.multicolor).font(.system(size: 48))
                        }
                        .padding(.horizontal, 20).padding(.top, 8)

                        // Interactive temp graph
                        if !day.hourlyTemps.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("TEMPERATURE")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                InteractiveTempGraph(
                                    points: day.hourlyTemps,
                                    globalLow: globalLow,
                                    globalHigh: globalHigh
                                )
                                .frame(height: 160)
                            }
                            .padding(16)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 16)
                        }

                        // NOAA prose — strip leading "DayName: " prefix if present
                        if !day.detailedForecast.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                // Snow accumulation callout
                                if let snow = day.snowAccumulation {
                                    HStack(spacing: 8) {
                                        Image(systemName: "snowflake").foregroundStyle(.cyan)
                                        Text("Snow accumulation: \(snow)")
                                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.cyan)
                                    }
                                }
                                Text(strippedForecast(day.detailedForecast, dayName: day.fullDayName))
                                    .font(.system(size: 15)).foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(16)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 16)
                        }

                        // Wind + Precip side by side
                        HStack(spacing: 12) {
                            HStack(spacing: 10) {
                                Image(systemName: "wind").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("WIND").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    Text("\(day.windDirection) \(Int(day.windSpeed.rounded())) mph")
                                        .font(.system(size: 15))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))

                            if day.precipProbability > 0 {
                                HStack(spacing: 10) {
                                    Image(systemName: wmoPrecipSymbol(code: day.weatherCode))
                                        .symbolRenderingMode(.multicolor).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("PRECIP").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                        Text("\(day.precipProbability)%")
                                            .font(.system(size: 15))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                        .padding(.horizontal, 16)

                        Spacer(minLength: 32)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Interactive Temperature Graph

struct InteractiveTempGraph: View {
    let points: [HourlyTempPoint]
    let globalLow: Double
    let globalHigh: Double

    @State private var dragX: CGFloat? = nil
    @GestureState private var isDragging = false

    // Layout constants
    private let topPad:    CGFloat = 28   // room for temp label above curve
    private let bottomPad: CGFloat = 20   // room for hour label below axis
    private let sidePad:   CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let plotH = h - topPad - bottomPad
            let plotW = w - 2 * sidePad
            let range = max(globalHigh - globalLow, 1)

            // Convert data → screen coords
            let pts: [(CGFloat, CGFloat)] = points.enumerated().map { idx, p in
                let x = sidePad + plotW * CGFloat(idx) / CGFloat(max(points.count - 1, 1))
                let y = topPad + plotH * CGFloat(1 - (p.temperature - globalLow) / range)
                return (x, y)
            }

            // Find hovered index from dragX
            let hovIdx: Int? = dragX.map { dx in
                let clamped = max(sidePad, min(w - sidePad, dx))
                let frac = (clamped - sidePad) / plotW
                return max(0, min(points.count - 1, Int((frac * CGFloat(points.count - 1)).rounded())))
            }

            ZStack(alignment: .topLeading) {

                // ── Grid lines ──────────────────────────────────────────
                let gridTemps = strideTemps(low: globalLow, high: globalHigh, steps: 4)
                ForEach(gridTemps, id: \.self) { temp in
                    let y = topPad + plotH * CGFloat(1 - (temp - globalLow) / range)
                    Path { p in
                        p.move(to: CGPoint(x: sidePad, y: y))
                        p.addLine(to: CGPoint(x: w - sidePad, y: y))
                    }
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)

                    Text("\(Int(temp.rounded()))°")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .position(x: sidePad - 2, y: y)
                }

                // ── Fill under curve ────────────────────────────────────
                if pts.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: pts[0].0, y: topPad + plotH))
                        path.addLine(to: CGPoint(x: pts[0].0, y: pts[0].1))
                        addCurve(to: &path, pts: pts)
                        path.addLine(to: CGPoint(x: pts.last!.0, y: topPad + plotH))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(
                        colors: [Color.orange.opacity(0.3), Color.cyan.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    ))

                    // ── Line ──────────────────────────────────────────────
                    Path { path in
                        path.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
                        addCurve(to: &path, pts: pts)
                    }
                    .stroke(Color.orange.opacity(0.85), lineWidth: 2)
                }

                // ── Hour labels along bottom ────────────────────────────
                ForEach(Array(points.enumerated()), id: \.offset) { idx, p in
                    // Only label every 3 hours to avoid crowding
                    if idx % 3 == 0 {
                        Text(hourLabel(p.time))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .position(x: pts[idx].0, y: h - bottomPad / 2)
                    }
                }

                // ── Hover scrubber ──────────────────────────────────────
                if let idx = hovIdx, idx < pts.count {
                    let px = pts[idx].0
                    let py = pts[idx].1
                    let temp = points[idx].temperature

                    // Vertical rule
                    Path { p in
                        p.move(to: CGPoint(x: px, y: topPad))
                        p.addLine(to: CGPoint(x: px, y: topPad + plotH))
                    }
                    .stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    // Dot on curve
                    Circle().fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .position(x: px, y: py)
                    Circle().fill(Color.white.opacity(0.9))
                        .frame(width: 4, height: 4)
                        .position(x: px, y: py)

                    // Temp bubble
                    let bubbleX = min(max(px, 28), w - 28)
                    Text("\(Int(temp.rounded()))°")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: bubbleX, y: py - 20)

                    // Time bubble
                    Text(hourLabel(points[idx].time))
                        .font(.system(size: 11))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: bubbleX, y: topPad - 14)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in dragX = v.location.x }
                    .onEnded   { _ in
                        withAnimation(.easeOut(duration: 0.3)) { dragX = nil }
                    }
            )
        }
    }

    // Smooth bezier through all points
    private func addCurve(to path: inout Path, pts: [(CGFloat, CGFloat)]) {
        for i in 1..<pts.count {
            let cp1 = CGPoint(x: (pts[i-1].0 + pts[i].0) / 2, y: pts[i-1].1)
            let cp2 = CGPoint(x: (pts[i-1].0 + pts[i].0) / 2, y: pts[i].1)
            path.addCurve(to: CGPoint(x: pts[i].0, y: pts[i].1), control1: cp1, control2: cp2)
        }
    }

    // Nice round grid temps — 4 lines between low and high
    private func strideTemps(low: Double, high: Double, steps: Int) -> [Double] {
        let step = ((high - low) / Double(steps)).rounded()
        guard step > 0 else { return [] }
        let start = (low / step).rounded(.up) * step
        var temps: [Double] = []
        var t = start
        while t <= high {
            temps.append(t)
            t += step
        }
        return temps
    }

    private func hourLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "ha"
        return f.string(from: d).lowercased()
    }
}

// MARK: - Glass Card / Card Header / Error View

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial).opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CardHeader: View {
    let icon: String; let title: String
    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }
}

struct ErrorView: View {
    let message: String; let retry: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(.yellow)
            Text(message).font(.system(size: 15)).foregroundStyle(.white)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Button("Try Again") { retry() }.buttonStyle(.bordered).tint(.white)
        }
    }
}

// MARK: - Helpers

/// Strips "DayName: " or "Tonight: " prefix NOAA prepends to detailed forecast strings.
func strippedForecast(_ text: String, dayName: String) -> String {
    // Handle multi-sentence prose: "Monday: sentence. Tuesday Night: sentence."
    // Strip each period-name prefix before each sentence.
    let periodNames = [
        "This Afternoon", "Tonight", "Overnight",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
        "Monday Night", "Tuesday Night", "Wednesday Night", "Thursday Night",
        "Friday Night", "Saturday Night", "Sunday Night",
        dayName
    ]
    var result = text
    for name in periodNames {
        result = result.replacingOccurrences(of: name + ": ", with: "",
                                             options: .caseInsensitive)
    }
    return result.trimmingCharacters(in: .whitespaces)
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    ContentView()
        .environment(LocationStore())
        .environment(LocationManager())
}
