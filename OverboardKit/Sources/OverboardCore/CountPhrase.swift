import Foundation

/// Builds "1 file" / "2 files" without a hand-written English plural table, so
/// the only thing a translation has to supply is the noun.
///
/// The usual spelling for this is `String(localized: "^[\(count) file](inflect:
/// true)")`, but that markup is only expanded when the string is found in a
/// *compiled* strings table: SwiftPM copies a String Catalog into the resource
/// bundle without compiling it, so the markup would ship to users verbatim.
/// `AttributedString.inflected()` runs the same Foundation inflection engine
/// directly on the source string, which works in a package target and under
/// `swift test`.
public enum CountPhrase {
    /// `count` formatted for the current locale, followed by `noun` agreed with
    /// it in number. Nouns Foundation's lexicon doesn't know come back
    /// unchanged, so pass ordinary dictionary words ("character", not "char").
    public static func string(_ count: Int, of noun: String) -> String {
        var phrase = AttributedString("\(count.formatted()) \(noun)")
        var morphology = Morphology()
        morphology.number = count == 1 ? .singular : .plural
        phrase.inflect = .explicit(morphology)
        return String(phrase.inflected().characters)
    }
}
