import Foundation
@testable import OverboardCore
import Testing

struct CalculatorEngineTests {
    private func value(_ input: String) -> Double? {
        CalculatorEngine.evaluate(input)?.value
    }

    private func display(_ input: String) -> String? {
        CalculatorEngine.evaluate(input)?.display
    }

    // MARK: - Arithmetic

    @Test func precedence() {
        #expect(self.value("2+2*3") == 8)
        #expect(self.value("(2+2)*3") == 12)
        #expect(self.value("10-4-3") == 3)
    }

    @Test func floatDivision() throws {
        #expect(try abs(#require(self.value("2/3")) - 0.6666666667) < 1e-9)
    }

    @Test func power() {
        #expect(self.value("2^10") == 1024)
        #expect(self.value("(2^3)^2") == 64)
        #expect(self.value("2*3^2") == 18) // ^ binds tighter than *
        #expect(self.value("2^3+1") == 9) // ...and tighter than +
        // ^ is right-associative: 2^3^2 is 2^(3^2) = 512, not (2^3)^2.
        #expect(self.value("2^3^2") == 512)
        #expect(self.value("2^(3-1)") == 4)
        #expect(self.value("pow(2,3)") == 8)
    }

    // #6: unary minus binds looser than ^, so -2^2 is -(2^2), not (-2)^2.
    @Test func unaryMinusBindsLooserThanPower() {
        #expect(self.value("-2^2") == -4)
        #expect(self.value("3*-2^2") == -12)
        #expect(self.value("-2^2+10") == 6)
    }

    // #17: an unspaced negative exponent must evaluate, not silently vanish.
    @Test func negativeExponents() {
        #expect(self.value("2^-2") == 0.25)
        #expect(self.value("10^-3") == 0.001)
        #expect(self.value("2 ^ -2") == 0.25) // spaced form still works
    }

    @Test func unaryMinus() {
        #expect(self.value("3*-2") == -6)
        #expect(self.value("-(2+3)") == -5)
    }

    // #18: comma-decimal locales; normalization is separator-driven and pure.
    @Test func localeSeparatorNormalization() {
        // Comma-decimal locale: "," is the decimal point, "." is grouping.
        #expect(CalculatorEngine.normalizeSeparators("2,5+1", decimalSeparator: ",") == "2.5+1")
        #expect(CalculatorEngine.normalizeSeparators("1.000,5", decimalSeparator: ",") == "1000.5")
        // Period-decimal locale: commas are left for the parser (arg separators
        // like max(3,7)), so they're untouched here.
        #expect(CalculatorEngine.normalizeSeparators("max(3,7)", decimalSeparator: ".") == "max(3,7)")
        #expect(CalculatorEngine.normalizeSeparators("2.5+1", decimalSeparator: ".") == "2.5+1")
    }

    @Test func functionsAndConstants() throws {
        #expect(self.value("sqrt(16)") == 4)
        #expect(self.value("max(3, 7) * 2") == 14)
        #expect(try abs(#require(self.value("pi * 2")) - .pi * 2) < 1e-12)
        #expect(try abs(#require(self.value("e + 1")) - (M_E + 1)) < 1e-12)
    }

    // MARK: - Percent sugar

    @Test func percent() {
        #expect(self.value("20% * 50") == 10)
        #expect(self.value("15% of 80") == 12)
        #expect(self.value("100 + 10%") == 100.1)
    }

    @Test func percentOfIsCaseInsensitive() {
        #expect(self.value("15% OF 80") == 12)
    }

    // MARK: - Gating

    @Test func bareNumbersAreNotMath() {
        #expect(CalculatorEngine.evaluate("42") == nil)
        #expect(CalculatorEngine.evaluate("-3.14") == nil)
        #expect(CalculatorEngine.evaluate("1,000") == nil)
        #expect(CalculatorEngine.evaluate("  7  ") == nil)
    }

    @Test func proseIsNotMath() {
        #expect(CalculatorEngine.evaluate("hello world") == nil)
        #expect(CalculatorEngine.evaluate("2 cups of flour") == nil)
        #expect(CalculatorEngine.evaluate("meeting at 3+ pm sharp") == nil)
        #expect(CalculatorEngine.evaluate("Package.swift") == nil)
    }

    @Test func malformedInputNeverTraps() {
        for junk in ["", "2+", "(2", "++", "2 2", "()", "%", "of of", "1..2+1", "🦀+1",
                     "^2", "2^", "^", "2^^3", "^^"]
        {
            #expect(CalculatorEngine.evaluate(junk) == nil, "expected nil for \(junk)")
        }
    }

    @Test func hugeInputIsRejected() {
        let huge = String(repeating: "1+", count: 5000) + "1"
        #expect(CalculatorEngine.evaluate(huge) == nil)
    }

    @Test func nonFiniteResultsAreRejected() {
        #expect(CalculatorEngine.evaluate("1/0") == nil)
        #expect(CalculatorEngine.evaluate("0/0") == nil)
    }

    // MARK: - Formatting

    @Test func integralValuesDropDecimals() {
        #expect(self.display("2+2") == "4")
        #expect(self.display("10/4*2") == "5")
    }

    @Test func fractionsShowTenSignificantDigits() {
        #expect(self.display("2/3") == "0.6666666667")
    }

    @Test func negativeResults() {
        #expect(self.display("2-10") == "-8")
    }

    // #30: negative zero must display as "0", never "-0".
    @Test func negativeZeroDisplaysAsZero() {
        #expect(self.display("0*-5") == "0")
        #expect(self.display("-0") == nil) // bare number, no row (unchanged)
    }
}
