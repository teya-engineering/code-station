import Foundation

// A place on the earth, for working out where the sun is from it.
struct Coordinates: Equatable, Sendable {
    // Degrees, north positive.
    var latitude: Double
    // Degrees, east positive.
    var longitude: Double
}

// Where the sun is in the sky at a moment, seen from a place. The arithmetic is NOAA's
// solar calculator, which is good to a minute or so for any date this century and
// needs nothing but the date and the coordinates.
//
// Angles are in degrees throughout, and every moment is a plain Date, so the caller's
// time zone never enters into it: the sun does not know what the clock says.
enum SolarClock {
    // The sun's centre sits this far below the horizon when its upper edge appears to
    // touch it, once refraction has bent the light. NOAA's sunrise and sunset use it.
    static let horizonAltitude = -0.833
    // The end of civil twilight: the last of the light has gone from the sky.
    static let civilTwilightAltitude = -6.0

    // How far the sun is above the horizon, in degrees. Negative once it has set.
    static func altitude(at moment: Date, from place: Coordinates) -> Double {
        let century = julianCentury(moment)
        let declination = Self.declination(century)
        let minutes = moment.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) / 60
        var trueSolarMinutes = (minutes + equationOfTime(century) + 4 * place.longitude)
            .truncatingRemainder(dividingBy: 1_440)
        if trueSolarMinutes < 0 { trueSolarMinutes += 1_440 }
        let hourAngle = trueSolarMinutes / 4 - 180
        let cosZenith = sin(radians(place.latitude)) * sin(radians(declination))
            + cos(radians(place.latitude)) * cos(radians(declination)) * cos(radians(hourAngle))
        return 90 - degrees(acos(min(1, max(-1, cosZenith))))
    }

    // The moment the sun is highest on the local day that holds `moment`. The day is read
    // in the calendar given, so a place and its clock agree on which day is meant.
    static func solarNoon(on moment: Date, from place: Coordinates,
                          calendar: Calendar = .current) -> Date {
        let midday = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: moment)
            ?? moment
        // Solar noon in minutes after UTC midnight of the day holding the local midday.
        // The equation of time is read at that midday; it drifts a fraction of a second
        // across the few hours the guess can be out by.
        let utcMidnight = midday.timeIntervalSince1970
            - midday.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        let noonMinutes = 720 - 4 * place.longitude - equationOfTime(julianCentury(midday))
        var noon = Date(timeIntervalSince1970: utcMidnight + noonMinutes * 60)
        // Far east or west of Greenwich, the solar noon nearest the local midday can sit
        // on the other side of UTC midnight.
        if noon.timeIntervalSince(midday) > 43_200 { noon = noon.addingTimeInterval(-86_400) }
        if midday.timeIntervalSince(noon) > 43_200 { noon = noon.addingTimeInterval(86_400) }
        return noon
    }

    // When the sun's upper edge crosses the horizon on the local day, or nil where it does
    // not cross at all: the polar day and the polar night.
    static func sunrise(on moment: Date, from place: Coordinates,
                        calendar: Calendar = .current) -> Date? {
        crossing(on: moment, from: place, calendar: calendar, rising: true)
    }

    static func sunset(on moment: Date, from place: Coordinates,
                       calendar: Calendar = .current) -> Date? {
        crossing(on: moment, from: place, calendar: calendar, rising: false)
    }

    private static func crossing(on moment: Date, from place: Coordinates, calendar: Calendar,
                                 rising: Bool) -> Date? {
        let noon = solarNoon(on: moment, from: place, calendar: calendar)
        let declination = Self.declination(julianCentury(noon))
        let cosHourAngle = (cos(radians(90 - horizonAltitude))
            / (cos(radians(place.latitude)) * cos(radians(declination))))
            - tan(radians(place.latitude)) * tan(radians(declination))
        guard (-1...1).contains(cosHourAngle) else { return nil }
        let hourAngle = degrees(acos(cosHourAngle))
        return noon.addingTimeInterval((rising ? -1 : 1) * hourAngle * 4 * 60)
    }

    // MARK: - NOAA

    private static func julianCentury(_ moment: Date) -> Double {
        // Julian day 2451545.0 is noon UTC on 1 January 2000.
        let julianDay = moment.timeIntervalSince1970 / 86_400 + 2_440_587.5
        return (julianDay - 2_451_545) / 36_525
    }

    private static func meanLongitude(_ century: Double) -> Double {
        wrap(280.46646 + century * (36000.76983 + century * 0.0003032))
    }

    private static func meanAnomaly(_ century: Double) -> Double {
        357.52911 + century * (35999.05029 - 0.0001537 * century)
    }

    private static func eccentricity(_ century: Double) -> Double {
        0.016708634 - century * (0.000042037 + 0.0000001267 * century)
    }

    private static func apparentLongitude(_ century: Double) -> Double {
        let anomaly = radians(meanAnomaly(century))
        let centre = sin(anomaly) * (1.914602 - century * (0.004817 + 0.000014 * century))
            + sin(2 * anomaly) * (0.019993 - 0.000101 * century)
            + sin(3 * anomaly) * 0.000289
        let trueLongitude = meanLongitude(century) + centre
        return trueLongitude - 0.00569 - 0.00478 * sin(radians(125.04 - 1934.136 * century))
    }

    private static func obliquity(_ century: Double) -> Double {
        let seconds = 21.448 - century * (46.815 + century * (0.00059 - century * 0.001813))
        let mean = 23 + (26 + seconds / 60) / 60
        return mean + 0.00256 * cos(radians(125.04 - 1934.136 * century))
    }

    // How far north of the equator the sun stands overhead, in degrees.
    private static func declination(_ century: Double) -> Double {
        degrees(asin(sin(radians(obliquity(century))) * sin(radians(apparentLongitude(century)))))
    }

    // How many minutes the sundial runs ahead of the clock on this day.
    private static func equationOfTime(_ century: Double) -> Double {
        let y = pow(tan(radians(obliquity(century) / 2)), 2)
        let longitude = radians(meanLongitude(century))
        let anomaly = radians(meanAnomaly(century))
        let e = eccentricity(century)
        let time = y * sin(2 * longitude)
            - 2 * e * sin(anomaly)
            + 4 * e * y * sin(anomaly) * cos(2 * longitude)
            - 0.5 * y * y * sin(4 * longitude)
            - 1.25 * e * e * sin(2 * anomaly)
        return 4 * degrees(time)
    }

    private static func wrap(_ angle: Double) -> Double {
        let wrapped = angle.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}
