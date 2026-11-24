import Foundation

// Always two decimals: a session that has spent eight cents should read as $0.08 next
// to one that has spent three dollars, so the column lines up.
enum Money {
    static func short(_ amount: Double) -> String { String(format: "$%.2f", amount) }

    // Plan credits, for an agent that counts in credits rather than dollars. Written the
    // way Kiro writes them and the way dollars are written here: always two decimals with
    // a point, so 0.50 reads like $0.50. A sliver under one hundredth reads as such rather
    // than as zero.
    static func credits(_ amount: Double) -> String {
        if amount > 0, amount < 0.01 { return "< 0.01 credits" }
        return String(format: "%.2f credits", amount)
    }
}
