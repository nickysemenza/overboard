// Generates OverboardKit/Sources/OverboardCore/Emoji/Resources/emoji.json from emojibase-data.
//
// Data derives from Unicode CLDR annotations via the emojibase project
// (https://github.com/milesj/emojibase, MIT license). This script is run
// manually by maintainers to refresh the bundled dataset — it is never
// invoked from CI or the app build.
//
// Usage:
//   swift scripts/generate-emoji-data.swift
//   swift scripts/generate-emoji-data.swift <dataPath> <shortcodesPath>
//
// With no arguments the two source files are downloaded from jsDelivr. Pass
// local file paths (as produced by `curl -sL <url> -o file.json`) to run
// offline, e.g. when the sandbox has no network access.
import Foundation

// MARK: - Input loading

let dataURLString = "https://cdn.jsdelivr.net/npm/emojibase-data@latest/en/data.json"
let shortcodesURLString = "https://cdn.jsdelivr.net/npm/emojibase-data@latest/en/shortcodes/emojibase.json"

func logStatus(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func loadData(localPath: String?, remoteURLString: String, label: String) -> Data {
    if let localPath, !localPath.isEmpty {
        logStatus("Reading \(label) from \(localPath)")
        guard let data = FileManager.default.contents(atPath: localPath) else {
            fatalError("Could not read \(label) at \(localPath)")
        }
        return data
    }

    logStatus("Downloading \(label) from \(remoteURLString)")
    guard let url = URL(string: remoteURLString) else {
        fatalError("Invalid URL for \(label): \(remoteURLString)")
    }

    let semaphore = DispatchSemaphore(value: 0)
    var result: Data?
    var fetchError: Error?
    let task = URLSession.shared.dataTask(with: url) { data, _, error in
        result = data
        fetchError = error
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()

    if let fetchError {
        fatalError("Failed to download \(label): \(fetchError)")
    }
    guard let result else {
        fatalError("No data returned when downloading \(label)")
    }
    return result
}

let arguments = CommandLine.arguments
let dataPathArg = arguments.count > 1 ? arguments[1] : nil
let shortcodesPathArg = arguments.count > 2 ? arguments[2] : nil

let dataData = loadData(localPath: dataPathArg, remoteURLString: dataURLString, label: "emoji data")
let shortcodesData = loadData(localPath: shortcodesPathArg, remoteURLString: shortcodesURLString, label: "shortcodes")

guard let entries = try? JSONSerialization.jsonObject(with: dataData) as? [[String: Any]] else {
    fatalError("Could not parse emoji data JSON as an array of objects")
}

guard let shortcodesRaw = try? JSONSerialization.jsonObject(with: shortcodesData) as? [String: Any] else {
    fatalError("Could not parse shortcodes JSON as an object")
}

var shortcodesByHexcode: [String: [String]] = [:]
for (hexcode, value) in shortcodesRaw {
    if let single = value as? String {
        shortcodesByHexcode[hexcode] = [single]
    } else if let multiple = value as? [String] {
        shortcodesByHexcode[hexcode] = multiple
    }
}

// MARK: - Filtering

/// emojibase `group` (per messages metadata): 0 smileys-emotion, 1 people-body,
/// 2 component, 3 animals-nature, 4 food-drink, 5 travel-places, 6 activities,
/// 7 objects, 8 symbols, 9 flags. Group 2 (skin tones + hair) is dropped below.
let groupToCategory: [Int: String] = [
    0: "smileys",
    1: "people",
    3: "animals",
    4: "food",
    5: "travel",
    6: "activities",
    7: "objects",
    8: "symbols",
    9: "flags",
]
let categoryOrder = ["smileys", "people", "animals", "food", "travel", "activities", "objects", "symbols", "flags"]

let skinToneScalars: Set<UInt32> = [0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF]
func containsSkinToneModifier(_ string: String) -> Bool {
    string.unicodeScalars.contains { skinToneScalars.contains($0.value) }
}

let regionalIndicatorRange: ClosedRange<UInt32> = 0x1F1E6 ... 0x1F1FF
func regionalIndicatorCount(_ string: String) -> Int {
    string.unicodeScalars.count { regionalIndicatorRange.contains($0.value) }
}

struct EmojiEntry {
    let e: String
    let n: String
    let k: [String]
    let c: String
    let v: Double
}

var results: [EmojiEntry] = []
var categoryCounts: [String: Int] = [:]

for entry in entries {
    guard let emoji = entry["emoji"] as? String, !emoji.isEmpty else { continue }
    guard let label = entry["label"] as? String, !label.isEmpty else { continue }
    guard let hexcode = entry["hexcode"] as? String else { continue }
    guard let versionNumber = (entry["version"] as? NSNumber)?.doubleValue else { continue }

    // Fully-qualified guard: emojibase's `emoji` property is always the
    // fully-qualified presentation string, so an empty value is the only
    // way an entry could fail this check.
    if containsSkinToneModifier(emoji) {
        continue
    }

    let category: String
    if let group = (entry["group"] as? NSNumber)?.intValue {
        if group == 2 {
            continue
        } // Components: skin tones + hair styles.
        guard let mapped = groupToCategory[group] else { continue }
        category = mapped
    } else {
        // Entries without a group are almost entirely the 26 standalone
        // regional-indicator letters, which render as a boxed letter, not a
        // flag, unless paired. Only keep them if the string itself already
        // renders as a flag (>=2 regional indicators combined).
        guard regionalIndicatorCount(emoji) >= 2 else { continue }
        category = "flags"
    }

    let name = label.lowercased()

    var keywordsSeen = Set<String>()
    var keywords: [String] = []
    func addKeyword(_ raw: String) {
        let lower = raw.lowercased()
        guard !lower.isEmpty, lower != name else { return }
        guard keywordsSeen.insert(lower).inserted else { return }
        keywords.append(lower)
    }
    if let tags = entry["tags"] as? [String] {
        for tag in tags {
            addKeyword(tag)
        }
    }
    if let shortcodes = shortcodesByHexcode[hexcode] {
        for shortcode in shortcodes {
            addKeyword(shortcode)
        }
    }

    results.append(EmojiEntry(e: emoji, n: name, k: keywords, c: category, v: versionNumber))
    categoryCounts[category, default: 0] += 1
}

// MARK: - JSON encoding (hand-built for deterministic key order + formatting)

func jsonStringEscape(_ string: String) -> String {
    var result = ""
    result.reserveCapacity(string.count)
    for scalar in string.unicodeScalars {
        switch scalar {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        default:
            if scalar.value < 0x20 {
                result += String(format: "\\u%04x", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
    }
    return result
}

func formatVersion(_ version: Double) -> String {
    if version == version.rounded() {
        return String(Int(version))
    }
    var formatted = String(format: "%.2f", version)
    while formatted.hasSuffix("0") {
        formatted.removeLast()
    }
    if formatted.hasSuffix(".") {
        formatted.removeLast()
    }
    return formatted
}

func jsonLine(for entry: EmojiEntry) -> String {
    let keywordsJSON = "[" + entry.k.map { "\"\(jsonStringEscape($0))\"" }.joined(separator: ",") + "]"
    return "{\"e\":\"\(jsonStringEscape(entry.e))\",\"n\":\"\(jsonStringEscape(entry.n))\",\"k\":\(keywordsJSON),\"c\":\"\(jsonStringEscape(entry.c))\",\"v\":\(formatVersion(entry.v))}"
}

var output = "[\n"
output += results.map { jsonLine(for: $0) }.joined(separator: ",\n")
output += "\n]\n"

// MARK: - Write output

let scriptURL = URL(fileURLWithPath: #filePath)
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outputURL = repoRoot.appendingPathComponent("OverboardKit/Sources/OverboardCore/Emoji/Resources/emoji.json")

try! FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try! output.write(to: outputURL, atomically: true, encoding: .utf8)

// MARK: - Report

logStatus("Wrote \(results.count) entries to \(outputURL.path)")
for category in categoryOrder {
    logStatus("  \(category): \(categoryCounts[category] ?? 0)")
}

logStatus("Total: \(results.count)")
