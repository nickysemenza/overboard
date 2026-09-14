import Foundation
@testable import OverboardCore
import Testing

struct UnitConversionEngineTests {
    private func display(_ input: String) -> String? {
        UnitConversionEngine.convert(input)?.display
    }

    // MARK: - Conversions

    @Test func lengthMilesToKilometers() {
        #expect(self.display("5 mi in km") == "8.05 km")
    }

    @Test func temperatureFahrenheitToCelsius() {
        #expect(self.display("72 f to c") == "22.22 °C")
    }

    @Test func massPoundsToKilograms() {
        #expect(self.display("3 lb in kg") == "1.36 kg")
    }

    @Test func durationHoursToMinutes() {
        #expect(self.display("2 hours in minutes") == "120 min")
    }

    @Test func informationMegabytesToGigabytes() {
        #expect(self.display("500 MB in GB") == "0.5 GB")
    }

    /// `in` here is the source unit (inches), not the `in|to|as` keyword —
    /// the second `to` is the keyword this time.
    @Test func inchesToCentimetersWithInAsTheUnit() {
        #expect(self.display("12 in to cm") == "30.48 cm")
    }

    /// The quantity is a full arithmetic expression, evaluated via
    /// `ArithmeticParser` before the unit conversion happens.
    @Test func quantityCanBeAnExpression() {
        #expect(self.display("2*3 mi in km") == "9.66 km")
    }

    // MARK: - Gating

    @Test func mismatchedDimensionsAreRejected() {
        #expect(UnitConversionEngine.convert("5 mi in kg") == nil)
    }

    @Test func unknownUnitsAreRejected() {
        #expect(UnitConversionEngine.convert("5 xyz in km") == nil)
        #expect(UnitConversionEngine.convert("5 mi in xyz") == nil)
    }

    @Test func proseIsNotAConversion() {
        #expect(UnitConversionEngine.convert("2 cups of flour") == nil)
        #expect(UnitConversionEngine.convert("5 in") == nil)
    }
}
