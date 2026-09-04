#!/usr/bin/env swift
import Foundation

enum ValidationFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value): return value
        }
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ValidationFailure.message(message) }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let skillURL = root.appendingPathComponent("skills/read-the-code/SKILL.md")
let parserURL = root.appendingPathComponent("native/CLI/rtc/RTCCLI.swift")
let exportURL = root.appendingPathComponent("native/Sources/RTCExport/DiagnosticExporter.swift")
let skill = try String(contentsOf: skillURL, encoding: .utf8)
let parser = try String(contentsOf: parserURL, encoding: .utf8)
let exportSource = try String(contentsOf: exportURL, encoding: .utf8)
let executable = root.appendingPathComponent("native/.build/debug/rtc")

let commands = [
    "rtc submit",
    "rtc status",
    "rtc poll",
    "rtc conversation poll",
    "rtc conversation reply",
    "rtc tour attach",
    "rtc export",
    "rtc close",
    "rtc install-skill",
    "rtc help",
    "rtc --help",
    "rtc -h",
]
let parserCommands = ["submit", "status", "poll", "conversation", "tour", "export", "close", "install-skill", "help"]
let flags = [
    "--repo", "--base", "--head", "--metadata", "--tour", "--wake-file", "--no-notify", "--json",
    "--after", "--timeout", "--full", "--message", "--file", "--diagnostic", "--scope",
    "--help", "-h",
]

try require(skill.contains("portable skill v2"), "portable skill must identify the v2 workflow")
for command in commands {
    try require(skill.contains(command), "portable skill is missing \(command)")
}
for command in parserCommands {
    try require(parser.contains("case \"\(command)\""), "native parser is missing \(command)")
}
for flag in flags {
    try require(parser.contains("\"\(flag)\""), "native parser is missing \(flag)")
    try require(skill.contains(flag), "portable skill is missing \(flag)")
}

for requiredBoundary in [
    "never persist a capability",
    "Advance a durable cursor only after",
    "grants no authority to push",
    "never confirm automatically",
    "read-the-code-axi",
    "schemaVersion: 1",
    "schemaVersion: 2",
    "export.prepare",
    "export.confirm",
    "not yet connected to the packaged CLI",
] {
    try require(
        skill.localizedCaseInsensitiveContains(requiredBoundary),
        "portable skill is missing safety boundary: \(requiredBoundary)"
    )
}

for serviceBoundary in [
    #"prepareOperation = "export.prepare""#,
    #"confirmOperation = "export.confirm""#,
    "prepareDispatcher",
    "confirmDispatcher",
] {
    try require(
        exportSource.contains(serviceBoundary),
        "native diagnostic service is missing boundary: \(serviceBoundary)"
    )
}

let frontmatter = skill.split(separator: "---", omittingEmptySubsequences: false)
try require(frontmatter.count >= 3, "portable skill frontmatter is missing")
let frontmatterLines = frontmatter[1].split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
try require(frontmatterLines.count == 2, "portable skill frontmatter must contain exactly name and description")

try require(
    skill.contains("rev-parse --verify --end-of-options \"${base}^{commit}\"")
        && skill.contains("git -C \"$repo\""),
    "portable skill must use quoted, option-terminated Git examples"
)

func run(_ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

try require(
    FileManager.default.isExecutableFile(atPath: executable.path), "native rtc must be built before skill validation")
for arguments in [
    ["help"], ["--help"], ["-h"],
] {
    let status = try run(arguments)
    try require(status == 0, "documented operation unavailable: \(arguments.joined(separator: " "))")
}
for arguments in [
    ["export", "review-id", "--bogus", "--json"],
    ["export", "review-id", "--diagnostic", "--diagnostic"],
    ["install-skill", "--scope", "root", "--json"],
    ["status", "--hostile"],
    ["poll", "review-id", "--after", "0", "leftover"],
] {
    let status = try run(arguments)
    try require(status == 2, "hostile/leftover arguments were accepted: \(arguments.joined(separator: " "))")
}

print("Native portable skill validation passed.")
