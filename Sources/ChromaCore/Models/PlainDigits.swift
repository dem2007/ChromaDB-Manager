import Foundation

public extension BinaryInteger {
    /// The number written out digit by digit, with no thousands separator.
    ///
    /// `String(localized:)` formats an interpolated integer through the current
    /// locale, which is right for a quantity («документов: 12 345») and wrong
    /// for an identifier: port 8000 came out as «8 000», and a vector of 1024
    /// components as «1 024». Ports, PIDs and dimensions go through this.
    var plainDigits: String { String(describing: self) }
}
