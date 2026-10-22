import Foundation

// The 27.2 SDK added Foundation's own `Date >=` and `Date <=`, which the app calls
// on macOS/iOS 27.2 or later. Some 27.2 betas say 27.2 but don't have them yet,
// so the app crashed there on its first date comparison (MacBook Pro on
// 26B5091g, 10/21). These shadow Foundation's with `<`, which every OS has.
extension Date {
    static func >= (a: Date, b: Date) -> Bool { !(a < b) }
    static func <= (a: Date, b: Date) -> Bool { !(b < a) }
}
