import Foundation
import RTCCLI

let parser = RTCCLIParser()
do {
    let command = try parser.parse(Array(CommandLine.arguments.dropFirst()))
    if command == .help { print("rtc submit | status | poll | conversation | tour attach | export | close | install-skill") }
} catch {
    let result = RTCCLIOutput.error(error); FileHandle.standardError.write(Data(result.text.utf8)); exit(result.exitCode)
}
