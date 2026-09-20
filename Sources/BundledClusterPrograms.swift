import Foundation

/// V8 content. Historical identity strings are data, not derived from current placement.
enum BundledClusterPrograms {
    static let v8: ClusterProgramDefinition = {
        typealias Reference = ClusterProgramDefinition.ExerciseReference
        typealias Progression = ClusterProgramDefinition.Progression
        typealias Slot = ClusterProgramDefinition.Slot
        typealias Step = ClusterProgramDefinition.Step
        let references: [String: Reference] = [
            "Flat DB Press": Reference(candidates: [.name("Flat DB Press")], setupSource: .exerciseCatalog),
            "Lat Pulldown": Reference(candidates: [.name("Lat Pulldown")], setupSource: .exerciseCatalog),
            "Overhead Cable Extension": Reference(candidates: [.name("Overhead Cable Extension"), .name("Overhead Single-Arm Cable Extension")], setupSource: .exerciseCatalog),
            "Incline Curl": Reference(candidates: [.name("Incline Curl")], setupSource: .exerciseCatalog),
            "Seated Cable Flye": Reference(candidates: [.id(UUID(uuidString: "AD41745F-6104-43B0-A886-3A7065BB8466")!), .name("Seated Cable Flye")], setupSource: .exerciseCatalog),
            "CS DB Row": Reference(candidates: [.id(UUID(uuidString: "3122AC62-0E70-467F-AFA8-B890D6B334D1")!), .name("CS DB Row")], setupSource: .exerciseCatalog),
            "Cable Pushdown": Reference(candidates: [.name("Cable Pushdown")], setupSource: .exerciseCatalog),
            "DB Preacher Curl": Reference(candidates: [.name("DB Preacher Curl")], setupSource: .exerciseCatalog),
            "Incline DB Press": Reference(candidates: [.name("Incline DB Press")], setupSource: .exerciseCatalog),
            "SA Lat Pulldown": Reference(candidates: [.id(UUID(uuidString: "D6FB95A8-A882-4CDE-99C8-3804530E0A76")!), .name("SA Lat Pulldown")], setupSource: .exerciseCatalog),
            "DB Skullcrusher": Reference(candidates: [.name("DB Skullcrusher")], setupSource: .exerciseCatalog),
            "Bayesian Curl": Reference(candidates: [.name("Bayesian Curl")], setupSource: .exerciseCatalog),
            "Incline DB Flye": Reference(candidates: [.id(UUID(uuidString: "420AFD52-9446-41C3-92C5-1E9239709263")!), .name("Incline DB Flye")], setupSource: .exerciseCatalog),
            "SA CS Cable Row": Reference(candidates: [.id(UUID(uuidString: "9FCBF4C1-2E7E-4A2E-AD81-F0FB1CA7B2B8")!), .consolidatedRowName("Chest Supported Row"), .consolidatedRowName("Chest-Supported Cable Row")], setupSource: .exerciseCatalog),
            "Overhead SA Cable Extension": Reference(candidates: [.id(UUID(uuidString: "17BC2F9D-F0A2-4604-AA41-33ADD79ED16B")!)], setupSource: .exerciseCatalog),
            "Seated DB Hammer Curl": Reference(candidates: [.id(UUID(uuidString: "A8D6049B-0E33-43C8-91A9-6A4A689F2218")!)], setupSource: .exerciseCatalog),
            "Back Extension": Reference(candidates: [.name("Back Extension")], setupSource: .exerciseCatalog),
            "Belt Squat": Reference(candidates: [.name("Belt Squat")], setupSource: .exerciseCatalog),
            "Stiff-Leg Deadlift": Reference(candidates: [.name("Stiff-Leg Deadlift")], setupSource: .exerciseCatalog),
            "Bulgarian Split Squat": Reference(candidates: [.name("Bulgarian Split Squat")], setupSource: .exerciseCatalog),
            "Reverse Hyper": Reference(candidates: [.name("Reverse Hyper")], setupSource: .exerciseCatalog),
            "Safety Bar Squat": Reference(candidates: [.name("Safety Bar Squat")], setupSource: .exerciseCatalog),
            "Leg Curl": Reference(candidates: [.name("Leg Curl")], setupSource: .exerciseCatalog),
            "Leg Extension": Reference(candidates: [.name("Leg Extension")], setupSource: .exerciseCatalog),
            "Incline Side-Lying DB Lateral Raise": Reference(candidates: [.id(UUID(uuidString: "6AB50DE4-7104-4396-BC69-2574F1104F04")!), .name("Incline Side-Lying DB Lateral Raise")], setupSource: .exerciseCatalog),
            "Stair Calves": Reference(candidates: [.name("Stair Calves")], setupSource: .exerciseCatalog),
            "Seated DB Shrugs": Reference(candidates: [.name("Seated DB Shrugs")], setupSource: .exerciseCatalog),
            "Super ROM DB Lateral Raise": Reference(candidates: [.name("Super ROM DB Lateral Raise")], setupSource: .exerciseCatalog),
            "Bench-Supported Cable Wrist Curl (Supinated)": Reference(candidates: [.name("Bench-Supported Cable Wrist Curl (Supinated)")], setupSource: .exerciseCatalog),
            "Cable Lateral Raise": Reference(candidates: [.name("Cable Lateral Raise")], setupSource: .exerciseCatalog),
            "Bench-Supported Cable Wrist Extension (Pronated)": Reference(candidates: [.name("Bench-Supported Cable Wrist Extension (Pronated)")], setupSource: .exerciseCatalog),
            "Captain of Crush": Reference(candidates: [.name("Captain of Crush"), .name("Captains of Crush")], setupSource: .exerciseCatalog),
        ]
        let rowAliases: [UUID: String] = [
            UUID(uuidString: "3122AC62-0E70-467F-AFA8-B890D6B334D1")!: "openlift.clustered-hypertrophy.v6.cluster-1.back.dumbbell-row",
            UUID(uuidString: "9FCBF4C1-2E7E-4A2E-AD81-F0FB1CA7B2B8")!: "openlift.clustered-hypertrophy.v1.cluster-1.back.c"
        ]
        return ClusterProgramDefinition(formatVersion: 1, programVersionID: "openlift.clustered-hypertrophy.v8",
            templateName: "Clustered Hypertrophy v8", identityKey: "openlift_clustered_hypertrophy_v8",
            exercises: references, clusters: [
                .init(id: "cluster-1", steps: [
                    Step(templatePosition: 0, label: "Cluster 1 · A", slots: [
                        Slot(muscle: .chest, exercise: "Flat DB Press", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-1.chest.b")),
                        Slot(muscle: .back, exercise: "Lat Pulldown", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-1.back.a")),
                        Slot(muscle: .triceps, exercise: "Overhead Cable Extension", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-2.triceps.a")),
                        Slot(muscle: .biceps, exercise: "Incline Curl", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-2.biceps.a")),
                    ]),
                    Step(templatePosition: 1, label: "Cluster 1 · B", slots: [
                        Slot(muscle: .chest, exercise: "Seated Cable Flye", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-1.chest.c")),
                        Slot(muscle: .back, exercise: "CS DB Row", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-1.back.c", exerciseAliases: rowAliases)),
                        Slot(muscle: .triceps, exercise: "Cable Pushdown", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-2.triceps.b")),
                        Slot(muscle: .biceps, exercise: "DB Preacher Curl", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-2.biceps.b")),
                    ]),
                    Step(templatePosition: 2, label: "Cluster 1 · C", slots: [
                        Slot(muscle: .chest, exercise: "Incline DB Press", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-1.chest.a")),
                        Slot(muscle: .back, exercise: "SA Lat Pulldown", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v6.cluster-1.back.single-arm-pulldown")),
                        Slot(muscle: .triceps, exercise: "DB Skullcrusher", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-2.triceps.c")),
                        Slot(muscle: .biceps, exercise: "Bayesian Curl", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-2.biceps.c")),
                    ]),
                    Step(templatePosition: 3, label: "Cluster 1 · D", slots: [
                        Slot(muscle: .chest, exercise: "Incline DB Flye", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-1.chest.c")),
                        Slot(muscle: .back, exercise: "SA CS Cable Row", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v6.cluster-1.back.dumbbell-row", exerciseAliases: rowAliases)),
                        Slot(muscle: .triceps, exercise: "Overhead SA Cable Extension", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v8.movement.triceps.", appendExerciseID: true)),
                        Slot(muscle: .biceps, exercise: "Seated DB Hammer Curl", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v8.movement.biceps.", appendExerciseID: true)),
                    ]),
                ]),
                .init(id: "cluster-2", steps: [
                    Step(templatePosition: 4, label: "Cluster 2 · A", slots: [
                        Slot(muscle: .hamstrings, exercise: "Back Extension", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.legs.", appendExerciseID: true)),
                    ]),
                    Step(templatePosition: 5, label: "Cluster 2 · B", slots: [
                        Slot(muscle: .quads, exercise: "Belt Squat", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.legs.", appendExerciseID: true)),
                    ]),
                    Step(templatePosition: 6, label: "Cluster 2 · C", slots: [
                        Slot(muscle: .hamstrings, exercise: "Stiff-Leg Deadlift", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.legs.", appendExerciseID: true)),
                    ]),
                    Step(templatePosition: 7, label: "Cluster 2 · D", slots: [
                        Slot(muscle: .quads, exercise: "Bulgarian Split Squat", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.legs.", appendExerciseID: true)),
                    ]),
                    Step(templatePosition: 8, label: "Cluster 2 · E", slots: [
                        Slot(muscle: .hamstrings, exercise: "Reverse Hyper", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.legs.", appendExerciseID: true)),
                    ]),
                    Step(templatePosition: 9, label: "Cluster 2 · F", slots: [
                        Slot(muscle: .quads, exercise: "Safety Bar Squat", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.legs.", appendExerciseID: true)),
                    ]),
                    Step(templatePosition: 10, label: "Cluster 2 · G", slots: [
                        Slot(muscle: .hamstrings, exercise: "Leg Curl", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.legs.", appendExerciseID: true)),
                    ]),
                    Step(templatePosition: 11, label: "Cluster 2 · H", slots: [
                        Slot(muscle: .quads, exercise: "Leg Extension", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.legs.", appendExerciseID: true)),
                    ]),
                ]),
                .init(id: "cluster-3", steps: [
                    Step(templatePosition: 12, label: "Cluster 3 · A", slots: [
                        Slot(muscle: .sideDelts, exercise: "Incline Side-Lying DB Lateral Raise", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.shoulders.", appendExerciseID: true)),
                        Slot(muscle: .calves, exercise: "Stair Calves", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.calves.", appendExerciseID: true)),
                        Slot(muscle: .traps, exercise: "Seated DB Shrugs", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v3.cluster-3.traps.seated-dumbbell-shrug")),
                    ]),
                    Step(templatePosition: 13, label: "Cluster 3 · B", slots: [
                        Slot(muscle: .sideDelts, exercise: "Super ROM DB Lateral Raise", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.shoulders.", appendExerciseID: true)),
                        Slot(muscle: .forearms, exercise: "Bench-Supported Cable Wrist Curl (Supinated)", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-3.calves-forearms.b")),
                    ]),
                    Step(templatePosition: 14, label: "Cluster 3 · C", slots: [
                        Slot(muscle: .sideDelts, exercise: "Cable Lateral Raise", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.shoulders.", appendExerciseID: true)),
                        Slot(muscle: .calves, exercise: "Stair Calves", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.calves.", appendExerciseID: true)),
                        Slot(muscle: .traps, exercise: "Seated DB Shrugs", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v3.cluster-3.traps.seated-dumbbell-shrug")),
                    ]),
                    Step(templatePosition: 15, label: "Cluster 3 · D", slots: [
                        Slot(muscle: .sideDelts, exercise: "Incline Side-Lying DB Lateral Raise", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.shoulders.", appendExerciseID: true)),
                        Slot(muscle: .forearms, exercise: "Bench-Supported Cable Wrist Extension (Pronated)", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-3.calves-forearms.d")),
                    ]),
                    Step(templatePosition: 16, label: "Cluster 3 · E", slots: [
                        Slot(muscle: .sideDelts, exercise: "Super ROM DB Lateral Raise", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.shoulders.", appendExerciseID: true)),
                        Slot(muscle: .calves, exercise: "Stair Calves", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.calves.", appendExerciseID: true)),
                        Slot(muscle: .traps, exercise: "Seated DB Shrugs", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v3.cluster-3.traps.seated-dumbbell-shrug")),
                    ]),
                    Step(templatePosition: 17, label: "Cluster 3 · F", slots: [
                        Slot(muscle: .sideDelts, exercise: "Cable Lateral Raise", defaultSetCount: 2, progression: Progression(key: "openlift.clustered-hypertrophy.v7.movement.shoulders.", appendExerciseID: true)),
                        Slot(muscle: .forearms, exercise: "Captain of Crush", defaultSetCount: 3, progression: Progression(key: "openlift.clustered-hypertrophy.v1.cluster-3.calves-forearms.f")),
                    ]),
                ]),
            ])
    }()
}
