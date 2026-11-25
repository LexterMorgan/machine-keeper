// This machine has CommandLineTools only. That toolchain ships Swift
// Testing but not XCTest, so the suite uses Swift Testing.
import Foundation
import Testing

enum TestFixtures {
    static func data(named name: String, fileExtension: String = "json") throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    static func reportData() throws -> Data {
        try data(named: "report")
    }

    static let cleanJSON = Data(
        """
        {
          "schemaVersion": 1,
          "dryRun": true,
          "results": [
            {
              "id": "npm-cache",
              "title": "npm cache",
              "bytes": 297222144,
              "status": "would-remove"
            },
            {
              "id": "pip-cache",
              "title": "pip cache",
              "bytes": 9072640,
              "status": "would-remove"
            },
            {
              "id": "spotify-cache",
              "title": "Spotify cache",
              "bytes": 8823283712,
              "status": "skipped-app-running"
            },
            {
              "id": "huggingface-cache",
              "title": "Hugging Face model cache",
              "bytes": 147955712,
              "status": "opt-in-skipped"
            }
          ],
          "freedBytes": 0
        }
        """.utf8
    )
}
