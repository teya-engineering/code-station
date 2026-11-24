import Foundation

// Always two decimals: a session that has spent eight cents should read as $0.08 next
// to one that has spent three dollars, so the column lines up.
enum Money {
    static func short(_ amount: Double) -> String { String(format: "$%.2f", amount) }

    // Plan credits, for an agent that counts in credits rather than dollars. Written the
    // way the Mac's locale writes numbers, to two places at most; a sliver reads as
    // under one hundredth rather than as zero.
    static func credits(_ amount: Double) -> String {
        if amount > 0, amount < 0.01 {
            return "< \(0.01.formatted(.number.precision(.fractionLength(2)))) credits"
        }
        let number = amount.formatted(.number.precision(.fractionLength(0...2)))
        return amount == 1 ? "\(number) credit" : "\(number) credits"
    }
}
