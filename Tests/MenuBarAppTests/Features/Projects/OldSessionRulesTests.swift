import Foundation
import Testing
@testable import MenuBarApp

struct OldSessionRulesTests {
    @Test func everyCombinationUsesTheLongestMatchingAgeAndRequiresEverySwitch() {
        let reasons = CleanupReason.allCases
        let ages = Dictionary(uniqueKeysWithValues: zip(reasons, [5, 9, 12, 2, 7]))
        let rule = CleanupRule(deletesOnItsOwn: false, asked: [.unread, .unbuiltDesign],
                               includesOrphans: false, days: 30, conditionDays: ages)
        for mask in 1..<(1 << reasons.count) {
            let matching = reasons.enumerated().compactMap { index, reason in
                mask & (1 << index) == 0 ? nil : reason
            }
            #expect(rule.age(matching: matching) == matching.compactMap { ages[$0] }.max())
            #expect(rule.automaticallyDeletes(matching)
                    == !matching.contains { $0 == .unread || $0 == .unbuiltDesign })
        }
        #expect(rule.age(matching: []) == 30)
        #expect(!rule.automaticallyDeletes([]))
        #expect(rule.minimumDays == 2)
    }

    @Test func agesCountFromTheLastTurn() {
        let now = Date()
        var session = ChatSession(projectID: UUID())
        session.createdAt = now.addingTimeInterval(-20 * 86_400)
        let rule = CleanupRule(deletesOnItsOwn: true, asked: [.unread], includesOrphans: false,
                               days: 3, conditionDays: [.unread: 10])
        #expect(rule.isOld(session, reasons: [.unread], now: now))
        session.summary.lastMessageAt = now.addingTimeInterval(-5 * 86_400)
        #expect(!rule.isOld(session, reasons: [.unread], now: now))
        #expect(rule.isOld(session, reasons: [], now: now))
    }

    @Test @MainActor func freshSettingsUseThreeDaysAndProtectEveryCondition() {
        let settings = AppSettings(preferences: scratchDefaults())
        #expect(settings.cleanupRule.age(for: nil) == 3)
        #expect(settings.cleanupRule.automaticallyDeletes([]))
        for reason in CleanupReason.allCases {
            #expect(settings.cleanupRule.age(for: reason) == 3)
            #expect(!settings.cleanupRule.automaticallyDeletes([reason]))
        }
    }

    @Test @MainActor func migrationPreservesTheSharedAgeAndEffectiveDeletionChoices() {
        for enabled in [false, true] {
            let preferences = scratchDefaults()
            Preferences.oldSessionDays.write(17, in: preferences)
            Preferences.setOldSessionsDeleteOnTheirOwn(enabled, in: preferences)
            Preferences.setOldSessionAskReasons([.snoozed, .unbuiltDesign], in: preferences)
            let settings = AppSettings(preferences: preferences)
            #expect(settings.cleanupRule.age(for: nil) == 17)
            #expect(settings.cleanupRule.automaticallyDeletes([]) == enabled)
            for reason in CleanupReason.allCases {
                #expect(settings.cleanupRule.age(for: reason) == 17)
                #expect(settings.cleanupRule.automaticallyDeletes([reason])
                        == (enabled && reason != .snoozed && reason != .unbuiltDesign))
            }
        }
    }

    @Test @MainActor func independentEditsPersistAndMigrationDoesNotRunAgain() {
        let preferences = scratchDefaults()
        Preferences.setOldSessionsDeleteOnTheirOwn(false, in: preferences)
        let settings = AppSettings(preferences: preferences)
        settings.oldSessionConditionDays[.unread] = 11
        settings.oldSessionAskReasons.remove(.unread)
        settings.oldSessionDays = 6
        let restored = AppSettings(preferences: preferences)
        #expect(!restored.cleanupRule.automaticallyDeletes([]))
        #expect(restored.cleanupRule.automaticallyDeletes([.unread]))
        #expect(restored.cleanupRule.age(for: .unread) == 11)
        #expect(restored.cleanupRule.age(for: nil) == 6)
        for reason in CleanupReason.allCases where reason != .unread {
            #expect(restored.cleanupRule.age(for: reason) == 3)
            #expect(!restored.cleanupRule.automaticallyDeletes([reason]))
        }
    }

    @Test @MainActor func migrationKeepsTheProtectionsOfOlderPreferences() {
        let preferences = scratchDefaults()
        preferences.set("review", forKey: "oldSessionCleanupPolicy")
        preferences.set(["snoozed"], forKey: "oldSessionAskReasons")
        let settings = AppSettings(preferences: preferences)
        #expect(!settings.cleanupRule.hasAutomaticDeletion)
    }

    @Test @MainActor func dayEntryRejectsInvalidValuesWithoutClamping() {
        for text in ["", " ", "0", "31", "-1", "1.5", "3.0", "abc", "1e1", "9999999999999999999999"] {
            #expect(DayField.validDays(text, in: 1...30) == nil)
        }
        for value in 1...30 {
            #expect(DayField.validDays(String(value), in: 1...30) == value)
        }
        #expect(DayField.validDays(" 12 ", in: 1...30) == 12)
    }
}
