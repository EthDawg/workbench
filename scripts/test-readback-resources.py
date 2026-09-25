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
        let optionalMissing = CommandLine.arguments.contains("--optional-missing")
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
            let payload = try ReadbackResources.deckPayload()
            let created = try ReadbackStore.create(at: destination, title: "Synthetic")
            for (path, bytes) in payload {
                let file = destination.appendingPathComponent(path)
                guard try Data(contentsOf: file) == bytes else { fatalError("Payload differs: \(path)") }
                let mode = try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
                guard mode?.intValue == 0o600 else { fatalError("Nonprivate companion: \(path)") }
            }
            let reopened = try ReadbackStore.load(from: destination)
            guard created.id == reopened.id,
                  reopened.skillPack == .neutral,
                  fm.fileExists(atPath: destination.appendingPathComponent("README.md").path) else { fatalError("Invalid created session") }
            let neutralSkill = try String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8)
            guard neutralSkill.contains("template.pptx"), !fm.fileExists(atPath: destination.appendingPathComponent("brand").path) else {
                fatalError("Neutral default changed")
            }
            try Data("User custom skill".utf8).write(to: destination.appendingPathComponent("SKILL.md"))
            _ = try ReadbackStore.load(from: destination)
            guard try String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8) == "User custom skill" else { fatalError("Open overwrote custom skill") }
            let packs = ReadbackSkillPackStore(root: fixture.appendingPathComponent("Installed packs"))
            if optionalMissing {
                do {
                    _ = try packs.installServiceNow()
                    fatalError("Incomplete optional pack was installed")
                } catch {
                    guard error.localizedDescription.contains("ServiceNow") else { throw error }
                }
                guard !fm.fileExists(atPath: packs.root.path) else { fatalError("Incomplete optional install left files") }
                print("PASS missing optional assets do not break neutral sessions or partially install a pack")
            } else {
                let reference = try packs.installServiceNow()
                let pack = try packs.snapshot(for: .serviceNow)
                let branded = fixture.appendingPathComponent("Branded session")
                let brandedManifest = try ReadbackStore.create(at: branded, title: "Synthetic branded", skillPack: pack)
                guard reference == .serviceNow, brandedManifest.skillPack == reference else { fatalError("Pack identity missing") }
                for (path, bytes) in pack.files {
                    guard try Data(contentsOf: branded.appendingPathComponent(path)) == bytes else { fatalError("Optional payload differs") }
                }
                try Data("Custom branded session skill".utf8).write(to: branded.appendingPathComponent("SKILL.md"))
                _ = try packs.installServiceNow()
                try packs.uninstallServiceNow()
                _ = try ReadbackStore.load(from: branded)
                guard try String(contentsOf: branded.appendingPathComponent("SKILL.md"), encoding: .utf8) == "Custom branded session skill" else {
                    fatalError("Pack management changed a session")
                }
                do {
                    _ = try packs.snapshot(for: .serviceNow)
                    fatalError("Uninstalled explicit pack silently resolved")
                } catch {
                    guard error.localizedDescription.contains("unavailable") else { throw error }
                }
                let malformed = ReadbackSkillPackSnapshot(reference: .neutral, files: ["../escape": Data("Must not write".utf8)])
                let rejected = fixture.appendingPathComponent("Rejected")
                do {
                    _ = try ReadbackStore.create(at: rejected, title: "Rejected", skillPack: malformed)
                    fatalError("Unsafe payload accepted")
                } catch {
                    guard !fm.fileExists(atPath: rejected.path) else { fatalError("Unsafe payload created a session") }
                }
                print("PASS neutral default, complete installed pack snapshot/id/version, private files and existing custom skills preserved")
            }
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
        asset = moved / "Contents/Resources" / bundle.name / "build-snap-and-talk-deck/packs/servicenow-employee-experience/1.0.0/brand/assets/bg_purple.jpg"
        saved = asset.read_bytes()
        asset.unlink()
        subprocess.run([str(moved / "Contents/MacOS" / binary), "--optional-missing"], check=True, timeout=30)
        asset.write_bytes(saved)
        skill = moved / "Contents/Resources" / bundle.name / "build-snap-and-talk-deck/SKILL.md"
        skill.unlink()
        subprocess.run([str(moved / "Contents/MacOS" / binary), "--missing"], check=True, timeout=30)
        shutil.rmtree(moved / "Contents/Resources" / bundle.name)
        subprocess.run([str(moved / "Contents/MacOS" / binary), "--missing"], check=True, timeout=30)
print("READBACK_RESOURCE_LAYOUTS_OK: 11 process checks using actual store and resolver; no app installation")
