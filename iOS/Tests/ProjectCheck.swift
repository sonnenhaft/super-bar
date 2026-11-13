import Foundation

// Run from the repository root. Validate the checked-in project without generating
// or rewriting it, and keep app/widget builds independent of external runtimes.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let ios = root.appendingPathComponent("iOS")
let data = try Data(contentsOf: ios.appendingPathComponent("SuperBar.xcodeproj/project.pbxproj"))
let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
let objects = plist["objects"] as! [String: [String: Any]]
let forbidden: Set<String> = ["XCRemoteSwiftPackageReference", "XCLocalSwiftPackageReference",
    "XCSwiftPackageProductDependency", "PBXShellScriptBuildPhase"]
for object in objects.values {
    precondition(!forbidden.contains(object["isa"] as? String ?? ""), "External dependency or script build phase")
    if object["isa"] as? String == "PBXFileReference", object["sourceTree"] as? String == "<group>",
       let path = object["path"] as? String {
        precondition(FileManager.default.fileExists(atPath: ios.appendingPathComponent(path).path), "Missing project file: \(path)")
    }
}
for (name, folders) in [("SuperBar", ["App", "Shared"]), ("SuperBarWidgets", ["Widgets", "Shared"])] {
    let target = objects.values.first { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == name }!
    var included = Set<String>()
    for phaseID in target["buildPhases"] as! [String] {
        guard let phase = objects[phaseID], phase["isa"] as? String == "PBXSourcesBuildPhase" else { continue }
        for buildID in phase["files"] as! [String] {
            let ref = objects[buildID]!["fileRef"] as! String
            included.insert(objects[ref]!["path"] as! String)
        }
    }
    for folder in folders {
        for file in try FileManager.default.contentsOfDirectory(at: ios.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            where file.pathExtension == "swift" {
            let path = folder + "/" + file.lastPathComponent
            precondition(included.contains(path), "\(path) is missing from \(name)")
        }
    }
}
print("iOS project: files and app/widget membership verified; no external packages or build scripts.")
