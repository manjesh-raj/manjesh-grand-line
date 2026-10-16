import Foundation


extension Yaml {
  enum TokenType: String {
    case yamlDirective = "%YAML"
    case docStart = "doc-start"
    case docend = "doc-end"
    case comment = "comment"
    case space = "space"
    case newLine = "newline"
    case indent = "indent"
    case dedent = "dedent"
    case null = "null"
    case _true = "true"
    case _false = "false"
    case infinityP = "+infinity"
    case infinityN = "-infinity"
    case nan = "nan"
    case double = "double"
    case int = "int"
    case intOct = "int-oct"
    case intHex = "int-hex"
    case intSex = "int-sex"
    case anchor = "&"
    case alias = "*"
    case comma = ","
    case openSB = "["
    case closeSB = "]"
    case dash = "-"
    case openCB = "{"
    case closeCB = "}"
    case key = "key"
    case keyDQ = "key-dq"
    case keySQ = "key-sq"
    case questionMark = "?"
    case colonFO = ":-flow-out"
    case colonFI = ":-flow-in"
    case colon = ":"
    case literal = "|"
    case folded = ">"
    case reserved = "reserved"
    case stringDQ = "string-dq"
    case stringSQ = "string-sq"
    case stringFI = "string-flow-in"
    case stringFO = "string-flow-out"
    case string = "string"
    case end = "end"
  }
}

private typealias TokenPattern = (type: Yaml.TokenType, pattern: NSRegularExpression)

extension Yaml {
  typealias TokenMatch = (type: Yaml.TokenType, match: String)
}

private let bBreak = "(?:\\r\\n|\\r|\\n)"

// printable non-space chars,
// except `:`(3a), `#`(23), `,`(2c), `[`(5b), `]`(5d), `{`(7b), `}`(7d)
private let safeIn = "\\x21\\x22\\x24-\\x2b\\x2d-\\x39\\x3b-\\x5a\\x5c\\x5e-\\x7a" +
  "\\x7c\\x7e\\x85\\xa0-\\ud7ff\\ue000-\\ufefe\\uff00\\ufffd" +
"\\U00010000-\\U0010ffff"
// with flow indicators: `,`, `[`, `]`, `{`, `}`
private let safeOut = "\\x2c\\x5b\\x5d\\x7b\\x7d" + safeIn
private let plainOutPattern =
"([\(safeOut)]#|:(?![ \\t]|\(bBreak))|[\(safeOut)]|[ \\t])+"
private let plainInPattern =
"([\(safeIn)]#|:(?![ \\t]|\(bBreak))|[\(safeIn)]|[ \\t]|\(bBreak))+"
private let dashPattern = Yaml.Regex.regex("^-([ \\t]+(?!#|\(bBreak))|(?=[ \\t\\n]))")
private let finish = "(?= *(,|\\]|\\}|( #.*)?(\(bBreak)|$)))"

private let tokenPatterns: [TokenPattern] = [
  (.yamlDirective, Yaml.Regex.regex("^%YAML(?= )")),
  (.docStart, Yaml.Regex.regex("^---")),
  (.docend, Yaml.Regex.regex("^\\.\\.\\.")),
  (.comment, Yaml.Regex.regex("^#.*|^\(bBreak) *(#.*)?(?=\(bBreak)|$)")),
  (.space, Yaml.Regex.regex("^ +")),
  (.newLine, Yaml.Regex.regex("^\(bBreak) *")),
  (.dash, dashPattern!),
  (.null, Yaml.Regex.regex("^(null|Null|NULL|~)\(finish)")),
  (._true, Yaml.Regex.regex("^(true|True|TRUE)\(finish)")),
  (._false, Yaml.Regex.regex("^(false|False|FALSE)\(finish)")),
  (.infinityP, Yaml.Regex.regex("^\\+?\\.(inf|Inf|INF)\(finish)")),
  (.infinityN, Yaml.Regex.regex("^-\\.(inf|Inf|INF)\(finish)")),
  (.nan, Yaml.Regex.regex("^\\.(nan|NaN|NAN)\(finish)")),
  (.int, Yaml.Regex.regex("^[-+]?[0-9]+\(finish)")),
  (.intOct, Yaml.Regex.regex("^0o[0-7]+\(finish)")),
  (.intHex, Yaml.Regex.regex("^0x[0-9a-fA-F]+\(finish)")),
  (.intSex, Yaml.Regex.regex("^[0-9]{2}(:[0-9]{2})+\(finish)")),
  (.double, Yaml.Regex.regex("^[-+]?(\\.[0-9]+|[0-9]+(\\.[0-9]*)?)([eE][-+]?[0-9]+)?\(finish)")),
  (.anchor, Yaml.Regex.regex("^&\\w+")),
  (.alias, Yaml.Regex.regex("^\\*\\w+")),
  (.comma, Yaml.Regex.regex("^,")),
  (.openSB, Yaml.Regex.regex("^\\[")),
  (.closeSB, Yaml.Regex.regex("^\\]")),
  (.openCB, Yaml.Regex.regex("^\\{")),
  (.closeCB, Yaml.Regex.regex("^\\}")),
  (.questionMark, Yaml.Regex.regex("^\\?( +|(?=\(bBreak)))")),
  (.colonFO, Yaml.Regex.regex("^:(?!:)")),
  (.colonFI, Yaml.Regex.regex("^:(?!:)")),
  (.literal, Yaml.Regex.regex("^\\|.*")),
  (.folded, Yaml.Regex.regex("^>.*")),
  (.reserved, Yaml.Regex.regex("^[@`]")),
  (.stringDQ, Yaml.Regex.regex("^\"([^\\\\\"]|\\\\(.|\(bBreak)))*\"")),
  (.stringSQ, Yaml.Regex.regex("^'([^']|'')*'")),
  (.stringFO, Yaml.Regex.regex("^\(plainOutPattern)(?=:([ \\t]|\(bBreak))|\(bBreak)|$)")),
  (.stringFI, Yaml.Regex.regex("^\(plainInPattern)")),
]

extension Yaml {
  static func escapeErrorContext (_ text: String) -> String {
    let endIndex = text.index(text.startIndex, offsetBy: 50, limitedBy: text.endIndex) ?? text.endIndex
    let escaped = String(text[..<endIndex])
      |> Yaml.Regex.replace(Yaml.Regex.regex("\\r"), template: "\\\\r")
      |> Yaml.Regex.replace(Yaml.Regex.regex("\\n"), template: "\\\\n")
      |> Yaml.Regex.replace(Yaml.Regex.regex("\""), template: "\\\\\"")
    return "near \"\(escaped)\""
  }
  
  
  // GRANDLINE LOCAL PATCH (YamlSwift tokenizer, linear time) - see
  // Vendor/YamlSwift/README.md's "Local patch: linear-time tokenizer".
  //
  // Upstream re-matched every pattern against the *whole remaining text* and
  // then copied that remainder (`substring(from:)`) for every token, which
  // bridged a fresh `NSString` each time - O(n) per token, O(n^2) per file.
  // Measured in Grand Line: a 400-link reading list took ~7s to parse and a
  // 150-note sticky board ~1.2s. This walks one `NSString` with a moving
  // offset and matches each pattern within `[offset, end)` instead.
  //
  // Measured with a profile, the copy was the smaller half: the cost was
  // ICU's `find` scanning forward through the whole remaining text for every
  // pattern that did not match at the current position, even though every
  // pattern here is anchored with `^`. `.anchored` makes a failing pattern
  // fail at the offset instead.
  //
  // It is the same match, not an approximation of it: `NSRegularExpression`
  // treats a search range's bounds as the string's own bounds by default
  // (anchoring bounds on, transparent bounds off), so `^` matches at the
  // offset, `$` at the end, and no lookaround sees before the offset -
  // exactly what matching against the copied remainder did. And `.anchored`
  // changes nothing for a pattern whose every top-level alternative already
  // begins with `^`, which is true of every pattern this tokenizer uses
  // (`tokenPatterns`, `dashPattern`, and the two block patterns below) and
  // must stay true of any added. Ranges are kept absolute and every
  // substring is cut from the one source string.
  static func tokenize (_ text: String) -> YAMLResult<[TokenMatch]> {
    let source = text as NSString
    let sourceString = source as String
    let length = source.length
    var pos = 0
    var matchList: [TokenMatch] = []
    var indents = [0]
    var insideFlow = 0

    func match (_ regex: NSRegularExpression, at offset: Int) -> NSRange {
      return regex.rangeOfFirstMatch(in: sourceString, options: .anchored,
                                     range: NSMakeRange(offset, length - offset))
    }
    func cut (_ range: NSRange) -> String {
      return source.substring(with: range)
    }
    func remainder (from offset: Int) -> String {
      return source.substring(from: offset)
    }

    next:
      while pos < length {
        for tokenPattern in tokenPatterns {
          let range = match(tokenPattern.pattern, at: pos)
          if range.location != NSNotFound {
            let rangeEnd = range.location + range.length
            switch tokenPattern.type {

            case .newLine:
              let match = cut(range)
              let lastindent = indents.last ?? 0
              let rest = match[match.index(after: match.startIndex)...]
              let spaces = rest.count
              let nestedBlockSequence =
                matchRangeFound(dashPattern!, at: rangeEnd, in: sourceString, length: length)
              if spaces == lastindent {
                matchList.append(TokenMatch(.newLine, match))
              } else if spaces > lastindent {
                if insideFlow == 0 {
                  if matchList.last != nil &&
                    matchList[matchList.endIndex - 1].type == .indent {
                    indents[indents.endIndex - 1] = spaces
                    matchList[matchList.endIndex - 1] = TokenMatch(.indent, match)
                  } else {
                    indents.append(spaces)
                    matchList.append(TokenMatch(.indent, match))
                  }
                }
              } else if nestedBlockSequence && spaces == lastindent - 1 {
                matchList.append(TokenMatch(.newLine, match))
              } else {
                while nestedBlockSequence && spaces < (indents.last ?? 0) - 1
                  || !nestedBlockSequence && spaces < indents.last ?? 0 {
                    indents.removeLast()
                    matchList.append(TokenMatch(.dedent, ""))
                }
                matchList.append(TokenMatch(.newLine, match))
              }

            case .dash, .questionMark:
              let match = cut(range)
              let index = match.index(after: match.startIndex)
              let indent = match.count
              indents.append((indents.last ?? 0) + indent)
              matchList.append(
                TokenMatch(tokenPattern.type, String(match[..<index])))
              matchList.append(TokenMatch(.indent, String(match[index...])))

            case .colonFO:
              if insideFlow > 0 {
                continue
              }
              fallthrough

            case .colonFI:
              let match = cut(range)
              matchList.append(TokenMatch(.colon, match))
              if insideFlow == 0 {
                indents.append((indents.last ?? 0) + 1)
                matchList.append(TokenMatch(.indent, ""))
              }

            case .openSB, .openCB:
              insideFlow += 1
              matchList.append(TokenMatch(tokenPattern.type, cut(range)))

            case .closeSB, .closeCB:
              insideFlow -= 1
              matchList.append(TokenMatch(tokenPattern.type, cut(range)))

            case .literal, .folded:
              matchList.append(TokenMatch(tokenPattern.type, cut(range)))
              pos = rangeEnd
              let lastindent = indents.last ?? 0
              let minindent = 1 + lastindent
              let blockPattern = Yaml.Regex.regex(("^(\(bBreak) *)*(\(bBreak)" +
                "( {\(minindent),})[^ ].*(\(bBreak)( *|\\3.*))*)(?=\(bBreak)|$)"))
              // `splitLead`, over the remainder: the matched lead, and the
              // offset just past it (or no lead, and the offset unchanged).
              let leadRange = match(blockPattern!, at: pos)
              let lead: String
              if leadRange.location == NSNotFound {
                lead = ""
              } else {
                let leadEnd = leadRange.location + leadRange.length
                lead = cut(NSMakeRange(pos, leadEnd - pos))
                pos = leadEnd
              }
              let block = (lead
                |> Yaml.Regex.replace(Yaml.Regex.regex("^\(bBreak)"), template: "")
                |> Yaml.Regex.replace(Yaml.Regex.regex("^ {0,\(lastindent)}"), template: "")
                |> Yaml.Regex.replace(Yaml.Regex.regex("\(bBreak) {0,\(lastindent)}"), template: "\n")
                ) + (matchRangeFound(Yaml.Regex.regex("^\(bBreak)"), at: pos, in: sourceString, length: length)
                  && lead.endIndex > lead.startIndex
                  ? "\n" : "")
              matchList.append(TokenMatch(.string, block))
              continue next

            case .stringFO:
              if insideFlow > 0 {
                continue
              }
              let indent = (indents.last ?? 0)
              let blockPattern = Yaml.Regex.regex(("^\(bBreak)( *| {\(indent),}" +
                "\(plainOutPattern))(?=\(bBreak)|$)"))
              var block = cut(range)
                |> Yaml.Regex.replace(Yaml.Regex.regex("^[ \\t]+|[ \\t]+$"), template: "")
              pos = rangeEnd
              while true {
                let range = match(blockPattern!, at: pos)
                if range.location == NSNotFound {
                  break
                }
                let s = cut(range)
                block += "\n" +
                  Yaml.Regex.replace(Yaml.Regex.regex("^\(bBreak)[ \\t]*|[ \\t]+$"), template: "")(s)
                pos = range.location + range.length
              }
              matchList.append(TokenMatch(.string, block))
              continue next

            case .stringFI:
              let match = cut(range)
                |> Yaml.Regex.replace(Yaml.Regex.regex("^[ \\t]|[ \\t]$"), template: "")
              matchList.append(TokenMatch(.string, match))

            case .reserved:
              return fail(escapeErrorContext(remainder(from: pos)))

            default:
              matchList.append(TokenMatch(tokenPattern.type, cut(range)))
            }
            pos = rangeEnd
            continue next
          }
        }
        return fail(escapeErrorContext(remainder(from: pos)))
    }
    while indents.count > 1 {
      indents.removeLast()
      matchList.append((.dedent, ""))
    }
    matchList.append((.end, ""))
    return lift(matchList)
  }

  /// Whether `regex` matches at `offset`, over `[offset, end)` - the linear
  /// patch's stand-in for `Yaml.Regex.matches(substring(from:), regex:)`.
  private static func matchRangeFound (_ regex: NSRegularExpression?, at offset: Int,
                                       in string: String, length: Int) -> Bool {
    guard let regex else { return false }
    return regex.rangeOfFirstMatch(in: string, options: .anchored,
                                   range: NSMakeRange(offset, length - offset)).location != NSNotFound
  }
}
