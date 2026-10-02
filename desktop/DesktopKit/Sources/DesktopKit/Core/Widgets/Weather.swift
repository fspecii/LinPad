import CoreLocation
import Foundation
import Observation

/// Current conditions and a short forecast from Open-Meteo (no API key).
struct WeatherReport: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable {
        var date: String
        var code: Int
        var high: Double
        var low: Double
    }

    var place: String
    var temperature: Double
    var code: Int
    var isDay: Bool
    var windSpeed: Double?
    var unit: String
    var days: [Day]
    var updated: Date

    var condition: WeatherCondition { WeatherCondition(code: code) }
}

/// WMO weather interpretation codes, as Open-Meteo reports them.
struct WeatherCondition: Equatable {
    let code: Int

    var title: String {
        switch code {
        case 0: "Clear"
        case 1: "Mainly Clear"
        case 2: "Partly Cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing Drizzle"
        case 61, 63, 65: "Rain"
        case 66, 67: "Freezing Rain"
        case 71, 73, 75, 77: "Snow"
        case 80, 81, 82: "Showers"
        case 85, 86: "Snow Showers"
        case 95: "Thunderstorm"
        case 96, 99: "Thunderstorm, Hail"
        default: "Unknown"
        }
    }

    func symbol(isDay: Bool = true) -> String {
        switch code {
        case 0, 1: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55, 56, 57: "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67: "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 80, 81, 82: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}

enum OpenMeteo {
    struct Place: Equatable, Sendable {
        var name: String
        var latitude: Double
        var longitude: Double
    }

    static func forecastURL(for place: Place, fahrenheit: Bool) -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "4"),
        ] + (fahrenheit ? [URLQueryItem(name: "temperature_unit", value: "fahrenheit")] : [])
        return components.url!
    }

    static func geocodingURL(for city: String) -> URL {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1")]
        return components.url!
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            var temperature_2m: Double
            var weather_code: Int
            var is_day: Int?
            var wind_speed_10m: Double?
        }

        struct Daily: Decodable {
            var time: [String]
            var weather_code: [Int]
            var temperature_2m_max: [Double]
            var temperature_2m_min: [Double]
        }

        var current: Current
        var current_units: [String: String]?
        var daily: Daily?
    }

    private struct GeocodingResponse: Decodable {
        struct Result: Decodable {
            var name: String
            var latitude: Double
            var longitude: Double
            var country: String?
        }

        var results: [Result]?
    }

    static func parseForecast(_ data: Data, place: String, now: Date = Date()) throws -> WeatherReport {
        let response = try JSONDecoder().decode(ForecastResponse.self, from: data)
        var days: [WeatherReport.Day] = []
        if let daily = response.daily {
            let count = min(daily.time.count, daily.weather_code.count, daily.temperature_2m_max.count, daily.temperature_2m_min.count)
            days = (0..<count).map {
                WeatherReport.Day(date: daily.time[$0], code: daily.weather_code[$0],
                                  high: daily.temperature_2m_max[$0], low: daily.temperature_2m_min[$0])
            }
        }
        return WeatherReport(place: place, temperature: response.current.temperature_2m, code: response.current.weather_code,
                             isDay: (response.current.is_day ?? 1) == 1, windSpeed: response.current.wind_speed_10m,
                             unit: response.current_units?["temperature_2m"] ?? "°", days: days, updated: now)
    }

    static func parseGeocoding(_ data: Data) throws -> Place? {
        let response = try JSONDecoder().decode(GeocodingResponse.self, from: data)
        return response.results?.first.map { Place(name: $0.name, latitude: $0.latitude, longitude: $0.longitude) }
    }
}

/// The Weather widget's data: the typed city, or else where the iPad is (when the user
/// allows location while in use). Refreshed at most every 30 minutes, and only while a
/// Weather widget is on screen.
@Observable @MainActor
final class WeatherModel {
    static let cityKey = "widgets.weather.city"
    static let cacheKey = "widgets.weather.report"
    private static let maximumAge: TimeInterval = 30 * 60

    private(set) var report: WeatherReport?
    private(set) var error: String?
    private(set) var isLoading = false
    var city: String = UserDefaults.standard.string(forKey: WeatherModel.cityKey) ?? "" {
        didSet {
            UserDefaults.standard.set(city, forKey: Self.cityKey)
            if city != oldValue { report = nil }
        }
    }

    @ObservationIgnored private let locator = OneShotLocator()

    init() {
        report = UserDefaults.standard.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode(WeatherReport.self, from: $0) }
    }

    var needsCity: Bool { city.isEmpty && !locator.canUseLocation }

    func refreshIfStale(now: Date = Date()) async {
        if let report, now.timeIntervalSince(report.updated) < Self.maximumAge { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let place = try await resolvePlace() else {
                error = city.isEmpty ? "Type a city to see its weather." : "No place called “\(city)”."
                return
            }
            let fahrenheit = Locale.current.measurementSystem == .us
            let (data, _) = try await URLSession.shared.data(from: OpenMeteo.forecastURL(for: place, fahrenheit: fahrenheit))
            let report = try OpenMeteo.parseForecast(data, place: place.name)
            self.report = report
            error = nil
            if let encoded = try? JSONEncoder().encode(report) { UserDefaults.standard.set(encoded, forKey: Self.cacheKey) }
        } catch {
            self.error = report == nil ? "Weather is unavailable offline." : nil
        }
    }

    private func resolvePlace() async throws -> OpenMeteo.Place? {
        let typed = city.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty {
            let (data, _) = try await URLSession.shared.data(from: OpenMeteo.geocodingURL(for: typed))
            return try OpenMeteo.parseGeocoding(data)
        }
        return await locator.currentPlace()
    }
}

/// One location fix, asked for only when the app declares when-in-use location access.
@MainActor
private final class OneShotLocator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var canUseLocation: Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") != nil else { return false }
        switch manager.authorizationStatus {
        case .denied, .restricted: return false
        default: return true
        }
    }

    func currentPlace() async -> OpenMeteo.Place? {
        guard canUseLocation, continuation == nil else { return nil }
        let location: CLLocation? = await withCheckedContinuation { continuation in
            self.continuation = continuation
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
        }
        guard let location else { return nil }
        let name = (try? await CLGeocoder().reverseGeocodeLocation(location))?.first?.locality ?? "Current Location"
        return OpenMeteo.Place(name: name, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    private func finish(_ location: CLLocation?) {
        continuation?.resume(returning: location)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard continuation != nil else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            case .notDetermined: break
            default: finish(nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        MainActor.assumeIsolated { finish(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(nil) }
    }
}
