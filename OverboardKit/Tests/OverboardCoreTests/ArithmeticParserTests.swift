import Foundation
@testable import OverboardCore
import Testing

/// The parser underneath `CalculatorEngine`. `CalculatorEngineTests` covers
/// the user-facing contract (gating, sugar, formatting); this pins the grammar
/// itself, including the inputs the gate would never let through.
struct ArithmeticParserTests {
    private func value(_ input: String) -> Double? {
        ArithmeticParser.evaluate(input)
    }

    // MARK: - Precedence and associativity

    @Test func precedenceClimbsFromAdditionToPower() {
        #expect(self.value("2+2*3") == 8)
        #expect(self.value("2*3+2") == 8)
        #expect(self.value("2*3^2") == 18)
        #expect(self.value("2^3+1") == 9)
        #expect(self.value("12/3/2") == 2) // / is left-associative
        #expect(self.value("10-4-3") == 3) // ...and so is -
    }

    @Test func powerIsRightAssociative() {
        #expect(self.value("2^3^2") == 512)
        #expect(self.value("(2^3)^2") == 64)
    }

    @Test func unaryMinusBindsLooserThanPower() {
        #expect(self.value("-2^2") == -4)
        #expect(self.value("-2^2+10") == 6)
        #expect(self.value("3*-2^2") == -12)
        // ...but the exponent carries its own sign.
        #expect(self.value("2^-2") == 0.25)
        #expect(self.value("2^-1^2") == 0.5)
    }

    @Test func unaryOperatorsStack() {
        #expect(self.value("--3") == 3)
        #expect(self.value("+-3") == -3)
        #expect(self.value("3*-2") == -6)
        #expect(self.value("-(2+3)") == -5)
    }

    @Test func nestedParenthesesGroupInnermostFirst() {
        #expect(self.value("((2+3)*(4-1))") == 15)
        #expect(self.value("2*(3+(4*(5-3)))") == 22)
        #expect(self.value("max(2, min(9, 3+4))") == 7)
    }

    // MARK: - Percent and modulo

    /// `%` is percent when nothing follows it, and modulo between operands.
    @Test func percentSuffixAndInfixModulo() {
        #expect(self.value("10%") == 0.1)
        #expect(self.value("20% * 50") == 10)
        #expect(self.value("100 + 10%") == 100.1)
        #expect(self.value("10 % 3") == 1)
        #expect(self.value("10.5 % 3") == 1.5)
    }

    // MARK: - Functions, constants, numbers

    @Test func functionsAndConstants() throws {
        #expect(self.value("sqrt(16)") == 4)
        #expect(self.value("pow(2,3)") == 8)
        #expect(self.value("abs(-4)") == 4)
        #expect(self.value("floor(2.7)") == 2)
        #expect(self.value("ceil(2.1)") == 3)
        #expect(self.value("round(2.5)") == 3)
        #expect(self.value("min(3, 7, 2)") == 2)
        #expect(self.value("max(3, 7, 2)") == 7)
        #expect(try abs(#require(self.value("log(e)")) - 1) < 1e-12)
        #expect(try abs(#require(self.value("pi")) - .pi) < 1e-12)
    }

    @Test func wrongArityAndUnknownNamesFail() {
        #expect(self.value("max(3)") == nil) // variadic, but at least two
        #expect(self.value("sqrt(4, 9)") == nil)
        #expect(self.value("tan(1)") == nil) // never part of this grammar
        #expect(self.value("nope") == nil)
    }

    @Test func numbersAcceptDecimalsAndExponents() throws {
        #expect(self.value("1.5+1.5") == 3)
        #expect(self.value("1e3+1") == 1001)
        #expect(self.value("1.5E2") == 150)
        // `e` after a number is only an exponent when digits follow it.
        #expect(try abs(#require(self.value("2*e")) - 2 * M_E) < 1e-12)
    }

    // MARK: - Malformed input

    @Test(arguments: [
        "", "   ", "2+", "2*", "(2", "2)", "()", "((1+2)", "1..2", "2 2",
        "^2", "2^", "2^^3", "+", "sqrt", "sqrt(", "sqrt()", "max(1,)", "3 4 5",
        "2 + + ", "1,2", "#", "2 $ 3",
    ])
    func malformedInputReturnsNil(input: String) {
        #expect(ArithmeticParser.evaluate(input) == nil, "expected nil for \(input)")
    }

    @Test func deeplyNestedInputIsRejectedRatherThanOverflowingTheStack() {
        let deep = String(repeating: "(", count: 500) + "1" + String(repeating: ")", count: 500)
        #expect(ArithmeticParser.evaluate(deep) == nil)
    }

    // MARK: - Non-finite and very large values

    /// The parser reports what IEEE arithmetic produces; rejecting non-finite
    /// results is `CalculatorEngine`'s job, so the launcher shows no row.
    @Test func divisionByZeroYieldsNonFiniteRatherThanNil() throws {
        #expect(try #require(self.value("1/0")).isInfinite)
        #expect(try #require(self.value("-1/0")).isInfinite)
        #expect(try #require(self.value("0/0")).isNaN)
        #expect(CalculatorEngine.evaluate("1/0") == nil)
        #expect(CalculatorEngine.evaluate("0/0") == nil)
    }

    @Test func veryLargeNumbersSaturateToInfinity() throws {
        #expect(self.value("1e308") == 1e308)
        #expect(try #require(self.value("1e308*10")).isInfinite)
        #expect(try #require(self.value("10^400")).isInfinite)
        #expect(self.value("2^53") == 9_007_199_254_740_992)
    }
}
