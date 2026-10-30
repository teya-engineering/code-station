import Foundation
import Testing
@testable import MenuBarApp

// The sun's arithmetic is checked against published times and against itself: the moments
// it names for noon and the horizon have to agree with the altitude it reports there.
struct SolarClockTests {
    private let lisbon = Coordinates(latitude: 38.717, longitude: -9.133)
    private let greenwich = Coordinates(latitude: 51.477, longitude: 0)
    private let tromso = Coordinates(latitude: 69.65, longitude: 18.96)
    private let equator = Coordinates(latitude: 0, longitude: 0)

    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute))!
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func minutes(_ moment: Date, from reference: Date) -> Double {
        moment.timeIntervalSince(reference) / 60
    }

    // The equation of time is what moves solar noon off the clock's: about two minutes
    // early at the June solstice and sixteen late at the start of November.
    @Test func solarNoonFollowsTheEquationOfTime() {
        let june = SolarClock.solarNoon(on: utc(2026, 6, 21), from: greenwich, calendar: utcCalendar)
        #expect(abs(minutes(june, from: utc(2026, 6, 21, 12, 2))) < 1)
        let november = SolarClock.solarNoon(on: utc(2026, 11, 3), from: greenwich, calendar: utcCalendar)
        #expect(abs(minutes(november, from: utc(2026, 11, 3, 11, 44))) < 1)
    }

    @Test func noonAltitudeOnTheEquatorAtTheSolsticeIsTheObliquity() {
        let noon = SolarClock.solarNoon(on: utc(2026, 6, 21), from: equator, calendar: utcCalendar)
        #expect(abs(SolarClock.altitude(at: noon, from: equator) - (90 - 23.44)) < 0.1)
    }

    // Lisbon's published solstice times: 06:12 and 21:05 Western European Summer Time.
    @Test func lisbonSunriseAndSunsetMatchTheAlmanac() throws {
        let day = utc(2026, 6, 21)
        let sunrise = try #require(SolarClock.sunrise(on: day, from: lisbon, calendar: utcCalendar))
        let sunset = try #require(SolarClock.sunset(on: day, from: lisbon, calendar: utcCalendar))
        #expect(abs(minutes(sunrise, from: utc(2026, 6, 21, 5, 12))) < 4)
        #expect(abs(minutes(sunset, from: utc(2026, 6, 21, 20, 5))) < 4)
    }

    // 07:51 and 17:18 Western European Time.
    @Test func lisbonWinterSunriseAndSunsetMatchTheAlmanac() throws {
        let day = utc(2026, 12, 21)
        let sunrise = try #require(SolarClock.sunrise(on: day, from: lisbon, calendar: utcCalendar))
        let sunset = try #require(SolarClock.sunset(on: day, from: lisbon, calendar: utcCalendar))
        #expect(abs(minutes(sunrise, from: utc(2026, 12, 21, 7, 51))) < 4)
        #expect(abs(minutes(sunset, from: utc(2026, 12, 21, 17, 18))) < 4)
    }

    @Test func theSunSitsOnTheHorizonAtSunriseAndSunset() throws {
        for place in [lisbon, greenwich, equator] {
            for day in [utc(2026, 3, 20), utc(2026, 9, 1), utc(2026, 12, 21)] {
                let sunrise = try #require(SolarClock.sunrise(on: day, from: place, calendar: utcCalendar))
                let sunset = try #require(SolarClock.sunset(on: day, from: place, calendar: utcCalendar))
                #expect(abs(SolarClock.altitude(at: sunrise, from: place) - SolarClock.horizonAltitude) < 0.15)
                #expect(abs(SolarClock.altitude(at: sunset, from: place) - SolarClock.horizonAltitude) < 0.15)
                #expect(sunrise < sunset)
            }
        }
    }

    @Test func noonIsTheTopOfTheArc() {
        let noon = SolarClock.solarNoon(on: utc(2026, 4, 10), from: lisbon, calendar: utcCalendar)
        let top = SolarClock.altitude(at: noon, from: lisbon)
        for offset in [-3600.0, -600, 600, 3600] {
            #expect(SolarClock.altitude(at: noon.addingTimeInterval(offset), from: lisbon) < top)
        }
    }

    @Test func thePolarDayAndNightHaveNoHorizonCrossing() {
        #expect(SolarClock.sunrise(on: utc(2026, 6, 21), from: tromso, calendar: utcCalendar) == nil)
        #expect(SolarClock.sunset(on: utc(2026, 12, 21), from: tromso, calendar: utcCalendar) == nil)
        #expect(SolarClock.sunrise(on: utc(2026, 3, 20), from: tromso, calendar: utcCalendar) != nil)
    }
}

struct SunlightTests {
    private let lisbon = Coordinates(latitude: 38.717, longitude: -9.133)
    private let tromso = Coordinates(latitude: 69.65, longitude: 18.96)

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func utc(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: month, day: day,
                                              hour: hour, minute: minute))!
    }

    @Test func fullSunAtNoonAndNoneAtNight() {
        let noon = SolarClock.solarNoon(on: utc(6, 21, 12), from: lisbon, calendar: utcCalendar)
        #expect(Sunlight.reading(at: noon, from: lisbon, calendar: utcCalendar).fraction == 1)
        #expect(Sunlight.reading(at: utc(6, 21, 2), from: lisbon, calendar: utcCalendar).fraction == 0)
        #expect(Sunlight.reading(at: utc(6, 21, 23, 30), from: lisbon, calendar: utcCalendar).fraction == 0)
    }

    // Full warmth arrives at the end of civil twilight, not at the horizon.
    @Test func sunsetStillHasSomeSunLeft() throws {
        let sunset = try #require(SolarClock.sunset(on: utc(6, 21, 12), from: lisbon, calendar: utcCalendar))
        let atSunset = Sunlight.reading(at: sunset, from: lisbon, calendar: utcCalendar)
        #expect(atSunset.fraction > 0.05)
        #expect(atSunset.fraction < 0.2)
        let later = Sunlight.reading(at: sunset.addingTimeInterval(45 * 60), from: lisbon, calendar: utcCalendar)
        #expect(later.fraction == 0)
    }

    @Test func theArcClimbsThenFalls() {
        var last = -1.0
        var peaked = false
        for hour in 3...23 {
            let fraction = Sunlight.reading(at: utc(9, 1, hour), from: lisbon, calendar: utcCalendar).fraction
            if fraction < last { peaked = true }
            if peaked { #expect(fraction <= last) } else { #expect(fraction >= last) }
            last = fraction
        }
        #expect(peaked)
    }

    // The hours after midnight belong to the coming day's arc, so a reading just before
    // dawn climbs rather than sitting on yesterday's night.
    @Test func earlyMorningReadsAgainstTheComingDay() {
        let four = Sunlight.reading(at: utc(6, 21, 4), from: lisbon, calendar: utcCalendar).fraction
        let six = Sunlight.reading(at: utc(6, 21, 6), from: lisbon, calendar: utcCalendar).fraction
        #expect(six > four)
    }

    @Test func thePolarNightIsAllLampAndThePolarDayNeverFullyWarms() {
        #expect(Sunlight.reading(at: utc(12, 21, 11), from: tromso, calendar: utcCalendar).fraction == 0)
        // Solar noon in Tromsø is about 10:44 UTC, so midnight is about 22:44.
        let summerMidnight = Sunlight.reading(at: utc(6, 21, 22, 44), from: tromso, calendar: utcCalendar)
        #expect(summerMidnight.altitude > SolarClock.civilTwilightAltitude)
        #expect(summerMidnight.fraction < 0.01)
        #expect(Sunlight.reading(at: utc(6, 21, 10, 44), from: tromso, calendar: utcCalendar).fraction > 0.99)
    }

    @Test func temperatureRunsBetweenLampAndDaylight() {
        #expect(Sunlight.kelvin(for: 0) == 3400)
        #expect(Sunlight.kelvin(for: 1) == 6500)
        let half = Sunlight.kelvin(for: 0.5)
        #expect(half > 3400 && half < 6500)
        #expect(abs(Sunlight.warmth(of: half) - 0.5) < 0.001)
        #expect(Sunlight.warmth(of: 6500) == 0)
        #expect(Sunlight.warmth(of: 3400) == 1)
    }
}

struct ZoneLocationTests {
    private let table = """
    # comment
    PT\t+3843-00908\tEurope/Lisbon\tPortugal (mainland)
    US\t+404251-0740023\tAmerica/New_York\tEastern (most areas)
    AU\t-3352+15113\tAustralia/Sydney\tNew South Wales (most areas)
    """

    @Test func parsesMinutesAndSecondsForms() throws {
        let lisbon = try #require(ZoneLocation.parse("+3843-00908"))
        #expect(abs(lisbon.latitude - 38.717) < 0.001)
        #expect(abs(lisbon.longitude - -9.133) < 0.001)
        let newYork = try #require(ZoneLocation.parse("+404251-0740023"))
        #expect(abs(newYork.latitude - 40.714) < 0.001)
        #expect(abs(newYork.longitude - -74.006) < 0.001)
        let sydney = try #require(ZoneLocation.parse("-3352+15113"))
        #expect(sydney.latitude < 0 && sydney.longitude > 0)
        #expect(ZoneLocation.parse("nonsense") == nil)
    }

    @Test func findsTheZoneInTheTable() throws {
        let zone = try #require(TimeZone(identifier: "Australia/Sydney"))
        let place = try #require(ZoneLocation.coordinates(for: zone, table: table))
        #expect(abs(place.latitude - -33.867) < 0.001)
        #expect(ZoneLocation.coordinates(for: TimeZone(identifier: "Asia/Tokyo")!, table: table) == nil)
    }

    @Test func theSystemTableKnowsCommonZones() throws {
        let place = try #require(ZoneLocation.coordinates(for: TimeZone(identifier: "Europe/London")!))
        #expect(abs(place.latitude - 51.5) < 0.1)
    }

    // A zone named for its offset alone has no city, so the clock gives the longitude.
    @Test func anOffsetZoneGuessesFromItsClock() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 3 * 3_600))
        let place = ZoneLocation.bestGuess(for: zone)
        #expect(place.latitude == 0)
        #expect(abs(place.longitude - 45) < 0.001)
    }
}
