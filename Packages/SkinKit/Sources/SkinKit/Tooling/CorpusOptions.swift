import Foundation

/// Command lines of `skintool corpus` and `skintool corpus-report`, parsed here so they can be unit-tested (#0038).
public struct CorpusOptions: Equatable, Sendable {
    public struct UsageError: Error, Equatable, Sendable, CustomStringConvertible {
        public let description: String
    }

    public static let usage =
        "usage: skintool corpus <dir> --out <dir> [--resume] [--timeout <s>=10] [--max-memory <MiB>=4096] [--sample <N>] [--seed <n>=1] [--manifest <file>]"

    public var input: String
    public var out: String
    public var resume = false
    public var timeout = 10.0
    public var maxMemoryMiB = 4096
    public var sample: Int?
    public var seed: UInt64 = 1
    public var manifest: String?

    public static func parse(_ arguments: [String]) -> Result<CorpusOptions, UsageError> {
        var input: String?, out: String?, manifest: String?
        var resume = false, timeout = 10.0, maxMemory = 4096, sample: Int?, seed: UInt64 = 1
        var index = 0
        func fail(_ message: String) -> Result<CorpusOptions, UsageError> { .failure(UsageError(description: message)) }
        func value() -> String? {
            index += 1
            return index < arguments.count && !arguments[index].hasPrefix("--") ? arguments[index] : nil
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--resume": resume = true
            case "--out":
                guard let v = value() else { return fail("--out needs a folder") }
                out = v
            case "--manifest":
                guard let v = value() else { return fail("--manifest needs a file") }
                manifest = v
            case "--timeout":
                guard let v = value(), let n = Double(v), n > 0 else { return fail("--timeout needs a positive number of seconds") }
                timeout = n
            case "--max-memory":
                guard let v = value(), let n = Int(v), n > 0 else { return fail("--max-memory needs a positive number of MiB") }
                maxMemory = n
            case "--sample":
                guard let v = value(), let n = Int(v), n > 0 else { return fail("--sample needs a positive count") }
                sample = n
            case "--seed":
                guard let v = value(), let n = UInt64(v) else { return fail("--seed needs a non-negative integer") }
                seed = n
            default:
                if argument.hasPrefix("-") { return fail("unknown option: \(argument)") }
                if input != nil { return fail("only one <dir> is accepted") }
                input = argument
            }
            index += 1
        }
        guard let input else { return fail("missing <dir>") }
        guard let out else { return fail("missing --out <dir>") }
        var options = CorpusOptions(input: input, out: out)
        options.resume = resume; options.timeout = timeout; options.maxMemoryMiB = maxMemory
        options.sample = sample; options.seed = seed; options.manifest = manifest
        return .success(options)
    }
}

/// `skintool corpus-report <results.jsonl> --markdown <report.md> --json <summary.json> [--env <env.json>] [--sample <N>=1000] [--seed <n>=1] [--crashes <dir>]`
public struct CorpusReportOptions: Equatable, Sendable {
    public static let usage =
        "usage: skintool corpus-report <results.jsonl> --markdown <report.md> --json <summary.json> [--env <env.json>] [--sample <N>=1000] [--seed <n>=1] [--crashes <dir>]"

    public var input: String
    public var markdown: String
    public var json: String
    public var env: String?
    public var sample = 1000
    public var seed: UInt64 = 1
    public var crashes: String?

    public static func parse(_ arguments: [String]) -> Result<CorpusReportOptions, CorpusOptions.UsageError> {
        var input: String?, markdown: String?, json: String?, env: String?, crashes: String?
        var sample = 1000, seed: UInt64 = 1
        var index = 0
        func fail(_ message: String) -> Result<CorpusReportOptions, CorpusOptions.UsageError> {
            .failure(.init(description: message))
        }
        func value() -> String? {
            index += 1
            return index < arguments.count && !arguments[index].hasPrefix("--") ? arguments[index] : nil
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--markdown":
                guard let v = value() else { return fail("--markdown needs a file") }
                markdown = v
            case "--json":
                guard let v = value() else { return fail("--json needs a file") }
                json = v
            case "--env":
                guard let v = value() else { return fail("--env needs a file") }
                env = v
            case "--crashes":
                guard let v = value() else { return fail("--crashes needs a folder") }
                crashes = v
            case "--sample":
                guard let v = value(), let n = Int(v), n > 0 else { return fail("--sample needs a positive count") }
                sample = n
            case "--seed":
                guard let v = value(), let n = UInt64(v) else { return fail("--seed needs a non-negative integer") }
                seed = n
            default:
                if argument.hasPrefix("-") { return fail("unknown option: \(argument)") }
                if input != nil { return fail("only one <results.jsonl> is accepted") }
                input = argument
            }
            index += 1
        }
        guard let input else { return fail("missing <results.jsonl>") }
        guard let markdown else { return fail("missing --markdown <report.md>") }
        guard let json else { return fail("missing --json <summary.json>") }
        var options = CorpusReportOptions(input: input, markdown: markdown, json: json)
        options.env = env; options.sample = sample; options.seed = seed; options.crashes = crashes
        return .success(options)
    }
}
