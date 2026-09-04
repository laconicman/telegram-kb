// Re-runs the golden file's own input column through the current implementation and diffs.
// The file is self-contained — column 1 is the input — so this needs no corpus and no network.
import Foundation

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "Spec/url-canonical/corpus-canonical.tsv"
guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
    FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!); exit(2)
}
var checked = 0, failed = 0
for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
    if line.isEmpty || line.hasPrefix("#") { continue }
    let cols = line.components(separatedBy: "\t")
    guard cols.count == 2 else { continue }
    let expected: String? = cols[1].isEmpty ? nil : cols[1]
    let actual = URLCanonicaliser.canonicalise(cols[0])
    checked += 1
    if actual != expected {
        failed += 1
        if failed <= 5 {
            print("  MISMATCH \(cols[0])\n    expected: \(expected ?? "<nil>")\n    actual:   \(actual ?? "<nil>")")
        }
    }
}
print("  golden file: \(checked) rows checked, \(failed) mismatches")
exit(failed == 0 ? 0 : 1)
