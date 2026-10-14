import Foundation

/// The command line of `skintool`, parsed in the library so it can be unit-tested.
///
///     skintool [-v] <skin.wsz | folder>
///     skintool --png <out> [--state webamp|idle] [--scale N] [--compare <refdir>] [--no-region] [-v] <skin.wsz | folder>
public struct SkintoolOptions: Equatable, Sendable {
    public enum State: String, Sendable { case webamp, idle }

    public struct UsageError: Error, Equatable, Sendable, CustomStringConvertible {
        public let description: String
    }

    public static let usage =
        "usage: skintool [-v|--verbose] [--png <out> [--state webamp|idle] [--scale N] [--compare <refdir>] [--no-region]] <skin.wsz | folder>"

    public var verbose = false
    /// A PNG file for one skin, a directory for a folder; nil = report only.
    public var png: String?
    public var state: State = .webamp
    public var scale = 1
    public var compare: String?
    public var noRegion = false
    public var input: String

    public static func parse(_ arguments: [String]) -> Result<SkintoolOptions, UsageError> {
        var verbose = false, noRegion = false
        var png: String?, compare: String?
        var state: State?, scale: Int?
        var inputs: [String] = []
        var index = 0

        func value(for flag: String) -> String? {
            index += 1
            guard index < arguments.count, !arguments[index].hasPrefix("-") else { return nil }
            return arguments[index]
        }
        func fail(_ message: String) -> Result<SkintoolOptions, UsageError> { .failure(UsageError(description: message)) }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-v", "--verbose": verbose = true
            case "--no-region": noRegion = true
            case "--png":
                guard let path = value(for: argument) else { return fail("--png needs an output path") }
                png = path
            case "--compare":
                guard let path = value(for: argument) else { return fail("--compare needs a folder") }
                compare = path
            case "--state":
                guard let name = value(for: argument), let parsed = State(rawValue: name) else {
                    return fail("--state must be webamp or idle")
                }
                state = parsed
            case "--scale":
                guard let text = value(for: argument), let parsed = Int(text), parsed >= 1 else {
                    return fail("--scale needs an integer of 1 or more")
                }
                scale = parsed
            default:
                if argument.hasPrefix("-") { return fail("unknown option: \(argument)") }
                inputs.append(argument)
            }
            index += 1
        }

        guard inputs.count == 1, let input = inputs.first else {
            return fail(inputs.isEmpty ? "missing <skin.wsz | folder>" : "only one <skin.wsz | folder> is accepted")
        }
        if png == nil, state != nil || scale != nil || compare != nil || noRegion {
            return fail("--state, --scale, --compare and --no-region need --png")
        }
        if compare != nil, (scale ?? 1) != 1 { return fail("--compare needs --scale 1 (the references are 1x)") }

        var options = SkintoolOptions(input: input)
        options.verbose = verbose
        options.png = png
        options.state = state ?? .webamp
        options.scale = scale ?? 1
        options.compare = compare
        options.noRegion = noRegion
        return .success(options)
    }
}
