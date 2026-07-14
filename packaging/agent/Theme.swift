// Phosphor-green CRT palette, shared by both surfaces.
import AppKit

enum Theme {
    static let phosphor = NSColor(srgbRed: 0.20, green: 1.00, blue: 0.20, alpha: 1.0)
    static let phosphorDim = NSColor(srgbRed: 0.11, green: 0.56, blue: 0.11, alpha: 1.0)
    /// Alert color for overdue counts — amber, coherent with the CRT look.
    static let amber = NSColor(srgbRed: 1.00, green: 0.75, blue: 0.20, alpha: 1.0)
    static let screenBg = NSColor(srgbRed: 0.008, green: 0.04, blue: 0.008, alpha: 0.97)
}
