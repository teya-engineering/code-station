import Foundation

// Where in the world the machine is, read from its time zone. The zone table that ships
// with every Unix lists the principal city of each zone with its coordinates, which puts
// most people within an hour's drive of the right place and costs no permission prompt.
// It is a guess of a city, not a position, so sunset lands a few minutes off for anyone
// away from that city; close enough for a colour that drifts over an hour.
enum ZoneLocation {
    // The coordinates for the zone, or nil if the table has no entry for it.
    static func coordinates(for zone: TimeZone, table: String? = nil) -> Coordinates? {
        let table = table ?? Self.table ?? ""
        for line in table.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3, columns[2] == zone.identifier else { continue }
            return parse(String(columns[1]))
        }
        return nil
    }

    // Coordinates for the zone, falling back on the longitude its clock implies and the
    // equator when the table does not know it. A zone named for an offset alone, such as
    // GMT+3, has no city to look up. The longitude comes from the zone's standard time,
    // since summer time moves the clock an hour without moving the sun.
    static func bestGuess(for zone: TimeZone = .current, table: String? = nil,
                          at moment: Date = Date()) -> Coordinates {
        if let place = coordinates(for: zone, table: table) { return place }
        let standard = Double(zone.secondsFromGMT(for: moment)) - zone.daylightSavingTimeOffset(for: moment)
        return Coordinates(latitude: 0, longitude: standard / 3_600 * 15)
    }

    // ISO 6709 as the table writes it: ±DDMM±DDDMM or ±DDMMSS±DDDMMSS.
    static func parse(_ text: String) -> Coordinates? {
        let scalars = Array(text)
        guard let split = scalars.indices.dropFirst().first(where: { scalars[$0] == "+" || scalars[$0] == "-" })
        else { return nil }
        guard let latitude = angle(String(scalars[..<split]), degreeDigits: 2),
              let longitude = angle(String(scalars[split...]), degreeDigits: 3)
        else { return nil }
        return Coordinates(latitude: latitude, longitude: longitude)
    }

    private static func angle(_ text: String, degreeDigits: Int) -> Double? {
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = text.dropFirst()
        guard digits.count == degreeDigits + 2 || digits.count == degreeDigits + 4,
              digits.allSatisfy(\.isNumber),
              let degrees = Double(digits.prefix(degreeDigits)),
              let minutes = Double(digits.dropFirst(degreeDigits).prefix(2))
        else { return nil }
        let seconds = Double(digits.dropFirst(degreeDigits + 2)) ?? 0
        let magnitude = degrees + minutes / 60 + seconds / 3_600
        return sign == "-" ? -magnitude : magnitude
    }

    // The system's own table first, since it is kept current with the OS; the copy in the
    // bundle is for a machine where it has moved.
    private static let table: String? = {
        let system = URL(fileURLWithPath: "/usr/share/zoneinfo/zone.tab")
        if let text = try? String(contentsOf: system, encoding: .utf8) { return text }
        guard let url = AppResources.bundle.url(forResource: "zone", withExtension: "tab")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()
}
