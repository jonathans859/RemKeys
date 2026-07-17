import Foundation

/// One physical key transition, ready to serialize onto the wire.
///
/// Wire format is one line of plain UTF-8 text per transition:
///
///     key <vk> pressed=<0|1>\n
///
/// `<vk>` is a decimal Windows virtual-key code (see `VK`). The naming
/// (`key … pressed=…`) is a convention carried over from an older prototype —
/// it is not an integration point with any screen reader, just the shape the
/// Windows agent parses.
public struct KeyEvent: Equatable, Sendable {
    public let vk: UInt16
    public let pressed: Bool

    public init(vk: UInt16, pressed: Bool) {
        self.vk = vk
        self.pressed = pressed
    }

    /// The exact bytes to write, including the trailing newline that frames
    /// the line.
    public var wireLine: String {
        "key \(vk) pressed=\(pressed ? 1 : 0)\n"
    }

    public var wireData: Data {
        Data(wireLine.utf8)
    }

    /// Parse a single wire line back into an event. Tolerant of surrounding
    /// whitespace and CRLF; returns nil for anything that doesn't match, so a
    /// stray blank line never becomes a phantom keystroke. Mirrors the parser
    /// the Windows agent implements in C#.
    public static func parse(_ line: some StringProtocol) -> KeyEvent? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
        guard fields.count == 3, fields[0] == "key" else { return nil }
        guard let vk = UInt16(fields[1]) else { return nil }
        guard fields[2] == "pressed=1" || fields[2] == "pressed=0" else { return nil }
        return KeyEvent(vk: vk, pressed: fields[2] == "pressed=1")
    }
}
