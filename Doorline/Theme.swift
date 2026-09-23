import SwiftUI

extension Color {
    static let doorInk = Color(red: 0.07, green: 0.07, blue: 0.055)
    static let doorSurface = Color(red: 0.11, green: 0.105, blue: 0.09)
    static let doorBrass = Color(red: 0.89, green: 0.69, blue: 0.35)
    static let doorWarn = Color(red: 0.83, green: 0.40, blue: 0.29)
}

extension ShapeStyle where Self == Color {
    static var doorInk: Color { .doorInk }
    static var doorBrass: Color { .doorBrass }
}
