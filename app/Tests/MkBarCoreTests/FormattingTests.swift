import Foundation
import Testing
import MkBarCore

@Suite("Byte formatting")
struct FormattingTests {
    private static let byteCases: [(Int64, String)] = [
        (0, "0 B"),
        (-1, "0 B"),
        (Int64.min, "0 B"),
        (1, "1.00 B"),
        (10, "10.0 B"),
        (99, "99.0 B"),
        (100, "100 B"),
        (999, "999 B"),
        (1000, "1000 B"),
        (1023, "1023 B"),
        (1024, "1.00 KB"),
        (1152, "1.13 KB"),
        (1536, "1.50 KB"),
        (2560, "2.50 KB"),
        (10_239, "10.00 KB"),
        (10_240, "10.0 KB"),
        (102_399, "100.0 KB"),
        (102_400, "100 KB"),
        (102_912, "101 KB"),
        (1_048_575, "1024 KB"),
        (1_048_576, "1.00 MB"),
        (1_572_864, "1.50 MB"),
        (297_222_144, "283 MB"),
        (58_834_944, "56.1 MB"),
        (105_381_888, "101 MB"),
        (1_073_741_823, "1024 MB"),
        (1_073_741_824, "1.00 GB"),
        (1_099_511_627_775, "1024 GB"),
        (1_099_511_627_776, "1.00 TB"),
        (10_995_116_277_760, "10.0 TB"),
        (109_951_162_777_600, "100 TB"),
        (110_500_918_591_488, "101 TB"),
        // Above 10^21 the CLI's own Number arithmetic has already rounded the
        // input; the formatter must follow the same Double, not the Int64.
        (1_125_899_906_842_624, "1024 TB"),
        (1_357_421_321_524_346_879, "1234568 TB"),
        (9_007_199_254_740_993, "8192 TB"),
        (Int64.max, "8388608 TB"),
    ]

    @Test func matchesCLIFormatting() {
        for (bytes, expected) in Self.byteCases {
            #expect(ByteFormat.string(bytes) == expected, "bytes: \(bytes)")
        }
    }

    @Test func pressureLevelsMapToTheDocumentedLabels() {
        #expect(MemoryPressure(level: 1) == .normal)
        #expect(MemoryPressure(level: 2) == .warning)
        #expect(MemoryPressure(level: 4) == .critical)
        #expect(MemoryPressure(level: 0) == .unknown)
        #expect(MemoryPressure(level: 3) == .unknown)
        #expect(MemoryPressure(level: 5) == .unknown)
        #expect(MemoryPressure(level: -1) == .unknown)
        #expect(MemoryPressure(level: Int.max) == .unknown)

        #expect(MemoryPressure.normal.label == "normal")
        #expect(MemoryPressure.warning.label == "warning")
        #expect(MemoryPressure.critical.label == "critical")
        #expect(MemoryPressure.unknown.label == "unknown")
    }
}
