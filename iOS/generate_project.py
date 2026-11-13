#!/usr/bin/env python3
"""Generate the dependency-free Xcode project from an explicit source allowlist."""
import hashlib
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SHARED_UI = [
    "Shared/PanelTheme.swift", "Shared/PanelComponents.swift",
    "Shared/DeviceDisplayName.swift", "ClimateArtwork.swift",
]
SHARED = SHARED_UI + [
    "Readings.swift", "Cloud/CloudSupport.swift", "Cloud/CredentialStore.swift", "Shared/ReadingAge.swift", "Shared/PanelTemperatureControl.swift", "Shared/FanSpeedControl.swift", "Shared/AirflowControl.swift", "Shared/ClimateDeviceList.swift", "Shared/ClimateSelection.swift",
    "EnergyCharts.swift", "Shared/EnergyDetails.swift", "Deye/EnergyValueView.swift", "Deye/DeyeStore.swift", "Tuya/TuyaStore.swift",
    "Deye/DeyeCloud.swift", "Deye/DeyeReading.swift", "Deye/EnergyPricing.swift",
    "Tuya/TuyaCloud.swift", "Tuya/TuyaCrypto.swift", "Tuya/TuyaReading.swift",
    "TCL/TCLCloud.swift", "TCL/DeviceService.swift", "TCL/Climate.swift",
    "TCL/EnergyHistory.swift", "TCL/EnergyPeriod.swift", "TCL/EnergySync.swift",
    "LG/ThinQ.swift", "LG/LGDeviceState.swift", "Bluetti/Bluetooth/BluettiBluetooth.swift",
    "Bluetti/Protocol/BluettiIoTProtocol.swift", "Bluetti/Protocol/BluettiIoTCrypto.swift",
    "Bluetti/Protocol/BluettiFrameDecoder.swift", "Bluetti/Readings/AC50PChargeTime.swift",
]


def identifier(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def generate():
    objects = {}

    def add(object_name, **value):
        key = identifier(object_name)
        objects[key] = value
        return key

    files = ["../Sources/" + path for path in SHARED]
    files += [str(path.relative_to(ROOT)) for path in sorted((ROOT / "App").glob("*.swift"))]
    files += [str(path.relative_to(ROOT)) for path in sorted((ROOT / "Shared").glob("*.swift"))]
    files += ["Widgets/SuperBarWidgets.swift"]
    files += ["App/Assets.xcassets", "App/PrivacyInfo.xcprivacy", "Widgets/PrivacyInfo.xcprivacy"]
    files += ["../Resources/THIRD_PARTY_NOTICES.txt", "../Scripts/TUYA-NOTICE.txt"]
    files += ["../Resources/" + path.name for path in sorted((ROOT.parent / "Resources").glob("TCL-*.png"))]
    refs = {}
    for path in files:
        assert (ROOT / path).exists(), path
        refs[path] = add("file:" + path, isa="PBXFileReference", path=path, sourceTree="<group>",
                         lastKnownFileType="sourcecode.swift" if path.endswith(".swift") else "folder.assetcatalog" if path.endswith(".xcassets") else "image.png" if path.endswith(".png") else "text")

    def phase(name, kind, paths):
        builds = [add(name + ":" + path, isa="PBXBuildFile", fileRef=refs[path]) for path in paths]
        return add(name, isa=kind, buildActionMask=2147483647, files=builds, runOnlyForDeploymentPostprocessing=0)

    common = dict(SWIFT_VERSION="5.0", IPHONEOS_DEPLOYMENT_TARGET="17.0", SDKROOT="iphoneos",
                  SUPPORTED_PLATFORMS="iphoneos iphonesimulator", TARGETED_DEVICE_FAMILY="1,2",
                  CLANG_ENABLE_MODULES="YES", ENABLE_USER_SCRIPT_SANDBOXING="YES",
                  CODE_SIGN_STYLE="Automatic", CURRENT_PROJECT_VERSION="1", MARKETING_VERSION="0.1.0",
                  SUPER_BAR_APP_GROUP="group.com.sonnenhaft.superbar", SWIFT_EMIT_LOC_STRINGS="YES")

    def configs(name, settings):
        values = []
        for mode in ["Debug", "Release"]:
            config = dict(settings)
            config.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if mode == "Debug" else "-O",
                          DEBUG_INFORMATION_FORMAT="dwarf" if mode == "Debug" else "dwarf-with-dsym")
            if mode == "Debug":
                config["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
            values.append(add(name + mode, isa="XCBuildConfiguration", name=mode, buildSettings=config))
        return add(name + "Configs", isa="XCConfigurationList", buildConfigurations=values,
                   defaultConfigurationIsVisible=0, defaultConfigurationName="Release")

    app_product = add("appProduct", isa="PBXFileReference", path="SuperBar.app", sourceTree="BUILT_PRODUCTS_DIR", explicitFileType="wrapper.application", includeInIndex=0)
    widget_product = add("widgetProduct", isa="PBXFileReference", path="SuperBarWidgets.appex", sourceTree="BUILT_PRODUCTS_DIR", explicitFileType="wrapper.app-extension", includeInIndex=0)
    products = add("products", isa="PBXGroup", name="Products", sourceTree="<group>", children=[app_product, widget_product])
    main = add("main", isa="PBXGroup", sourceTree="<group>", children=list(refs.values()) + [products])
    widget_target = identifier("widgets")
    project_id = identifier("project")
    proxy = add("widgetProxy", isa="PBXContainerItemProxy", containerPortal=project_id, proxyType=1,
                remoteGlobalIDString=widget_target, remoteInfo="SuperBarWidgets")
    dependency = add("widgetDependency", isa="PBXTargetDependency", target=widget_target, targetProxy=proxy)
    embedded = add("embeddedWidget", isa="PBXBuildFile", fileRef=widget_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
    embed = add("embed", isa="PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="", dstSubfolderSpec=13,
                files=[embedded], name="Embed App Extensions", runOnlyForDeploymentPostprocessing=0)
    app_sources = [p for p in files if p.endswith(".swift") and not p.startswith("Widgets/")]
    widget_sources = [p for p in files if p.endswith(".swift") and (p.startswith("Shared/") or p.startswith("Widgets/") or p in {"../Sources/" + source for source in SHARED_UI})]
    for name, target, product, sources, plist, bundle, extension in [
        ("SuperBar", "app", app_product, app_sources, "App/Info.plist", "com.sonnenhaft.superbar.ios", False),
        ("SuperBarWidgets", "widgets", widget_product, widget_sources, "Widgets/Info.plist", "com.sonnenhaft.superbar.ios.widgets", True),
    ]:
        settings = dict(PRODUCT_NAME=name, PRODUCT_BUNDLE_IDENTIFIER=bundle, INFOPLIST_FILE=plist,
                        CODE_SIGN_ENTITLEMENTS="SuperBar.entitlements", GENERATE_INFOPLIST_FILE="NO",
                        LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks"])
        if extension:
            settings.update(APPLICATION_EXTENSION_API_ONLY="YES", SKIP_INSTALL="YES",
                            OTHER_SWIFT_FLAGS="$(inherited) -D WIDGET_EXTENSION",
                            LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"])
        else:
            settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
            settings["SUPER_BAR_PRIVACY_POLICY_URL"] = ""
        phases = [phase(target + "Sources", "PBXSourcesBuildPhase", sources),
                  phase(target + "Resources", "PBXResourcesBuildPhase", ["Widgets/PrivacyInfo.xcprivacy"] if extension else ["App/PrivacyInfo.xcprivacy"] + [p for p in files if p.endswith((".txt", ".xcassets", ".png"))]),
                  phase(target + "Frameworks", "PBXFrameworksBuildPhase", [])]
        if not extension:
            phases.append(embed)
        add(target, isa="PBXNativeTarget", name=name, productName=name, productReference=product,
            productType="com.apple.product-type.app-extension" if extension else "com.apple.product-type.application",
            buildConfigurationList=configs(target, settings), buildPhases=phases, buildRules=[], dependencies=[] if extension else [dependency])
    add("project", isa="PBXProject", attributes={"LastUpgradeCheck": "1600", "BuildIndependentTargetsInParallel": "YES"},
        buildConfigurationList=configs("project", common), compatibilityVersion="Xcode 14.0", developmentRegion="en",
        hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=main, productRefGroup=products,
        projectDirPath="", projectRoot="", targets=[identifier("app"), widget_target])

    def serialize(value, indent=0):
        if isinstance(value, dict):
            return "{\n" + "".join("\t" * (indent + 1) + json.dumps(k) + " = " + serialize(v, indent + 1) + ";\n" for k, v in value.items()) + "\t" * indent + "}"
        if isinstance(value, list):
            return "(" + ", ".join(serialize(v, indent) for v in value) + ")"
        return str(value) if isinstance(value, int) else json.dumps(value)

    project = ROOT / "SuperBar.xcodeproj"
    project.mkdir(exist_ok=True)
    content = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project_id}
    (project / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(content) + "\n")
    scheme_dir = project / "xcshareddata/xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier("app")}" BuildableName="SuperBar.app" BlueprintName="SuperBar" ReferencedContainer="container:SuperBar.xcodeproj"/>'
    (scheme_dir / "SuperBar.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
    base = dict(CFBundleDevelopmentRegion="en", CFBundleExecutable="$(EXECUTABLE_NAME)",
                CFBundleIdentifier="$(PRODUCT_BUNDLE_IDENTIFIER)", CFBundleInfoDictionaryVersion="6.0",
                CFBundleName="$(PRODUCT_NAME)", CFBundleShortVersionString="$(MARKETING_VERSION)",
                CFBundleVersion="$(CURRENT_PROJECT_VERSION)", SuperBarAppGroup="$(SUPER_BAR_APP_GROUP)")
    app_info = dict(base, CFBundleDisplayName="Super Bar", CFBundlePackageType="APPL", LSRequiresIPhoneOS=True,
                    SuperBarPrivacyPolicyURL="$(SUPER_BAR_PRIVACY_POLICY_URL)",
                    UILaunchScreen={}, UIApplicationSceneManifest={"UIApplicationSupportsMultipleScenes": False},
                    UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
                    NSBluetoothAlwaysUsageDescription="Super Bar reads battery level and power from your nearby BLUETTI AC50P after you tap Find stations.",
                    UIBackgroundModes=["fetch"], BGTaskSchedulerPermittedIdentifiers=["com.sonnenhaft.superbar.refresh"],
                    CFBundleURLTypes=[{"CFBundleURLName": "Super Bar", "CFBundleURLSchemes": ["superbar"]}])
    app_info["UISupportedInterfaceOrientations~ipad"] = app_info["UISupportedInterfaceOrientations"] + ["UIInterfaceOrientationPortraitUpsideDown"]
    widget_info = dict(base, CFBundleDisplayName="Super Bar Widgets", CFBundlePackageType="XPC!",
                       NSExtension={"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"})
    for path, value in [("App/Info.plist", app_info), ("Widgets/Info.plist", widget_info),
                        ("SuperBar.entitlements", {"com.apple.security.application-groups": ["$(SUPER_BAR_APP_GROUP)"]})]:
        (ROOT / path).write_bytes(plistlib.dumps(value, sort_keys=False))
    print(f"Generated {project} ({len(app_sources)} app sources; {len(widget_sources)} widget sources)")


if __name__ == "__main__":
    generate()
