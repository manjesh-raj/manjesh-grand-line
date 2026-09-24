// Grand Line - native macOS app.
//
// The Add-credential sheet's password generator. Pure logic, no AppKit - the
// three modes, the character sets, the honest entropy figure, and one
// cryptographically-secure source of randomness.
//
// **Every random choice goes through `SecRandomCopyBytes`.** Not
// `Int.random(in:)`'s default generator (which is fine on Apple platforms
// today but is a documented *system* source rather than a documented
// *cryptographic* one), and never `arc4random_uniform` folded in by hand with
// `%`. `CryptoRandomNumberGenerator` below is a `RandomNumberGenerator` over
// `SecRandomCopyBytes`, handed to Swift's own `random(in:using:)` - which is
// unbiased by construction, so nothing here ever reaches for the modulo that
// is the classic way to skew a generated password.
//
// **The entropy number is computed, not decorative.** It is
// `log2(alphabet) * length` for the character modes and `log2(words) * count`
// for the passphrase - the real guessing entropy of the *generator*, which is
// the only defensible thing to print. It deliberately does not run the output
// through the strength meter `CredentialVaultPasswordStrength` uses for a
// *typed* master password: that meter estimates a human's password, and
// applying it to a machine-generated one would report "fair" for a string
// with 90 bits behind it.
//
// **Why the word list is 256 words and not 7776.** A Diceware list is a file;
// this is a source constant, and 7776 words is ~60KB of it. 256 words is
// exactly 8 bits each, which makes the arithmetic exact and auditable, and the
// default of six words is 48 bits *before* the separator digit and the
// capitalisation - comfortably past what a site-side password needs when the
// vault behind it is the thing actually being protected. A captain who wants
// more raises the count, and the printed figure follows.

import Foundation
import Security

/// A `RandomNumberGenerator` backed by `SecRandomCopyBytes`.
///
/// `next()` traps rather than degrading on failure, for the same reason
/// `CredentialVaultCrypto.newSalt` does: a password generated from a
/// predictable source is worse than no password, and there is no way to
/// report "this one is weak" through a `RandomNumberGenerator`'s API.
struct CryptoRandomNumberGenerator: RandomNumberGenerator {
    init() {}

    mutating func next() -> UInt64 {
        var value: UInt64 = 0
        let status = withUnsafeMutableBytes(of: &value) {
            SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt64>.size, $0.baseAddress!)
        }
        precondition(status == errSecSuccess,
                     "SecRandomCopyBytes failed (\(status)) - refusing to generate a password from a non-random source")
        return value
    }
}

struct GeneratedPassword: Equatable {
    let value: String
    /// Guessing entropy of the *generator* that produced it, in bits.
    let entropyBits: Double

    /// The chip's own wording, in the same three bands the mockup shows.
    /// Thresholds are the usual ones: below 60 bits is within reach of a
    /// funded offline attack on a fast hash, 80+ is not.
    var strengthLabel: String {
        switch entropyBits {
        case ..<60: return "fair"
        case ..<80: return "strong"
        default: return "very strong"
        }
    }

    var strengthTint: HelmTint {
        switch entropyBits {
        case ..<60: return .warn
        default: return .good
        }
    }

    /// "strong · 78 bits" - the mockup's chip, assembled in one place so the
    /// sheet and any future surface cannot phrase it two ways.
    var summary: String { "\(strengthLabel) \u{00B7} \(Int(entropyBits.rounded())) bits" }
}

enum PasswordGenerator {

    enum Mode: String, CaseIterable {
        case words
        case random
        case pin

        var title: String {
            switch self {
            case .words: return "Words"
            case .random: return "Random"
            case .pin: return "PIN"
            }
        }

        /// What the length slider counts in this mode, and its bounds. A PIN
        /// longer than 12 is not a PIN, and a passphrase of two words is not
        /// a passphrase - the ranges say so rather than letting the slider
        /// offer a setting nobody should pick.
        var lengthRange: ClosedRange<Int> {
            switch self {
            case .words: return 3...10
            case .random: return 8...64
            case .pin: return 4...12
            }
        }

        var defaultLength: Int {
            switch self {
            // Seven, not six: six words plus a digit and a capital is 53.9
        // bits, which this file's own bands print as "fair" - a default
        // that describes itself as merely fair is the wrong default. Seven
        // is 61.9 and prints as "strong".
        case .words: return 7
            case .random: return 20
            case .pin: return 6
            }
        }

        func lengthLabel(_ length: Int) -> String {
            switch self {
            case .words: return "\(length) words"
            case .random: return "\(length) characters"
            case .pin: return "\(length) digits"
            }
        }
    }

    /// The knobs the sheet exposes. `symbols`/`digits` only apply to
    /// `.random`; `.words` uses them as "put one digit in" and "add a symbol
    /// separator", which is what the mockup's `grain-Vault7-mossy-CIDR`
    /// actually is.
    struct Options: Equatable {
        var mode: Mode = .words
        var length: Int = Mode.words.defaultLength
        var useDigits = true
        var useSymbols = false
        var useUppercase = true

        init(mode: Mode = .words,
             length: Int? = nil,
             useDigits: Bool = true,
             useSymbols: Bool = false,
             useUppercase: Bool = true) {
            self.mode = mode
            self.length = length ?? mode.defaultLength
            self.useDigits = useDigits
            self.useSymbols = useSymbols
            self.useUppercase = useUppercase
        }
    }

    // MARK: Character sets

    static let lowercase = Array("abcdefghijkmnopqrstuvwxyz")
    /// No `I`, `O`, `l` or `1`/`0` in the letter sets: a generated password
    /// gets read off a screen and typed into a phone often enough that the
    /// ambiguous glyphs cost more than the ~0.2 bits per character they buy.
    static let uppercase = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let digits = Array("23456789")
    static let symbols = Array("!@#$%^&*-_=+?")

    // MARK: Generating

    /// Generate one password under `options`.
    ///
    /// `using` is injectable purely so `PasswordGeneratorSelfTest` can drive
    /// a deterministic sequence and assert the *shape* (which alphabet, which
    /// separators, which length) rather than only statistical properties. No
    /// production caller passes anything but the default.
    static func generate<G: RandomNumberGenerator>(_ options: Options, using generator: inout G) -> GeneratedPassword {
        switch options.mode {
        case .pin:
            let count = clamp(options.length, to: Mode.pin.lengthRange)
            let value = (0..<count).map { _ in String(Array("0123456789").randomElement(using: &generator)!) }.joined()
            return GeneratedPassword(value: value, entropyBits: log2(10.0) * Double(count))

        case .random:
            let count = clamp(options.length, to: Mode.random.lengthRange)
            var alphabet = lowercase
            if options.useUppercase { alphabet += uppercase }
            if options.useDigits { alphabet += digits }
            if options.useSymbols { alphabet += symbols }
            let value = (0..<count).map { _ in String(alphabet.randomElement(using: &generator)!) }.joined()
            return GeneratedPassword(value: value, entropyBits: log2(Double(alphabet.count)) * Double(count))

        case .words:
            let count = clamp(options.length, to: Mode.words.lengthRange)
            var chosen = (0..<count).map { _ in wordList.randomElement(using: &generator)! }
            var bits = log2(Double(wordList.count)) * Double(count)
            if options.useUppercase {
                // One word capitalised, picked at random - which is where the
                // extra bits come from, so it is counted.
                let index = Int.random(in: 0..<chosen.count, using: &generator)
                chosen[index] = chosen[index].capitalized
                bits += log2(Double(chosen.count))
            }
            let separator = options.useSymbols ? String(symbols.randomElement(using: &generator)!) : "-"
            var value = chosen.joined(separator: separator)
            if options.useDigits {
                let digit = Int.random(in: 0...9, using: &generator)
                value += "\(digit)"
                bits += log2(10.0)
            }
            return GeneratedPassword(value: value, entropyBits: bits)
        }
    }

    /// The production entry point: the same generator, over
    /// `SecRandomCopyBytes`.
    static func generate(_ options: Options) -> GeneratedPassword {
        var rng = CryptoRandomNumberGenerator()
        return generate(options, using: &rng)
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    // MARK: The word list

    /// 256 short, unambiguous, easily-typed English words - exactly 8 bits
    /// each, which is what makes this file's entropy arithmetic exact. No
    /// word is a prefix of another *and* under four letters, so a passphrase
    /// read aloud is unambiguous even without the separators.
    static let wordList: [String] = """
    amber anchor angle anvil apple april arbor arrow aspen atlas attic \
    audio autumn axiom bacon badge bagel baker balsa banjo barge basil \
    batch beach beacon beetle bengal birch bishop bison blade blaze blend \
    bloom board bolt bonus boots borax bottle boxer brace brave bread \
    brick bridge brisk broom brush buffer bugle bunch bundle burst cabin \
    cable cacao cactus camel canal candle canvas canyon cargo carol carpet \
    castle cedar cello census chalk charm chart cheese cherry chess chill \
    chime cider cinema circus citrus clamp clever cliff cloak clover cobalt \
    cocoa coffee comet compass copper coral cotton cougar county crane \
    crater credit creek crisp crown crumb crystal cumin cycle cymbal dairy \
    dapper dazzle debate decoy deluge denim depot desert detail diary \
    diesel dinner dolphin domain donor dragon drama drift druid dune duplex \
    eagle earthy easel eclipse eden effort elbow elder elfin ember emerald \
    empire enamel energy engine envoy ermine escort ether expert fable \
    fabric falcon fancy fauna fedora fender fennel ferry fiber fiddle \
    figure filter finch fjord flame flask fleet flint flora fluke flute \
    foggy forest forge fossil fresco frost frozen fungi funnel gadget \
    galaxy gallon gamma garden garlic gauge gavel gazebo gecko gemini \
    gentle geyser ginger glacier glide globe glossy gnome golden gopher \
    gospel gourd grain granite graph gravel green griffin grotto guitar \
    gusto gutter hammer hangar harbor harvest hazel heather helium hermit \
    hickory hollow honey hornet hostel hunter hurdle hybrid iceberg igloo \
    impala indigo inkwell insect iris island ivory jacket jaguar jasmine \
    jetty jigsaw jockey jungle juniper kayak kernel kettle keypad kimono \
    kindle kiosk kitten koala
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
}
