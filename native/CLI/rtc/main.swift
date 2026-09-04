import Foundation
import RTCCLI

let parser = RTCCLIParser()
do {
    let command = try parser.parse(Array(CommandLine.arguments.dropFirst()))
    let output = try await RTCCLIExecutor().run(command)
    FileHandle.standardOutput.write(Data(output.utf8))
    if !output.hasSuffix("\n") { FileHandle.standardOutput.write(Data("\n".utf8)) }
} catch {
    let result = RTCCLIOutput.error(error); FileHandle.standardError.write(Data(result.text.utf8)); exit(result.exitCode)
}
