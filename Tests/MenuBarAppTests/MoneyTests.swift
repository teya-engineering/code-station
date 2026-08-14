import Testing
@testable import MenuBarApp

// Costs sit in columns next to each other, so cents and dollars must print with the
// same two decimals to line up.
struct MoneyTests {

    @Test func alwaysShowsTwoDecimals() {
        #expect(Money.short(0.08) == "$0.08")
        #expect(Money.short(3) == "$3.00")
        #expect(Money.short(1.999) == "$2.00")
        #expect(Money.short(0) == "$0.00")
    }
}
