import Foundation

/// STATE_UPDATEの構文だけを扱うFoundation-only parserの結果。
/// Payloadの意味（StoryStatePatchへのdecode）はアプリ側に残し、
/// この型がStorySessionServiceへ依存しないようにする。
enum StoryStateMetadataParseResult: Equatable {
    case absent(visibleText: String)
    case valid(visibleText: String, payload: Data)
    case invalid(visibleText: String)
}

enum StoryStateMetadataParser {
    private static let markers = ["STATE_UPDATE:", "状態更新:"]
    private static let allowedKeys: Set<String> = [
        "location",
        "timeOfDay",
        "mood",
        "weather",
        "relationshipStage",
        "characterUpdates",
        "inventoryChanges",
        "activeGoals"
    ]

    static func parse(_ text: String) -> StoryStateMetadataParseResult {
        let markerRanges = allMarkerRanges(in: text)
        guard let firstMarker = markerRanges.first else {
            return .absent(visibleText: text)
        }

        let visiblePrefix = String(text[..<firstMarker.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard markerRanges.count == 1 else {
            return .invalid(visibleText: visiblePrefix)
        }

        let suffix = String(text[firstMarker.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard suffix.first == "{" else {
            return .invalid(visibleText: visiblePrefix)
        }

        guard let close = balancedObjectEnd(in: suffix) else {
            return .invalid(visibleText: visiblePrefix)
        }

        let jsonText = String(suffix[...close])
        let trailingStart = suffix.index(after: close)
        let trailing = suffix[trailingStart...]
        guard trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let payload = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload),
              let dictionary = object as? [String: Any],
              !dictionary.isEmpty,
              dictionary.keys.contains(where: allowedKeys.contains) else {
            return .invalid(visibleText: visiblePrefix)
        }

        return .valid(visibleText: visiblePrefix, payload: payload)
    }

    private static func allMarkerRanges(in text: String) -> [Range<String.Index>] {
        markers
            .flatMap { marker -> [Range<String.Index>] in
                var ranges: [Range<String.Index>] = []
                var searchStart = text.startIndex
                while searchStart < text.endIndex,
                      let range = text.range(
                          of: marker,
                          options: [.caseInsensitive],
                          range: searchStart..<text.endIndex
                      ) {
                    ranges.append(range)
                    guard range.upperBound < text.endIndex else { break }
                    searchStart = range.upperBound
                }
                return ranges
            }
            .sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Finds the closing brace of the first JSON object while respecting
    /// quoted braces and escaped quotes inside JSON strings.
    private static func balancedObjectEnd(in text: String) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth < 0 { return nil }
                if depth == 0 { return index }
            }
        }
        return nil
    }
}
