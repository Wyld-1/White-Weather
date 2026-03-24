//
//  wildcat_NOAA_Weather_widgets.swift
//  wildcat.NOAA-Weather.widgets
//
//  Created by Liam Lefohn on 3/23/26.
//

import WidgetKit
import SwiftUI

struct WeatherEntry: TimelineEntry {
    let date: Date
    let data: WidgetWeatherData
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WeatherEntry {
        WeatherEntry(date: Date(), data: .placeholder)
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> WeatherEntry {
        let id = configuration.location?.id ?? "current"
        return WeatherEntry(date: Date(), data: WidgetWeatherData.load(id: id) ?? .placeholder)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<WeatherEntry> {
        let id = configuration.location?.id ?? "current"
        let data = WidgetWeatherData.load(id: id) ?? .placeholder
        let entry = WeatherEntry(date: Date(), data: data)
        return Timeline(entries: [entry], policy: .atEnd)
    }
}

struct wildcat_NOAA_Weather_widgetsEntryView : View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                LockScreenWidget(data: entry.data)
            case .systemSmall:
                SmallWidget(data: entry.data)
            case .systemMedium:
                MediumWidget(data: entry.data)
            default:
                SmallWidget(data: entry.data)
            }
        }
        // Open the app to the same page as the widget showed, when tapped
        .widgetURL(URL(string: "wildcat-weather://location/\(entry.data.id)"))
    }
}

struct wildcat_NOAA_Weather_widgets: Widget {
    let kind: String = "wildcat_NOAA_Weather_widgets"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            wildcat_NOAA_Weather_widgetsEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetBackground(condition: entry.data.condition, isDay: entry.data.isDay)
                }
        }
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

// MARK: - Layouts

struct LockScreenWidget: View {
    let data: WidgetWeatherData
    var body: some View {
        Gauge(value: data.temperature, in: data.low...data.high) {
            Text("Temperature")
        } currentValueLabel: {
            Image(systemName: data.sfSymbol)
        } minimumValueLabel: {
            Text("\(Int(data.low))")
        } maximumValueLabel: {
            Text("\(Int(data.high))")
        }
        .gaugeStyle(.accessoryCircular)
    }
}

// MARK: - Small Widget
struct SmallWidget: View {
    let data: WidgetWeatherData
    var body: some View {
        WeatherInfoView(data: data, useLargeTemp: false)
            .foregroundStyle(.white)
    }
}

// MARK: - Medium Widget
struct MediumWidget: View {
    let data: WidgetWeatherData
    var body: some View {
        HStack(spacing: 0) {
            WeatherInfoView(data: data, useLargeTemp: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            // Verticle divider
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(width: 1)
                .padding(.vertical, 20)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("FORECAST")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.white.opacity(0.5))
                
                Text(data.dayProse)
                    .foregroundStyle(.white)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(5)
                
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
        }
        .foregroundStyle(.white)
    }
}

struct WidgetBackground: View {
    let condition: String
    let isDay: Bool
    
    var body: some View {
        let c = condition.lowercased()
        let colors: [Color]
        
        if c.contains("snow") || c.contains("sleet") || c.contains("flurr") {
            colors = [Color(white: 0.95), Color(white: 0.75)]
            
        } else if c.contains("rain") || c.contains("drizzle") || c.contains("storm") {
            colors = [Color(red: 0.15, green: 0.2, blue: 0.3), Color(red: 0.35, green: 0.4, blue: 0.5)]
            
        } else if !isDay {
            colors = [Color(red: 0.02, green: 0.05, blue: 0.15), Color(red: 0.1, green: 0.1, blue: 0.25)]
            
        } else if c.contains("clear") || c.contains("sunny") || c.contains("fair") {
            colors = [Color.blue, Color.yellow]
            
        } else {
            colors = [Color(white: 0.6), Color(white: 0.3)]
        }
        
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

// MARK: - Reusable Weather Info
// We split the "Info" from the "Background" so the Medium widget can reuse it cleanly.
struct WeatherInfoView: View {
    let data: WidgetWeatherData
    let useLargeTemp: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if data.id == "current" {
                Image(systemName: "location.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1)
            }
            else {
                Image(systemName: "location.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0))
            }
            
            HStack(alignment: .top) {
                let hasAlert = (data.windGusts ?? 0) >= 40
                if !hasAlert {
                    Spacer()
                }
                
                Image(systemName: data.sfSymbol)
                    .renderingMode(.original)
                    .font(.system(size: 40))
                    .shadow(color: .black.opacity(0.2), radius: 4)
                
                Spacer()
                
                if hasAlert {
                    Image(systemName: "wind.circle.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.yellow)
                        .shadow(radius: 2)
                }
            }
            
            Spacer()
            
            Text("\(Int(data.temperature.rounded()))°")
                .font(.system(size: 42, weight: .medium, design: .rounded))
                .shadow(color: .black.opacity(0.3), radius: 2)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 6)
            
            if let accum = data.accumDisplayString, !accum.isEmpty {
                HStack(spacing: 8) {
                    Text(accum)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.cyan.opacity(0.9))
                        .shadow(color: .white, radius: 1.5)
                    
                    Text(String(Int(data.high)) + "˚ | " + String(Int(data.low)) + "˚")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.4), radius: 1)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            else {
                Text("H:\(Int(data.high))°  L:\(Int(data.low))°")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.4), radius: 1)
            }
        }
    }
}
