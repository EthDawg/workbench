#!/usr/bin/env python3
"""Run exact Speko catalogue transport with synthetic URLProtocol responses only."""
from pathlib import Path
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="workbench-speko-catalogue-") as folder:
    folder = Path(folder)
    binary = folder / "CatalogueChecks"
    subprocess.run([
        "swiftc", "-parse-as-library", "-swift-version", "5",
        "-module-cache-path", str(folder / "ModuleCache"),
        str(project / "Sources/LocalVoice/Speko.swift"),
        str(project / "Tests/SpekoCatalog/TransportChecks.swift"),
        "-o", str(binary),
    ], check=True, timeout=120)
    subprocess.run([str(binary)], check=True, timeout=30)
