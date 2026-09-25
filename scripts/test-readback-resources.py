#!/usr/bin/env python3
"""Run the production session store/resource resolver in disposable CLI and app layouts."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
model = (ROOT / "Sources/LocalVoice/ReadbackModel.swift").read_text()
types = model[model.index("enum ReadbackSectionStatus"):model.index("enum ReadbackHandoffTarget")]
store = model[model.index("enum ReadbackStore {"):model.index("struct ReadbackScreenshot")]
assert "Bundle.module" not in store, "The generated accessor traps before its caller can catch an error"
harness = r'''
import Foundation
__TYPES__
__STORE__
@main struct ResourceChecks {
    static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("ResourceSession-\(UUID().uuidString)")
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let destination = fixture.appendingPathComponent("New session")
        let expectMissing = CommandLine.arguments.contains("--missing")
        if expectMissing {
            for existing in [false, true] {
                if existing { try fm.createDirectory(at: destination, withIntermediateDirectories: true) }
                do {
                    _ = try ReadbackStore.create(at: destination, title: "Synthetic")
                    fatalError("Missing resources were accepted")
                } catch {
                    guard error.localizedDescription.contains("deck skill") else { throw error }
                }
                if existing {
                    guard try fm.contentsOfDirectory(atPath: destination.path).isEmpty else { fatalError("Existing folder changed") }
                } else if fm.fileExists(atPath: destination.path) { fatalError("Missing resources left a partial session") }
            }
            print("PASS missing resources report an error without a trap or partial session")
        } else {
            let bytes = try ReadbackResources.deckSkill()
            let created = try ReadbackStore.create(at: destination, title: "Synthetic")
            let copied = try Data(contentsOf: destination.appendingPathComponent("SKILL.md"))
            let reopened = try ReadbackStore.load(from: destination)
            guard bytes == copied, created.id == reopened.id,
                  fm.fileExists(atPath: destination.appendingPathComponent("README.md").path) else { fatalError("Invalid created session") }
            print("PASS exact skill bytes, README and reopened session")
        }
    }
}
'''.replace("__TYPES__", types).replace("__STORE__", store)

with tempfile.TemporaryDirectory(prefix="workbench-resource-check-", dir="/private/tmp") as temporary:
    root = Path(temporary)
    source = root / "Check.swift"
    source.write_text(harness)
    build = root / "build"
    build.mkdir()
    executable = build / "LocalVoice"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-module-cache-path", str(root / "ModuleCache"),
                    str(ROOT / "Sources/LocalVoice/ReadbackResources.swift"), str(source), "-o", str(executable)], check=True, timeout=120)
    bundle = build / "Workbench_LocalVoice.bundle"
    shutil.copytree(ROOT / "Sources/LocalVoice/Resources", bundle)
    subprocess.run([str(executable)], check=True, timeout=30)

    # Same two identities/layouts as packaging; never installed or launched through LaunchServices.
    for name, binary, identifier in [("Workbench", "Workbench", "com.ethdawg.workbench"),
                                      ("Workbench Preview", "WorkbenchPreview", "com.ethdawg.workbench.preview")]:
        app = root / (name + ".app")
        resources = app / "Contents/Resources"
        macos = app / "Contents/MacOS"
        macos.mkdir(parents=True)
        resources.mkdir()
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier, "CFBundleExecutable": binary, "CFBundlePackageType": "APPL"}))
        shutil.copy2(executable, macos / binary)
        shutil.copytree(bundle, resources / bundle.name)
        subprocess.run([str(macos / binary)], check=True, timeout=30)
        # Move the whole app outside the build directory and rerun; no developer path fallback.
        moved = root / "relocated" / app.name
        moved.parent.mkdir(exist_ok=True)
        app.rename(moved)
        subprocess.run([str(moved / "Contents/MacOS" / binary)], check=True, timeout=30)
        skill = moved / "Contents/Resources" / bundle.name / "build-snap-and-talk-deck/SKILL.md"
        skill.unlink()
        subprocess.run([str(moved / "Contents/MacOS" / binary), "--missing"], check=True, timeout=30)
        shutil.rmtree(moved / "Contents/Resources" / bundle.name)
        subprocess.run([str(moved / "Contents/MacOS" / binary), "--missing"], check=True, timeout=30)
print("READBACK_RESOURCE_LAYOUTS_OK: 9 process checks using actual store and resolver; no app installation")
