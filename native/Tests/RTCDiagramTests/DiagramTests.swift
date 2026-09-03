import Foundation
import RTCContracts
import RTCDiagram

@main struct DiagramTests {
    static func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
    static func main() throws {
        let url = URL(fileURLWithPath: "native/Fixtures/Diagrams/control-flow.json")
        let document = try JSONDecoder().decode(DiagramDocument.self, from: Data(contentsOf: url))
        let validated = try DiagramValidator.validate(document)
        let first = try DiagramLayoutEngine.layout(validated)
        let second = try DiagramLayoutEngine.layout(validated)
        check(first.digest == second.digest, "deterministic layout")
        check(DiagramAccessibility.items(for: validated).map(\.id) == ["check", "done", "start"], "accessibility order")
        check(try DiagramExportRenderer.png(first).first == 0x89, "png export")
        check(try DiagramExportRenderer.pdf(first).prefix(4) == Data("%PDF".utf8), "pdf export")
        var duplicateJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var duplicateNodes = duplicateJSON["nodes"] as! [[String: Any]]
        duplicateNodes.append(duplicateNodes[0]); duplicateJSON["nodes"] = duplicateNodes
        let duplicate = try JSONDecoder().decode(DiagramDocument.self, from: JSONSerialization.data(withJSONObject: duplicateJSON))
        check((try? DiagramValidator.validate(duplicate)) == nil, "duplicate id")
        print("RTC diagram checks passed")
    }
}
