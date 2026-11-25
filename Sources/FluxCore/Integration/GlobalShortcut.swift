import Foundation

/// A key with modifiers, stored the way the system's hot-key API takes it: a virtual
/// key code and Carbon modifier flags.
public struct KeyCombo: Codable, Sendable, Hashable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    // Carbon modifier flags (Events.h).
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & (Self.command | Self.shift | Self.option | Self.control)
    }

    /// "⌃⌥⌘D", in the order macOS menus use.
    public var displayString: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    public var isFunctionKey: Bool { Self.functionKeys.contains(keyCode) }

    /// Whether this combination may be taken over system-wide. It must not swallow keys
    /// other apps rely on: plain typing, ⌘ shortcuts (⌘Q, ⌘⇧S …), ⌥ special characters
    /// or ⌃ text editing. So: two of ⌃ ⌥ ⌘ (⇧ optional), or a function key.
    public var isAllowedGlobally: Bool {
        guard Self.keyNames[keyCode] != nil, !Self.modifierOnlyKeys.contains(keyCode) else { return false }
        if isFunctionKey { return true }
        let strong = [Self.control, Self.option, Self.command].filter { modifiers & $0 != 0 }.count
        return strong >= 2
    }

    static let functionKeys: Set<UInt32> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, // F1–F12
        0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A, // F13–F20
    ]
    static let modifierOnlyKeys: Set<UInt32> = [0x37, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x36, 0x39, 0x3F]

    /// Names for the keys of an ANSI (US) layout, by virtual key code.
    static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [
            0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H",
            0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P",
            0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
            0x10: "Y", 0x06: "Z",
            0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7",
            0x1C: "8", 0x19: "9",
            0x18: "=", 0x1B: "-", 0x1E: "]", 0x21: "[", 0x27: "'", 0x29: ";", 0x2A: "\\", 0x2B: ",",
            0x2C: "/", 0x2F: ".", 0x32: "`",
            0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x75: "⌦", 0x35: "⎋",
            0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑", 0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        ]
        let fKeys: [UInt32] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
                               0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
        for (index, code) in fKeys.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()
}

/// What a system-wide shortcut does.
public enum GlobalShortcutAction: String, Codable, Sendable, CaseIterable, Identifiable, CodingKeyRepresentable {
    /// Brings Flux forward with the Add Download sheet, filled from the clipboard.
    case addDownload
    /// Shows the Flux window, or hides Flux when it's already in front.
    case showFlux
    /// Pauses everything running, or resumes what's paused when nothing runs.
    case pauseResumeAll

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .addDownload: "Add download from copied link"
        case .showFlux: "Show or hide Flux"
        case .pauseResumeAll: "Pause or resume all downloads"
        }
    }

    /// ⌃⌥⌘D adds a download; the others start unassigned.
    public static let defaults: [GlobalShortcutAction: KeyCombo] = [
        .addDownload: KeyCombo(keyCode: 0x02, modifiers: KeyCombo.control | KeyCombo.option | KeyCombo.command),
    ]
}
