import SwiftUI

struct ImportView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Published Folder") {
                    Text("Publish cycle JSON files to the OpenLift iCloud container:")
                    Text("OpenLift/cycles")
                        .font(.system(.callout, design: .monospaced))
                    Text("The app reads `.json` files from this folder.")
                }

                Section("JSON Shape") {
                    Text("""
                    {
                      "name": "Upper/Lower A",
                      "days": [
                        {
                          "label": "Day A",
                          "slots": [
                            {
                              "muscle": "chest",
                              "exerciseName": "Incline Dumbbell Press",
                              "defaultSetCount": 3
                            }
                          ]
                        }
                      ]
                    }
                    """)
                    .font(.system(.footnote, design: .monospaced))
                }

                Section("Notes") {
                    Text("Use either `exerciseName` or `exerciseId` per slot.")
                    Text("`exerciseName` is recommended for readability.")
                    Text("Then open Cycle tab and tap Refresh, then Import or Import + Activate.")
                }
            }
            .navigationTitle("Import")
        }
    }
}

#Preview {
    ImportView()
}
