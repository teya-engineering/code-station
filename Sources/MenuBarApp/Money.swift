import Foundation

// Always two decimals: a session that has spent eight cents should read as $0.08 next
// to one that has spent three dollars, so the column lines up.
enum Money {
    static func short(_ amount: Double) -> String { String(format: "$%.2f", amount) }
}
