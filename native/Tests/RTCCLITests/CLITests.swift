import Foundation
import RTCCLI

@main struct CLITests {
    static func main() throws {
        let parser = RTCCLIParser()
        check(try parser.parse(["submit", "--repo", "/tmp/repo", "--base", "main", "--head", "HEAD", "--json"]) == .submit(repo: "/tmp/repo", base: "main", head: "HEAD", metadata: nil, tour: nil, wakeFile: nil, notify: true, json: true), "submit")
        check(try parser.parse(["conversation", "poll", "abc", "--after", "4", "--timeout", "2m"]) == .poll(review: "abc", after: 4, timeoutMilliseconds: 120_000, full: false, json: false, conversation: true), "conversation")
        check((try? parser.parse(["submit", "--repo", "/tmp/repo"])) == nil, "missing")
        check((try? parser.parse(["poll", "abc", "--after", "0", "--timeout", "61m"])) == nil, "bounded timeout")
    }
    static func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
}
