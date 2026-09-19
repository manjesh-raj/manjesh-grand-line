// Manjesh Grand Line - native macOS app.
//
// Permanent coverage for the Whiteboard's component artwork and for the two
// label bugs the icon work was dispatched to fix
// (`fm/grand-line-whiteboard-component-icons-overhaul`).
//
// Pure logic, so it **runs in CI** beside `WhiteboardDSLSelfTest`. The half
// that genuinely needs a live canvas - proving the caption really reaches the
// screen in full - is in `WhiteboardViewSelfTest`, which is window-backed.
//
// What each group is for:
//
//  - **The artwork table is complete and honest.** `WhiteboardIconLibrary`
//    degrades to "no icon, just a captioned box" for a component the generated
//    table has nothing for, which is the right behaviour and also the reason a
//    missing entry has to be asserted: it ships looking exactly like the old
//    palette rather than like a defect.
//  - **The generated file and the hand-written enum agree.** The generator has
//    no Swift runtime, so `DiagramComponentRole`'s hues are typed out a second
//    time in `Scripts/build-whiteboard-icons.py`. Two copies of a colour table
//    is precisely the shape that drifts.
//  - **The captions carry no presentation selector.** See `WhiteboardLabel` for
//    the measured reason; this is the source-of-truth assertion that the
//    palette's own captions cannot reintroduce it.

// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts that every file in this directory carries it.
#if FM_SELFTESTS

import Foundation

enum WhiteboardIconsSelfTest {

    static func run() -> Bool {
        var ok = true
        func check(_ condition: Bool, _ message: String) {
            SelfTestAssertions.record(condition, message, &ok)
        }

        checkEveryComponentHasArtwork(check)
        checkArtworkIsUsableSVG(check)
        checkHuesMatchTheRoles(check)
        checkIconsAreDistinct(check)
        checkFileIDsAreStableAndUnique(check)
        checkCaptionsCarryNoPresentationSelector(check)
        checkLabelSanitiser(check)

        print(ok ? "WhiteboardIconsSelfTest: OK" : "WhiteboardIconsSelfTest: FAILURES")
        return ok
    }

    // MARK: Artwork

    private static func checkEveryComponentHasArtwork(_ check: (Bool, String) -> Void) {
        for component in DiagramComponent.allCases {
            check(WhiteboardIconLibrary.hasArtwork(component),
                  "artwork: \(component.rawValue) has none - run Scripts/build-whiteboard-icons.py")
            check(WhiteboardIcons.symbolNames[component.keyword] != nil,
                  "artwork: \(component.rawValue) is not in the generated symbol table")
        }
        // And nothing generated for a component that no longer exists, which is
        // how a rename leaves a keyword behind that nothing can ever draw.
        let keywords = Set(DiagramComponent.allCases.map(\.keyword))
        for generated in WhiteboardIcons.dataURLs.keys {
            check(keywords.contains(generated),
                  "artwork: generated \"\(generated)\", which is no component's keyword")
        }
    }

    private static func checkArtworkIsUsableSVG(_ check: (Bool, String) -> Void) {
        for component in DiagramComponent.allCases {
            guard let url = WhiteboardIcons.dataURLs[component.keyword] else { continue }
            let prefix = "data:image/svg+xml;base64,"
            guard url.hasPrefix(prefix) else {
                check(false, "artwork: \(component.rawValue) is not a base64 SVG data URL")
                continue
            }
            guard let data = Data(base64Encoded: String(url.dropFirst(prefix.count))),
                  let svg = String(data: data, encoding: .utf8) else {
                check(false, "artwork: \(component.rawValue) does not decode")
                continue
            }
            check(svg.hasPrefix("<svg") && svg.hasSuffix("</svg>"),
                  "artwork: \(component.rawValue) is not a whole SVG document")
            // A glyph with no path is a blank chip, which renders perfectly and
            // says nothing - the one failure a "does it decode" check misses.
            check(svg.contains("<path d=\""),
                  "artwork: \(component.rawValue) carries no glyph path")
            check(!svg.contains("<script"), "artwork: \(component.rawValue) carries a script")
        }
    }

    private static func checkHuesMatchTheRoles(_ check: (Bool, String) -> Void) {
        for component in DiagramComponent.allCases {
            guard let generated = WhiteboardIcons.glyphHexes[component.keyword] else {
                check(false, "hue: \(component.rawValue) has no generated hue")
                continue
            }
            check(generated.lowercased() == component.role.strokeColor.lowercased(),
                  "hue: \(component.rawValue) is drawn \(generated) but its role is \(component.role.strokeColor)")
            // The hue has to be in the artwork, not merely recorded beside it.
            if let url = WhiteboardIcons.dataURLs[component.keyword],
               let data = Data(base64Encoded: String(url.dropFirst("data:image/svg+xml;base64,".count))),
               let svg = String(data: data, encoding: .utf8) {
                check(svg.lowercased().contains(generated.lowercased()),
                      "hue: \(component.rawValue)'s artwork does not use \(generated)")
            }
        }
    }

    private static func checkIconsAreDistinct(_ check: (Bool, String) -> Void) {
        // The captain's complaint was that every component read as the same
        // plain box. Two components sharing one glyph *and* one hue would be
        // indistinguishable on the canvas, which is that complaint returning by
        // another route - so the pair, not the glyph alone, has to be unique.
        var seen: [String: String] = [:]
        for component in DiagramComponent.allCases {
            guard let symbol = WhiteboardIcons.symbolNames[component.keyword] else { continue }
            let signature = "\(symbol)|\(component.role.strokeColor)"
            if let other = seen[signature] {
                check(false, "distinct: \(component.rawValue) draws exactly like \(other)")
            }
            seen[signature] = component.rawValue
        }
    }

    private static func checkFileIDsAreStableAndUnique(_ check: (Bool, String) -> Void) {
        var ids = Set<String>()
        for component in DiagramComponent.allCases {
            let id = WhiteboardIconLibrary.fileID(for: component)
            check(id.contains(component.keyword),
                  "fileID: \(component.rawValue) is not keyed to its own keyword")
            check(ids.insert(id).inserted, "fileID: \(id) is used by more than one component")
        }
        // Deduplication across a whole diagram, in first-appearance order: the
        // same component twice must send its artwork once, and the order has to
        // be stable or the same text stops producing the same output.
        let twice = WhiteboardIconLibrary.files(for: [.database, .server, .database])
        check(twice.count == 2, "fileID: a repeated component sent \(twice.count) files")
        check((twice.first?["id"] as? String) == WhiteboardIconLibrary.fileID(for: .database),
              "fileID: files are not in first-appearance order")
    }

    // MARK: The two label bugs

    private static func checkCaptionsCarryNoPresentationSelector(_ check: (Bool, String) -> Void) {
        for component in DiagramComponent.allCases {
            let diagram = DiagramDSL.component(component, index: 0)
            guard let caption = (diagram.elements.first?["label"] as? [String: Any])?["text"] as? String else {
                check(false, "caption: \(component.rawValue) has no caption")
                continue
            }
            check(!WhiteboardLabel.wouldTruncate(caption),
                  "caption: \(component.rawValue) carries a variation selector, which truncates")
            check(caption == component.title,
                  "caption: \(component.rawValue) reads \"\(caption)\" rather than its title")
        }
    }

    private static func checkLabelSanitiser(_ check: (Bool, String) -> Void) {
        // The captain's own screenshot, as a string.
        let reported = "\u{1F5A5}\u{FE0F} Server"
        check(WhiteboardLabel.wouldTruncate(reported), "sanitiser: the reported caption is not recognised")
        let fixed = WhiteboardLabel.renderable(reported)
        check(!WhiteboardLabel.wouldTruncate(fixed), "sanitiser: the selector survived")
        // Every character except the selector survives - the point is that a
        // caption keeps its meaning, not that it gets shorter.
        check(fixed == "\u{1F5A5} Server", "sanitiser: produced \"\(fixed)\"")
        check(fixed.contains("Server"), "sanitiser: dropped the words")

        // The trigger is the selector, not the emoji: a caption with no emoji
        // at all truncates too, which is what rules out every "just strip
        // emoji" reading of this bug.
        let noEmoji = "A\u{FE0F}B Server"
        check(WhiteboardLabel.wouldTruncate(noEmoji), "sanitiser: a bare selector is not recognised")
        check(WhiteboardLabel.renderable(noEmoji) == "AB Server",
              "sanitiser: bare-selector text came back as \"\(WhiteboardLabel.renderable(noEmoji))\"")

        // An ordinary caption is returned untouched, identity included, so the
        // sanitiser cannot become a silent rewrite of every label in the app.
        let plain = "RDS / Aurora"
        check(WhiteboardLabel.renderable(plain) == plain, "sanitiser: rewrote an ordinary caption")
        check(!WhiteboardLabel.wouldTruncate(plain), "sanitiser: flagged an ordinary caption")

        // Both selectors, not just the emoji one - they are one concept.
        check(WhiteboardLabel.renderable("x\u{FE0E}y") == "xy",
              "sanitiser: left the text-presentation selector behind")
    }
}

#endif
