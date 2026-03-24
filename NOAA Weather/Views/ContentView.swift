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
    @Binding var selectedID: String?

    // Helper to calculate total dots (Current + Saved + Add Page)
    private var pageCount: Int { 1 + store.saved.count + 1 }

    // Helper to find which dot should be active based on the String ID
    private var currentIndex: Int {
        if selectedID == "current" { return 0 }
        if selectedID == "add" { return pageCount - 1 }
        if let idString = selectedID,
           let idx = store.saved.firstIndex(where: { $0.id.uuidString == idString }) {
            return idx + 1
        }
        return 0
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedID) {
                // Current Location Page
                LocationPageView(savedLocation: nil)
                    .tag("current" as String?)

                // Saved Location Pages
                ForEach(store.saved) { loc in
                    LocationPageView(savedLocation: loc)
                        .tag(loc.id.uuidString as String?)
                }

                // Add Location Page
                AddLocationPage(onAdded: {
                    if let newest = store.saved.last {
                        selectedID = newest.id.uuidString
                    }
                })
                .tag("add" as String?)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            PageDotsView(count: pageCount, currentIndex: currentIndex)
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
                        .font(.system(size: 11))
                        .foregroundStyle(i == currentIndex ? .white : .white.opacity(0.45))
                        .animation(.easeInOut(duration: 0.2), value: currentIndex)
                } else if i == count - 1 {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(i == currentIndex ? .white : .white.opacity(0.45))
                        .animation(.easeInOut(duration: 0.2), value: currentIndex)
                } else {
                    Circle()
                        .fill(i == currentIndex ? .white : .white.opacity(0.45))
                        .frame(width: 10, height: 10)
                        .animation(.easeInOut(duration: 0.2), value: currentIndex)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.black.opacity(0.6), in: Capsule())
    }
}

// MARK: - Add Location Page

struct AddLocationPage: View {
    @Environment(LocationStore.self) private var store
    var onAdded: (() -> Void)? = nil
    @State private var showSearch = false
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            VideoBackgroundView(videoName: "sun").ignoresSafeArea()
            RadialGradient(stops: [.init(color: .blue.opacity(0.4), location: 0),
                                   .init(color: .black.opacity(0.7), location: 0.8)],
                           center: .top, startRadius: 10, endRadius: 600).ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer()
                
                Group {
                    if #available(iOS 26.0, *) {
                        Button(action: {
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
                    Text("Add Location").font(.system(size: 32, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text("Track your local mountains, \ncities, and favorites.").font(.system(size: 17)).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: false)) { isAnimating = true } }
        .sheet(isPresented: $showSearch) { LocationSearchView(onAdded: onAdded).environment(store) }
    }
}

// MARK: - Weather Content

struct WeatherContentView: View {
    let viewModel: WeatherViewModel
    @Binding var selectedDay: DailyForecast?

    var body: some View {
        VStack(spacing: 12) {
            CurrentConditionsHeader(
                locationName: viewModel.locationName,
                current: viewModel.current,
                high: viewModel.daily.first?.high,
                low: viewModel.daily.first?.low
            )
            .padding(.top, 60).padding(.bottom, 4)

            // Versatile warning slot
            Group {
                if let gusts = viewModel.current?.windGusts, gusts >= 40 {
                    WeatherAlertBanner(
                        title: viewModel.isSkiResort ? "Wind Hold Risk": "High Wind Alert",
                        message: "Gusts up to \(Int(gusts.rounded())) mph",
                        tintColor: viewModel.isSkiResort ? .red: .yellow,
                        warningSymbol: "wind.circle.fill"
                    )
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                // Future warnings can be 'else if' or additional 'if' blocks here
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
                    if let today = viewModel.daily.first { selectedDay = today }
                }
            }

            if !viewModel.daily.isEmpty {
                DailyCard(
                    days: viewModel.daily,
                    globalLow: viewModel.globalLow,
                    globalHigh: viewModel.globalHigh,
                    onSelect: { day in
                        self.selectedDay = day
                    }
                ).padding(.horizontal, 16)
            }

            if let cur = viewModel.current {
                WindCard(
                    windSpeed: cur.windSpeed,
                    windGusts: cur.windGusts,
                    windDegrees: cur.windDirection,
                    windDirectionLabel: cur.windDirectionLabel
                ).padding(.horizontal, 16)
            }
            
            if let sun = viewModel.sunEvent {
                SunCard(sunEvent: sun).padding(.horizontal, 16)
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
            if locationName == "My Location" {
                HStack {
                    Image(systemName: "location.fill")
                        .font(.system(size: 20, weight: .medium)).foregroundStyle(.white).shadow(radius: 4)
                    
                    Text(locationName.isEmpty ? "—" : locationName)
                        .font(.system(size: 28, weight: .medium)).foregroundStyle(.white).shadow(radius: 4)
                }
            }
            else {
                Text(locationName.isEmpty ? "—" : locationName)
                    .font(.system(size: 28, weight: .medium)).foregroundStyle(.white).shadow(radius: 4)
            }
            
            Text(current.map { "\(Int($0.temperature.rounded()))°" } ?? "—")
                .font(.system(size: 96, weight: .thin)).foregroundStyle(.white).shadow(radius: 6)
            Text(current?.description ?? "")
                .font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 3)
            
            if let h = high, let l = low {
                Text("H:\(Int(h.rounded()))°  L:\(Int(l.rounded()))°")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.85)).shadow(radius: 3)
            }
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 20)
    }
}

// MARK: Alert Card

struct WeatherAlertBanner: View {
    let title: String
    let message: String
    let tintColor: Color
    let warningSymbol : String
    
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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tintColor.opacity(0.6), lineWidth: 3)
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
                    
                    Divider().background(.white.opacity(0.15)).padding(.horizontal, 16)
                }

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
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            Image(systemName: isRise ? "sunrise.fill" : "sunset.fill")
                .symbolRenderingMode(.multicolor).font(.system(size: 22)).frame(height: 26)
            Text(isRise ? "Sunrise" : "Sunset")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
        }
        .frame(width: 62).padding(.vertical, 6)
    }
}

struct HourlyCell: View {
    let hour: HourlyForecast
    var timeLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(hour.time), cal.component(.hour, from: hour.time) == cal.component(.hour, from: Date()) { return "Now" }
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
                            Divider().background(.white.opacity(0.15)).padding(.horizontal, 16)
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
    
    private var dayName: String {
        let f = DateFormatter(); f.dateFormat = "EEE"
        return f.string(from: day.date)
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(Calendar.current.isDateInToday(day.date) ? "Today" : dayName)
                .font(.system(size: 17, weight: .medium)).foregroundStyle(.white).frame(width: 52, alignment: .leading)

            HStack(spacing: -4) {
                Image(systemName: day.daySymbol).symbolRenderingMode(.multicolor).font(.system(size: 22)).frame(width: 28)
                if let nightSym = day.nightSymbol {
                    Image(systemName: nightSym).symbolRenderingMode(.monochrome).foregroundStyle(.white.opacity(0.4)).font(.system(size: 16)).offset(y: 4).offset(x: 8)
                }
            }.frame(width: 60, alignment: .leading)

            if day.precipProbability >= 20 {
                HStack(spacing: 3) {
                    Image(systemName: day.precipType == .rain ? "drop.fill" : "snowflake").symbolRenderingMode(.multicolor).font(.system(size: 11)).foregroundStyle(.cyan)
                    Text("\(day.precipProbability)%").font(.system(size: 12, weight: .medium)).foregroundStyle(Color(red: 0.4, green: 0.8, blue: 1.0))
                }.frame(width: 48, alignment: .leading)
            } else { Spacer().frame(width: 48) }

            Spacer()

            if day.accumulation.hasAccumulation {
                HStack(spacing: 6) {
                    Image(systemName: day.precipType == .rain ? "drop.fill" : "snowflake")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.cyan)
                    Text(day.accumulation.displayString)
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.cyan)
                    Text("\(Int(day.low.rounded()))° | \(Int(day.high.rounded()))°")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 60, alignment: .trailing)
                }
            } else {
                Text("\(Int(day.low.rounded()))°")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .frame(width: 36, alignment: .trailing)
                TempRangeBar(low: day.low, high: day.high, globalLow: globalLow, globalHigh: globalHigh)
                    .frame(width: 72, height: 8).padding(.horizontal, 6)
                Text("\(Int(day.high.rounded()))°")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 36, alignment: .leading)
            }
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.3)).padding(.leading, 6)
        }.padding(.horizontal, 16).padding(.vertical, 10)
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
                    VStack(alignment: .leading, spacing: 0) {
                        WindStatRow(label: "Wind",      value: "\(Int(windSpeed.rounded())) mph")
                        Divider().background(.white.opacity(0.12))
                        WindStatRow(label: "Gusts",     value: "\(Int(windGusts.rounded())) mph")
                        Divider().background(.white.opacity(0.12))
                        WindStatRow(label: "Direction", value: "\(Int(windDegrees.rounded()))° \(windDirectionLabel)")
                    }
                    .frame(maxWidth: .infinity)

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
            Text(label).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
            Spacer()
            Text(value).font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.vertical, 11)
    }
}

struct CompassRose: View {
    let degrees: Double
    private var needleDeg: Double { (degrees + 180).truncatingRemainder(dividingBy: 360) }

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy = size.height / 2
            let r  = min(cx, cy) - 2

            for i in 0..<72 {
                let angle = Double(i) * 5.0 * .pi / 180
                let isMajor = i % 18 == 0
                let isMed   = i % 9 == 0 && !isMajor
                let tickLen: CGFloat = isMajor ? 8 : isMed ? 5 : 3
                let opacity: CGFloat = isMajor ? 0.6 : isMed ? 0.35 : 0.18
                
                let x1 = cx + CGFloat(cos(angle - .pi/2)) * r
                let y1 = cy + CGFloat(sin(angle - .pi/2)) * r
                let x2 = cx + CGFloat(cos(angle - .pi/2)) * (r - tickLen)
                let y2 = cy + CGFloat(sin(angle - .pi/2)) * (r - tickLen)
                
                var tick = Path()
                tick.move(to: CGPoint(x: x1, y: y1))
                tick.addLine(to: CGPoint(x: x2, y: y2))
                ctx.stroke(tick, with: .color(.white.opacity(opacity)), style: StrokeStyle(lineWidth: isMajor ? 1.5 : 1, lineCap: .round))
            }

            let needleRad = (needleDeg - 90) * .pi / 180
            let needleLen = r - 10
            var needle = Path()
            needle.move(to: CGPoint(x: cx, y: cy))
            needle.addLine(to: CGPoint(x: cx + CGFloat(cos(needleRad)) * needleLen, y: cy + CGFloat(sin(needleRad)) * needleLen))
            ctx.stroke(needle, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            let dotR: CGFloat = 4
            ctx.fill(Path(ellipseIn: CGRect(x: cx - dotR, y: cy - dotR, width: dotR*2, height: dotR*2)), with: .color(.white))
        }
        .overlay {
            ZStack {
                let labelR: CGFloat = 32
                ForEach([("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)], id: \.0) { label, deg in
                    let rad = (deg - 90) * .pi / 180
                    Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        .offset(x: CGFloat(cos(rad)) * labelR, y: CGFloat(sin(rad)) * labelR)
                }
            }
        }
    }
}

// MARK: - Sun Card & Arc

struct SunCard: View {
    let sunEvent: SunEvent
    private let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                let sunEventTime = " — " + fmt.string(from: sunEvent.nextTime).prefix(while: { $0 != " " }) + fmt.string(from: sunEvent.nextTime).suffix(2)
                
                CardHeader(icon: sunEvent.nextIsRise ? "sunrise.fill" : "sunset.fill",
                           title: sunEvent.nextIsRise ? "SUNRISE" + sunEventTime : "SUNSET" + sunEventTime)
                Divider().background(.white.opacity(0.2)).padding(.horizontal, 16)

                
                VStack(alignment: .center, spacing: 16) {
                    
                    Spacer()

                    // The Thicker, Glowier Orbital Arc
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
            // Calculate a point on a circle that only spans the top 60 degrees (upper 1/3)
            let radius: CGFloat = w * 0.8 // Large radius for a shallow arc
            let center = CGPoint(x: w / 2, y: radius + 10) // Center is deep below the view
            
            // Angles: 240 to 300 degrees creates a shallow top-center arc
            let startAngle: Double = 240
            let endAngle: Double = 300
            let currentAngle = startAngle + (progress * (endAngle - startAngle))
            
            let sunPos = CGPoint(
                x: center.x + radius * cos(CGFloat(currentAngle) * .pi / 180),
                y: center.y + radius * sin(CGFloat(currentAngle) * .pi / 180)
            )
            
            ZStack {
                // 1. Background Path (Thick & Subtle)
                Path { p in
                    p.addArc(center: center, radius: radius, startAngle: .degrees(startAngle), endAngle: .degrees(endAngle), clockwise: false)
                }
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 6, lineCap: .round))

                // 2. Active Path Glow (Inner Bloom)
                Path { p in
                    p.addArc(center: center, radius: radius, startAngle: .degrees(startAngle), endAngle: .degrees(currentAngle), clockwise: false)
                }
                .stroke(
                    LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .blur(radius: 3)

                // 3. Active Path (Core)
                Path { p in
                    p.addArc(center: center, radius: radius, startAngle: .degrees(startAngle), endAngle: .degrees(currentAngle), clockwise: false)
                }
                .stroke(
                    LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )

                // 4. The Sun Orb (High Glow)
                ZStack {
                    Circle() // Deep Bloom
                        .fill(Color.orange)
                        .frame(width: 25, height: 25)
                        .blur(radius: 7)
                    
                    Circle() // Core
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

struct DayDetailSheet: View {
    let day: DailyForecast
    let globalLow: Double
    let globalHigh: Double
    @Environment(\.dismiss) private var dismiss
    
    private var fullDayName: String {
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return f.string(from: day.date)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(fullDayName).font(.system(size: 24, weight: .semibold))
                                HStack(spacing: 16) {
                                    Label("\(Int(day.high.rounded()))°", systemImage: "arrow.up")
                                        .font(.system(size: 17)).foregroundStyle(.orange)
                                    Label("\(Int(day.low.rounded()))°", systemImage: "arrow.down")
                                        .font(.system(size: 17)).foregroundStyle(.cyan)
                                }
                            }
                            Spacer()
                            Image(systemName: day.daySymbol).symbolRenderingMode(.multicolor).font(.system(size: 48))
                        }
                        .padding(.horizontal, 20).padding(.top, 8)

                        if !day.hourlyTemps.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("TEMPERATURE").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
                                InteractiveTempGraph(points: day.hourlyTemps, globalLow: globalLow, globalHigh: globalHigh).frame(height: 160)
                            }
                            .padding(16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 16)
                        }

                        // Accumulation callout
                        if day.accumulation.hasAccumulation {
                            HStack(spacing: 8) {
                                Image(systemName: day.precipType == .rain ? "drop.fill" : "snowflake")
                                    .foregroundStyle(.cyan)
                                Text("Accumulation: \(day.accumulation.displayString)")
                                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.cyan)
                            }
                            .padding(.horizontal, 20)
                        }

                        // Day forecast prose
                        if !day.dayProse.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: day.daySymbol)
                                        .symbolRenderingMode(.multicolor)
                                        .font(.system(size: 17))
                                    Text("DAY")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                Text(day.dayProse)
                                    .font(.system(size: 15)).foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(16)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 16)
                        }

                        // Night forecast prose
                        if !day.nightProse.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: day.nightSymbol ?? "moon.stars.fill")
                                        .symbolRenderingMode(.multicolor)
                                        .font(.system(size: 17))
                                    Text("NIGHT")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                Text(day.nightProse)
                                    .font(.system(size: 15)).foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(16)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 16)
                        }
                        Spacer(minLength: 32)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Interactive Graph

struct InteractiveTempGraph: View {
    let points: [HourlyForecast]
    let globalLow: Double
    let globalHigh: Double

    @State private var dragX: CGFloat? = nil
    private let topPad: CGFloat = 28
    private let bottomPad: CGFloat = 20
    private let sidePad: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width; let h = geo.size.height
            let plotH = h - topPad - bottomPad; let plotW = w - 2 * sidePad
            let range = max(globalHigh - globalLow, 1)

            let pts: [(CGFloat, CGFloat)] = points.enumerated().map { idx, p in
                let x = sidePad + plotW * CGFloat(idx) / CGFloat(max(points.count - 1, 1))
                let y = topPad + plotH * CGFloat(1 - (p.temperature - globalLow) / range)
                return (x, y)
            }

            let hovIdx: Int? = dragX.map { dx in
                let frac = (max(sidePad, min(w - sidePad, dx)) - sidePad) / plotW
                return max(0, min(points.count - 1, Int((frac * CGFloat(points.count - 1)).rounded())))
            }

            ZStack(alignment: .topLeading) {
                if pts.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: pts[0].0, y: topPad + plotH))
                        path.addLine(to: CGPoint(x: pts[0].0, y: pts[0].1))
                        addCurve(to: &path, pts: pts)
                        path.addLine(to: CGPoint(x: pts.last!.0, y: topPad + plotH))
                        path.closeSubpath()
                    }.fill(LinearGradient(colors: [.orange.opacity(0.3), .cyan.opacity(0.05)], startPoint: .top, endPoint: .bottom))

                    Path { path in
                        path.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
                        addCurve(to: &path, pts: pts)
                    }.stroke(Color.orange.opacity(0.85), lineWidth: 2)
                }

                ForEach(Array(points.enumerated()), id: \.offset) { idx, p in
                    if idx % 3 == 0 {
                        Text(hourLabel(p.time)).font(.system(size: 9)).foregroundStyle(.secondary)
                            .position(x: pts[idx].0, y: h - bottomPad / 2)
                    }
                }

                if let idx = hovIdx, idx < pts.count {
                    let px = pts[idx].0; let py = pts[idx].1; let temp = points[idx].temperature
                    Path { p in p.move(to: CGPoint(x: px, y: topPad)); p.addLine(to: CGPoint(x: px, y: topPad + plotH)) }
                        .stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    Circle().fill(Color.orange).frame(width: 8, height: 8).position(x: px, y: py)
                    Circle().fill(Color.white.opacity(0.9)).frame(width: 4, height: 4).position(x: px, y: py)

                    let bubbleX = min(max(px, 28), w - 28)
                    Text("\(Int(temp.rounded()))°").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule()).position(x: bubbleX, y: py - 20)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { dragX = $0.location.x }.onEnded { _ in withAnimation(.easeOut(duration: 0.3)) { dragX = nil } })
        }
    }

    private func addCurve(to path: inout Path, pts: [(CGFloat, CGFloat)]) {
        for i in 1..<pts.count {
            let cp1 = CGPoint(x: (pts[i-1].0 + pts[i].0) / 2, y: pts[i-1].1)
            let cp2 = CGPoint(x: (pts[i-1].0 + pts[i].0) / 2, y: pts[i].1)
            path.addCurve(to: CGPoint(x: pts[i].0, y: pts[i].1), control1: cp1, control2: cp2)
        }
    }
    private func hourLabel(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "ha"; return f.string(from: d).lowercased() }
}

// MARK: - Utilities

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial).opacity(0.85))
                 .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CardHeader: View {
    let icon: String; let title: String
    var body: some View {
        Label(title, systemImage: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }
}

#Preview {
    ContentView(selectedID: .constant("current"))
        .environment(LocationStore())
        .environment(LocationManager())
}
