import XCTest
@testable import OpenLift

final class PublishedCycleServiceTests: XCTestCase {
    func testParseTemplateResolvesLowercaseLegPressByName() throws {
        let exercises = [
            Exercise(name: "Leg Press", primaryMuscle: .quads, type: .compound, equipment: .machine),
            Exercise(name: "Leg Curl", primaryMuscle: .hamstrings, type: .isolation, equipment: .machine),
            Exercise(name: "Incline Dumbbell Press", primaryMuscle: .chest, type: .compound, equipment: .dumbbell),
            Exercise(name: "Helms Row", primaryMuscle: .back, type: .compound, equipment: .dumbbell)
        ]

        let url = try writeJSON(
            """
            {
              "name": "FB 2D",
              "days": [
                {
                  "label": "Day A",
                  "slots": [
                    { "muscle": "quads", "exerciseName": "leg press", "defaultSetCount": 2 },
                    { "muscle": "hamstrings", "exerciseName": "leg curl", "defaultSetCount": 2 },
                    { "muscle": "chest", "exerciseName": "incline dumbbell press", "defaultSetCount": 2 },
                    { "muscle": "back", "exerciseName": "helms row", "defaultSetCount": 2 }
                  ]
                }
              ]
            }
            """
        )

        let parsed = try PublishedCycleService.parseTemplate(at: url, exercises: exercises)
        XCTAssertEqual(parsed.name, "FB 2D")
        XCTAssertEqual(parsed.days.count, 1)
        XCTAssertEqual(parsed.days[0].slots.count, 4)
        XCTAssertEqual(parsed.days[0].slots[0].exerciseId, exercises[0].id)
    }

    func testParseTemplateResolvesDumbellTypoAlias() throws {
        let exercises = [
            Exercise(name: "Single-Arm Dumbbell Row", primaryMuscle: .back, type: .compound, equipment: .dumbbell)
        ]

        let url = try writeJSON(
            """
            {
              "name": "Alias Test",
              "days": [
                {
                  "label": "Day A",
                  "slots": [
                    { "muscle": "back", "exerciseName": "single-arm dumbell row", "defaultSetCount": 2 }
                  ]
                }
              ]
            }
            """
        )

        let parsed = try PublishedCycleService.parseTemplate(at: url, exercises: exercises)
        XCTAssertEqual(parsed.days[0].slots[0].exerciseId, exercises[0].id)
    }

    private func writeJSON(_ content: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        guard let data = content.data(using: .utf8) else {
            XCTFail("Could not encode JSON string as UTF-8.")
            return file
        }
        try data.write(to: file)
        return file
    }
}
