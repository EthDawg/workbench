#!/usr/bin/env python3
"""Regenerate the small dependency-free native iOS Xcode project."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
MOBILE = ROOT / "Mobile"
PROJECT = MOBILE / "Workbench.xcodeproj"
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(str(value))
def obj(name, body):
    key = uid(name); objects[key] = body; return key
def array(values): return "(" + ", ".join(values) + ")"
def settings(values): return "{ " + " ".join(f"{k} = {q(v)};" for k, v in values.items()) + " }"

products = []
groups = []
targets = []
configs = {}
common = dict(SWIFT_VERSION="5.0", IPHONEOS_DEPLOYMENT_TARGET="26.0", CLANG_ENABLE_MODULES="YES", SDKROOT="iphoneos", TARGETED_DEVICE_FAMILY="1,2", CODE_SIGN_STYLE="Automatic", DEVELOPMENT_TEAM="GHVAAH9P5Z", ENABLE_USER_SCRIPT_SANDBOXING="YES", SWIFT_STRICT_CONCURRENCY="targeted")

def configuration_list(name, extra):
    entries = []
    for variant in ["Debug", "Release"]:
        values = common | extra | dict(SWIFT_OPTIMIZATION_LEVEL="-Onone" if variant == "Debug" else "-O", DEBUG_INFORMATION_FORMAT="dwarf" if variant == "Debug" else "dwarf-with-dsym")
        if variant == "Debug": values |= dict(SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG", ENABLE_TESTABILITY="YES", ONLY_ACTIVE_ARCH="YES")
        entries.append(obj(name + variant, "isa = XCBuildConfiguration; buildSettings = " + settings(values) + f"; name = {variant};"))
    return obj(name + "configs", f"isa = XCConfigurationList; buildConfigurations = {array(entries)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

for name, folder, product_type, extension in [
    ("WorkbenchMobile", "Workbench", "com.apple.product-type.application", "app"),
    ("WorkbenchTests", "WorkbenchTests", "com.apple.product-type.bundle.unit-test", "xctest"),
    ("WorkbenchUITests", "WorkbenchUITests", "com.apple.product-type.bundle.ui-testing", "xctest")
]:
    files = sorted((MOBILE / folder).glob("*.swift"))
    if name == "WorkbenchMobile":
        files += [ROOT / "Sources/LocalVoice" / f for f in ["TextPrimitives.swift", "DictationCleanup.swift", "CorrectionRule.swift"]]
        files += sorted((ROOT / "Sources/PhotoHandoffKit").glob("*.swift"))
        files += sorted((ROOT / "Sources/SceneSyncKit").glob("*.swift"))
    children = []; sources = []; resources = []
    if name == "WorkbenchMobile":
        files += [MOBILE / folder / "Info.plist", MOBILE / folder / "PrivacyInfo.xcprivacy"]
        files += sorted((MOBILE / folder).glob("*.xcassets"))
        files += [ROOT / "Resources/PersonaPortraits"]
        files += [ROOT / "Resources/AmbientScenes"]
    for path in files:
        relative = str(path.relative_to(ROOT)) if path.is_relative_to(MOBILE) else "../" + str(path.relative_to(ROOT))
        if relative.startswith("Mobile/"): relative = relative.removeprefix("Mobile/")
        kind = "sourcecode.swift" if path.suffix == ".swift" else "folder.assetcatalog" if path.suffix == ".xcassets" else "folder" if path.is_dir() else "text.plist.xml"
        ref = obj(relative + "ref", f"isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(relative)}; sourceTree = SOURCE_ROOT;")
        children.append(ref)
        if path.name == "Info.plist": continue
        build = obj(relative + "build" + name, f"isa = PBXBuildFile; fileRef = {ref};")
        (sources if path.suffix == ".swift" else resources).append(build)
    group = obj(name + "group", f"isa = PBXGroup; children = {array(children)}; name = {name}; sourceTree = \"<group>\";")
    groups.append(group)
    source_phase = obj(name + "sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(sources)}; runOnlyForDeploymentPostprocessing = 0;")
    resource_phase = obj(name + "resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array(resources)}; runOnlyForDeploymentPostprocessing = 0;")
    framework_phase = obj(name + "frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
    product = obj(name + "product", f"isa = PBXFileReference; explicitFileType = {q('wrapper.application' if extension == 'app' else 'wrapper.cfbundle')}; includeInIndex = 0; path = {q(name + '.' + extension)}; sourceTree = BUILT_PRODUCTS_DIR;")
    products.append(product)
    extra = dict(PRODUCT_NAME="$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER="com.ethdawg.workbench.mobile.preview" + ("" if name == "WorkbenchMobile" else "." + name.lower()))
    dependencies = []
    if name == "WorkbenchMobile": extra |= dict(INFOPLIST_FILE="Workbench/Info.plist", GENERATE_INFOPLIST_FILE="NO", ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon", ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME="AccentColor", SUPPORTS_MACCATALYST="NO", SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD="NO", WORKBENCH_PHOTO_CLOUD_PROVISIONED="NO", WORKBENCH_PHOTO_CLOUD_CONTAINER="iCloud.com.ethdawg.workbench.preview", WORKBENCH_PHOTO_CLOUD_ENVIRONMENT="Development")
    else:
        extra |= dict(GENERATE_INFOPLIST_FILE="YES")
        if name == "WorkbenchTests": extra |= dict(TEST_HOST="$(BUILT_PRODUCTS_DIR)/WorkbenchMobile.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/WorkbenchMobile", BUNDLE_LOADER="$(TEST_HOST)")
        else: extra |= dict(TEST_TARGET_NAME="WorkbenchMobile")
        proxy = obj(name + "proxy", f"isa = PBXContainerItemProxy; containerPortal = {uid('project')}; proxyType = 1; remoteGlobalIDString = {uid('WorkbenchMobiletarget')}; remoteInfo = WorkbenchMobile;")
        dependencies.append(obj(name + "dependency", f"isa = PBXTargetDependency; target = {uid('WorkbenchMobiletarget')}; targetProxy = {proxy};"))
    cfg = configuration_list(name, extra)
    targets.append(obj(name + "target", f"isa = PBXNativeTarget; buildConfigurationList = {cfg}; buildPhases = {array([source_phase, framework_phase, resource_phase])}; buildRules = (); dependencies = {array(dependencies)}; name = {name}; productName = {name}; productReference = {product}; productType = {q(product_type)};"))

product_group = obj("products", f"isa = PBXGroup; children = {array(products)}; name = Products; sourceTree = \"<group>\";")
root_group = obj("root", f"isa = PBXGroup; children = {array(groups + [product_group])}; sourceTree = \"<group>\";")
cfg = configuration_list("Project", {})
obj("project", f"isa = PBXProject; attributes = {{ LastUpgradeCheck = 2600; }}; buildConfigurationList = {cfg}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {root_group}; productRefGroup = {product_group}; projectDirPath = \"\"; projectRoot = \"\"; targets = {array(targets)};")
PROJECT.mkdir(exist_ok=True)
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n" + "\n".join(f"{key} = {{ {body} }};" for key, body in objects.items()) + f"\n}}; rootObject = {uid('project')}; }}\n")
scheme_dir = PROJECT / "xcshareddata/xcschemes"; scheme_dir.mkdir(parents=True, exist_ok=True)
def reference(name, ext): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(name + "target")}" BuildableName="{name}.{ext}" BlueprintName="{name}" ReferencedContainer="container:Workbench.xcodeproj"/>'
app = reference("WorkbenchMobile", "app")
tests = "".join(f'<TestableReference skipped="NO">{reference(name, "xctest")}</TestableReference>' for name in ["WorkbenchTests", "WorkbenchUITests"])
(scheme_dir / "WorkbenchMobile.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{tests}</Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(PROJECT)
