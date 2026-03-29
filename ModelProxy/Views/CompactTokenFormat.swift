import Foundation

extension Int {
    /// Compact token count display: raw below 1K, "12.3K" below 1M, "1.2M" above.
    var compactTokenString: String {
        if self < 1_000 {
            return "\(self)"
        } else if self < 1_000_000 {
            let k = Double(self) / 1_000
            return k.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(k))K"
                : String(format: "%.1fK", k)
        } else {
            let m = Double(self) / 1_000_000
            return m.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(m))M"
                : String(format: "%.1fM", m)
        }
    }
}
