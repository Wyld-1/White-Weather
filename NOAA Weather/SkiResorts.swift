//
//  SkiResorts.swift
//  NOAA Weather
//
//  Named ski area → coordinate lookup for WA, OR, ID, MT, UT.

import CoreLocation

struct SkiResort {
    let name: String
    let state: String
    let coordinate: CLLocationCoordinate2D
}

let skiResorts: [SkiResort] = [

    // MARK: Washington
    SkiResort(name: "Crystal Mountain",     state: "WA", coordinate: .init(latitude: 46.9282, longitude: -121.5073)),
    SkiResort(name: "Stevens Pass",         state: "WA", coordinate: .init(latitude: 47.7448, longitude: -121.0900)),
    SkiResort(name: "Snoqualmie Pass",      state: "WA", coordinate: .init(latitude: 47.4242, longitude: -121.4130)),
    SkiResort(name: "White Pass",           state: "WA", coordinate: .init(latitude: 46.6380, longitude: -121.3924)),
    SkiResort(name: "Mission Ridge",        state: "WA", coordinate: .init(latitude: 47.2928, longitude: -120.3997)),
    SkiResort(name: "Mt. Baker",            state: "WA", coordinate: .init(latitude: 48.8599, longitude: -121.6731)),
    SkiResort(name: "Loup Loup",            state: "WA", coordinate: .init(latitude: 48.3939, longitude: -119.8997)),
    SkiResort(name: "49 Degrees North",     state: "WA", coordinate: .init(latitude: 48.4148, longitude: -117.7283)),
    SkiResort(name: "Bluewood",             state: "WA", coordinate: .init(latitude: 46.0850, longitude: -117.8231)),

    // MARK: Oregon
    SkiResort(name: "Mt. Hood Meadows",     state: "OR", coordinate: .init(latitude: 45.3311, longitude: -121.6694)),
    SkiResort(name: "Timberline Lodge",     state: "OR", coordinate: .init(latitude: 45.3311, longitude: -121.7094)),
    SkiResort(name: "Ski Bowl",             state: "OR", coordinate: .init(latitude: 45.2944, longitude: -121.8022)),
    SkiResort(name: "Ski Cooper",           state: "OR", coordinate: .init(latitude: 45.3053, longitude: -121.7819)),
    SkiResort(name: "Mt. Bachelor",         state: "OR", coordinate: .init(latitude: 43.9791, longitude: -121.6878)),
    SkiResort(name: "Hoodoo",               state: "OR", coordinate: .init(latitude: 44.4040, longitude: -121.8597)),
    SkiResort(name: "Willamette Pass",      state: "OR", coordinate: .init(latitude: 43.6042, longitude: -122.0575)),
    SkiResort(name: "Anthony Lakes",        state: "OR", coordinate: .init(latitude: 44.9597, longitude: -118.2342)),
    SkiResort(name: "Warner Canyon",        state: "OR", coordinate: .init(latitude: 42.3906, longitude: -120.2789)),

    // MARK: Idaho
    SkiResort(name: "Sun Valley",           state: "ID", coordinate: .init(latitude: 43.6962, longitude: -114.3538)),
    SkiResort(name: "Bogus Basin",          state: "ID", coordinate: .init(latitude: 43.7622, longitude: -116.1011)),
    SkiResort(name: "Brundage Mountain",    state: "ID", coordinate: .init(latitude: 44.8711, longitude: -116.4583)),
    SkiResort(name: "Schweitzer",           state: "ID", coordinate: .init(latitude: 48.3618, longitude: -116.6228)),
    SkiResort(name: "Tamarack Resort",      state: "ID", coordinate: .init(latitude: 44.6880, longitude: -116.1269)),
    SkiResort(name: "Pomerelle",            state: "ID", coordinate: .init(latitude: 42.5897, longitude: -113.7661)),
    SkiResort(name: "Magic Mountain",       state: "ID", coordinate: .init(latitude: 42.8453, longitude: -114.3847)),
    SkiResort(name: "Kelly Canyon",         state: "ID", coordinate: .init(latitude: 43.5800, longitude: -111.8000)),
    SkiResort(name: "Lookout Pass",         state: "ID", coordinate: .init(latitude: 47.4629, longitude: -115.7006)),

    // MARK: Montana
    SkiResort(name: "Big Sky",              state: "MT", coordinate: .init(latitude: 45.2860, longitude: -111.4014)),
    SkiResort(name: "Whitefish Mountain",   state: "MT", coordinate: .init(latitude: 48.4868, longitude: -114.3531)),
    SkiResort(name: "Bridger Bowl",         state: "MT", coordinate: .init(latitude: 45.8233, longitude: -110.8997)),
    SkiResort(name: "Red Lodge Mountain",   state: "MT", coordinate: .init(latitude: 45.1197, longitude: -109.3536)),
    SkiResort(name: "Great Divide",         state: "MT", coordinate: .init(latitude: 46.8797, longitude: -112.4019)),
    SkiResort(name: "Showdown",             state: "MT", coordinate: .init(latitude: 47.0042, longitude: -110.6494)),
    SkiResort(name: "Discovery",            state: "MT", coordinate: .init(latitude: 46.2411, longitude: -113.0683)),
    SkiResort(name: "Maverick Mountain",    state: "MT", coordinate: .init(latitude: 45.2614, longitude: -113.3028)),
    SkiResort(name: "Blacktail Mountain",   state: "MT", coordinate: .init(latitude: 47.8519, longitude: -114.5214)),
    SkiResort(name: "Lost Trail",           state: "MT", coordinate: .init(latitude: 45.6944, longitude: -113.9583)),

    // MARK: Utah
    SkiResort(name: "Park City Mountain",   state: "UT", coordinate: .init(latitude: 40.6514, longitude: -111.5080)),
    SkiResort(name: "Deer Valley",          state: "UT", coordinate: .init(latitude: 40.6374, longitude: -111.4783)),
    SkiResort(name: "Alta",                 state: "UT", coordinate: .init(latitude: 40.5883, longitude: -111.6383)),
    SkiResort(name: "Snowbird",             state: "UT", coordinate: .init(latitude: 40.5830, longitude: -111.6556)),
    SkiResort(name: "Brighton",             state: "UT", coordinate: .init(latitude: 40.5986, longitude: -111.5836)),
    SkiResort(name: "Solitude",             state: "UT", coordinate: .init(latitude: 40.6197, longitude: -111.5922)),
    SkiResort(name: "Snowbasin",            state: "UT", coordinate: .init(latitude: 41.2161, longitude: -111.8572)),
    SkiResort(name: "Powder Mountain",      state: "UT", coordinate: .init(latitude: 41.3697, longitude: -111.7808)),
    SkiResort(name: "Brian Head",           state: "UT", coordinate: .init(latitude: 37.6992, longitude: -112.8497)),
    SkiResort(name: "Sundance",             state: "UT", coordinate: .init(latitude: 40.3883, longitude: -111.5886)),
    SkiResort(name: "Beaver Mountain",      state: "UT", coordinate: .init(latitude: 41.9678, longitude: -111.5406)),
    SkiResort(name: "Eagle Point",          state: "UT", coordinate: .init(latitude: 38.3428, longitude: -112.3478)),
    SkiResort(name: "Nordic Valley",        state: "UT", coordinate: .init(latitude: 41.3097, longitude: -111.8247)),
]

// Fuzzy-search ski resorts by name. Returns best matches up to `limit`.
func searchSkiResorts(_ query: String, limit: Int = 5) -> [SkiResort] {
    guard !query.isEmpty else { return [] }
    let q = query.lowercased()
    return skiResorts
        .filter { $0.name.lowercased().contains(q) || $0.state.lowercased() == q }
        .prefix(limit)
        .map { $0 }
}
