import Foundation

/// Fallback for the launcher's calculator: unit conversions like `5 mi in km`
/// or `72 f to c`. Tried only after `CalculatorEngine` returns nil
/// (`CalculatorProvider.results` in `QueryRouter.swift`), because a
/// conversion's unit words are exactly the letter-runs `CalculatorEngine`'s
/// math gate is designed to reject.
public enum UnitConversionEngine {
    /// Converts `input` to `CalculatorEngine`'s `Evaluation` shape so the
    /// launcher's orange calculator row needs no idea a conversion happened,
    /// or returns nil when the input doesn't parse as
    /// `<quantity> <unit> (in|to|as) <unit>`, the quantity isn't a valid
    /// arithmetic expression, either unit is unrecognized, or the two units
    /// belong to different physical dimensions (`5 mi in kg`).
    public static func convert(_ input: String) -> CalculatorEngine.Evaluation? {
        guard let parsed = self.parse(input),
              let from = self.aliases[parsed.fromUnit],
              let to = self.aliases[parsed.toUnit],
              from.family == to.family
        else { return nil }
        let expression = CalculatorEngine.normalizeSeparators(parsed.quantityExpression)
        guard let quantity = ArithmeticParser.evaluate(expression), quantity.isFinite else { return nil }
        let converted = Measurement(value: quantity, unit: from.unit).converted(to: to.unit)
        guard converted.value.isFinite else { return nil }
        return CalculatorEngine.Evaluation(value: converted.value, display: self.format(converted.value, unit: to.unit))
    }

    // MARK: - Parsing

    private struct ParsedQuery {
        let quantityExpression: String
        let fromUnit: String
        let toUnit: String
    }

    /// `<quantity> <fromUnit> (in|to|as) <toUnit>`. The quantity capture is
    /// lazy, so it only grows past the shortest match until the fixed tail
    /// — a unit token, the keyword, then a final unit token — fits; that's
    /// what makes `12 in to cm` resolve right-to-left as quantity `12`, unit
    /// `in` (inches), keyword `to`, unit `cm`, rather than reading the first
    /// `in` as the keyword. `wholeMatch` anchors both ends, so there's no
    /// need to spell `^`/`$` out.
    ///
    /// Built fresh per call rather than cached in a static — `Regex` isn't
    /// `Sendable`, and a query is typed at most a few times a second, so
    /// there's no meaningful cost to recompiling the literal.
    private static func parse(_ input: String) -> ParsedQuery? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let match = trimmed.wholeMatch(of: /(.+?)\s+(\S+)\s+(?:in|to|as)\s+(\S+)/) else { return nil }
        return ParsedQuery(
            quantityExpression: String(match.output.1),
            fromUnit: String(match.output.2),
            toUnit: String(match.output.3)
        )
    }

    // MARK: - Formatting

    /// Integral results show no decimals (`120 min`); results at least 1
    /// show two decimals with trailing zeros trimmed (`8.05 km`,
    /// `1.36 kg`); smaller results show four significant figures
    /// (`0.5 GB`) instead of drowning in leading-zero noise.
    private static func format(_ value: Double, unit: Dimension) -> String {
        // Collapse negative zero (e.g. a unit whose converter flips sign),
        // matching CalculatorEngine's own formatting rule.
        let value = value == 0 ? 0 : value
        let text: String = if value == value.rounded(), abs(value) < 1e15 {
            String(format: "%.0f", value)
        } else if abs(value) >= 1 {
            self.trimTrailingZeros(String(format: "%.2f", value))
        } else {
            self.trimTrailingZeros(String(format: "%.4g", value))
        }
        return "\(text) \(unit.symbol)"
    }

    private static func trimTrailingZeros(_ text: String) -> String {
        guard text.contains(".") else { return text }
        var result = text
        while result.hasSuffix("0") {
            result.removeLast()
        }
        if result.hasSuffix(".") {
            result.removeLast()
        }
        return result
    }

    // MARK: - Unit aliases

    /// Groups aliases so two units only convert when they share a family —
    /// `Measurement.converted(to:)` would trap or misbehave across
    /// unrelated `Dimension` subclasses, so this is checked before it's
    /// ever called.
    private enum Family {
        case length, mass, temperature, duration, information, volume, speed, area, energy
    }

    private struct UnitAlias {
        let family: Family
        let unit: Dimension
    }

    /// Every alias lowercase-folded (matched against a lowercased query).
    /// `UnitDuration` has no built-in day/week, so those two are defined
    /// just below as plain linear multiples of the second.
    private static let aliases: [String: UnitAlias] = [
        // Length
        "mm": UnitAlias(family: .length, unit: UnitLength.millimeters),
        "cm": UnitAlias(family: .length, unit: UnitLength.centimeters),
        "m": UnitAlias(family: .length, unit: UnitLength.meters),
        "km": UnitAlias(family: .length, unit: UnitLength.kilometers),
        "in": UnitAlias(family: .length, unit: UnitLength.inches),
        "inch": UnitAlias(family: .length, unit: UnitLength.inches),
        "inches": UnitAlias(family: .length, unit: UnitLength.inches),
        "ft": UnitAlias(family: .length, unit: UnitLength.feet),
        "feet": UnitAlias(family: .length, unit: UnitLength.feet),
        "foot": UnitAlias(family: .length, unit: UnitLength.feet),
        "yd": UnitAlias(family: .length, unit: UnitLength.yards),
        "mi": UnitAlias(family: .length, unit: UnitLength.miles),
        "mile": UnitAlias(family: .length, unit: UnitLength.miles),
        "miles": UnitAlias(family: .length, unit: UnitLength.miles),
        "nmi": UnitAlias(family: .length, unit: UnitLength.nauticalMiles),

        // Mass
        "mg": UnitAlias(family: .mass, unit: UnitMass.milligrams),
        "g": UnitAlias(family: .mass, unit: UnitMass.grams),
        "kg": UnitAlias(family: .mass, unit: UnitMass.kilograms),
        "oz": UnitAlias(family: .mass, unit: UnitMass.ounces),
        "lb": UnitAlias(family: .mass, unit: UnitMass.pounds),
        "lbs": UnitAlias(family: .mass, unit: UnitMass.pounds),
        "pound": UnitAlias(family: .mass, unit: UnitMass.pounds),
        "pounds": UnitAlias(family: .mass, unit: UnitMass.pounds),
        "st": UnitAlias(family: .mass, unit: UnitMass.stones),
        "t": UnitAlias(family: .mass, unit: UnitMass.metricTons),

        // Temperature
        "c": UnitAlias(family: .temperature, unit: UnitTemperature.celsius),
        "f": UnitAlias(family: .temperature, unit: UnitTemperature.fahrenheit),
        "k": UnitAlias(family: .temperature, unit: UnitTemperature.kelvin),
        "celsius": UnitAlias(family: .temperature, unit: UnitTemperature.celsius),
        "fahrenheit": UnitAlias(family: .temperature, unit: UnitTemperature.fahrenheit),
        "kelvin": UnitAlias(family: .temperature, unit: UnitTemperature.kelvin),
        "°c": UnitAlias(family: .temperature, unit: UnitTemperature.celsius),
        "°f": UnitAlias(family: .temperature, unit: UnitTemperature.fahrenheit),

        // Duration
        "s": UnitAlias(family: .duration, unit: UnitDuration.seconds),
        "sec": UnitAlias(family: .duration, unit: UnitDuration.seconds),
        "second": UnitAlias(family: .duration, unit: UnitDuration.seconds),
        "seconds": UnitAlias(family: .duration, unit: UnitDuration.seconds),
        "min": UnitAlias(family: .duration, unit: UnitDuration.minutes),
        "minute": UnitAlias(family: .duration, unit: UnitDuration.minutes),
        "minutes": UnitAlias(family: .duration, unit: UnitDuration.minutes),
        "h": UnitAlias(family: .duration, unit: UnitDuration.hours),
        "hr": UnitAlias(family: .duration, unit: UnitDuration.hours),
        "hour": UnitAlias(family: .duration, unit: UnitDuration.hours),
        "hours": UnitAlias(family: .duration, unit: UnitDuration.hours),
        "d": UnitAlias(family: .duration, unit: UnitDuration.days),
        "day": UnitAlias(family: .duration, unit: UnitDuration.days),
        "days": UnitAlias(family: .duration, unit: UnitDuration.days),
        "w": UnitAlias(family: .duration, unit: UnitDuration.weeks),
        "week": UnitAlias(family: .duration, unit: UnitDuration.weeks),
        "weeks": UnitAlias(family: .duration, unit: UnitDuration.weeks),

        // Information storage
        "bit": UnitAlias(family: .information, unit: UnitInformationStorage.bits),
        "b": UnitAlias(family: .information, unit: UnitInformationStorage.bytes),
        "byte": UnitAlias(family: .information, unit: UnitInformationStorage.bytes),
        "bytes": UnitAlias(family: .information, unit: UnitInformationStorage.bytes),
        "kb": UnitAlias(family: .information, unit: UnitInformationStorage.kilobytes),
        "mb": UnitAlias(family: .information, unit: UnitInformationStorage.megabytes),
        "gb": UnitAlias(family: .information, unit: UnitInformationStorage.gigabytes),
        "tb": UnitAlias(family: .information, unit: UnitInformationStorage.terabytes),
        "pb": UnitAlias(family: .information, unit: UnitInformationStorage.petabytes),
        "kib": UnitAlias(family: .information, unit: UnitInformationStorage.kibibytes),
        "mib": UnitAlias(family: .information, unit: UnitInformationStorage.mebibytes),
        "gib": UnitAlias(family: .information, unit: UnitInformationStorage.gibibytes),
        "tib": UnitAlias(family: .information, unit: UnitInformationStorage.tebibytes),

        // Volume
        "ml": UnitAlias(family: .volume, unit: UnitVolume.milliliters),
        "l": UnitAlias(family: .volume, unit: UnitVolume.liters),
        "cup": UnitAlias(family: .volume, unit: UnitVolume.cups),
        "cups": UnitAlias(family: .volume, unit: UnitVolume.cups),
        "tsp": UnitAlias(family: .volume, unit: UnitVolume.teaspoons),
        "tbsp": UnitAlias(family: .volume, unit: UnitVolume.tablespoons),
        "floz": UnitAlias(family: .volume, unit: UnitVolume.fluidOunces),
        "pt": UnitAlias(family: .volume, unit: UnitVolume.pints),
        "qt": UnitAlias(family: .volume, unit: UnitVolume.quarts),
        "gal": UnitAlias(family: .volume, unit: UnitVolume.gallons),

        // Speed
        "mph": UnitAlias(family: .speed, unit: UnitSpeed.milesPerHour),
        "kph": UnitAlias(family: .speed, unit: UnitSpeed.kilometersPerHour),
        "kmh": UnitAlias(family: .speed, unit: UnitSpeed.kilometersPerHour),
        "m/s": UnitAlias(family: .speed, unit: UnitSpeed.metersPerSecond),
        "knot": UnitAlias(family: .speed, unit: UnitSpeed.knots),
        "knots": UnitAlias(family: .speed, unit: UnitSpeed.knots),

        // Area
        "sqft": UnitAlias(family: .area, unit: UnitArea.squareFeet),
        "sqm": UnitAlias(family: .area, unit: UnitArea.squareMeters),
        "acre": UnitAlias(family: .area, unit: UnitArea.acres),
        "acres": UnitAlias(family: .area, unit: UnitArea.acres),
        "ha": UnitAlias(family: .area, unit: UnitArea.hectares),

        // Energy
        "j": UnitAlias(family: .energy, unit: UnitEnergy.joules),
        "kj": UnitAlias(family: .energy, unit: UnitEnergy.kilojoules),
        "cal": UnitAlias(family: .energy, unit: UnitEnergy.calories),
        "kcal": UnitAlias(family: .energy, unit: UnitEnergy.kilocalories),
        "kwh": UnitAlias(family: .energy, unit: UnitEnergy.kilowattHours),
    ]
}

private extension UnitDuration {
    /// Foundation ships seconds/minutes/hours only; days and weeks are
    /// plain linear multiples of the second, same as `UnitConverterLinear`
    /// backs every built-in duration unit.
    static let days = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86400))
    static let weeks = UnitDuration(symbol: "w", converter: UnitConverterLinear(coefficient: 604_800))
}
