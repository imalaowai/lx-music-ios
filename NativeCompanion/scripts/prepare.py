#!/usr/bin/env python3
"""Generate a dependency-free Xcode project; no CocoaPods/React Native build."""
import base64, hashlib, json, pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[1]
def ident(value): return hashlib.sha256(value.encode()).hexdigest()[:24].upper()
objects = {}
def add(name, content): objects[ident(name)] = content; return ident(name)
def q(value): return json.dumps(str(value), ensure_ascii=False)
sources = sorted(root.joinpath('Sources').glob('*.swift'))
source_refs, source_builds, resource_refs, resource_builds = [], [], [], []
for file in sources:
    rel = file.relative_to(root).as_posix()
    reference = add(rel, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(rel)}; sourceTree = "<group>";')
    source_refs.append(reference)
    source_builds.append(add('build-'+rel, f'isa = PBXBuildFile; fileRef = {reference};'))
assets = root/'generated/Assets.xcassets/AppIcon.appiconset'
assets.mkdir(parents=True, exist_ok=True)
seed = root/'generated/icon.png'
seed.write_bytes(base64.b64decode((root/'Resources/Icon.base64').read_text()))
images = []
for points, scale in [(20,2),(20,3),(29,2),(29,3),(40,2),(40,3),(60,2),(60,3)]:
    size = points*scale; filename = f'iphone-{points}-{scale}.png'
    if sys.platform == 'darwin': subprocess.run(['sips','-z',str(size),str(size),str(seed),'--out',str(assets/filename)],check=True,stdout=subprocess.DEVNULL)
    images.append({'idiom':'iphone','size':f'{points}x{points}','scale':f'{scale}x','filename':filename})
for points,scale in [(20,1),(20,2),(29,1),(29,2),(40,1),(40,2),(76,1),(76,2),(83.5,2)]:
    size = int(points*scale); filename = f'ipad-{points}-{scale}.png'
    if sys.platform == 'darwin': subprocess.run(['sips','-z',str(size),str(size),str(seed),'--out',str(assets/filename)],check=True,stdout=subprocess.DEVNULL)
    images.append({'idiom':'ipad','size':f'{points}x{points}','scale':f'{scale}x','filename':filename})
(assets/'marketing.png').write_bytes(seed.read_bytes())
images.append({'idiom':'ios-marketing','size':'1024x1024','scale':'1x','filename':'marketing.png'})
(assets/'Contents.json').write_text(json.dumps({'images':images,'info':{'version':1,'author':'xcode'}},indent=2))
for rel,kind in [('Resources/Bridge.js','text'),('Resources/LaunchScreen.storyboard','file.storyboard'),('generated/Assets.xcassets','folder.assetcatalog')]:
    reference=add(rel,f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {q(rel)}; sourceTree = "<group>";')
    resource_refs.append(reference);resource_builds.append(add('build-'+rel,f'isa = PBXBuildFile; fileRef = {reference};'))
product=add('product','isa = PBXFileReference; explicitFileType = wrapper.application; path = LXCompanion.app; sourceTree = BUILT_PRODUCTS_DIR;')
products=add('products',f'isa = PBXGroup; name = Products; children = ({product},); sourceTree = "<group>";')
group=add('root',f'isa = PBXGroup; children = ({",".join(source_refs+resource_refs+[products])},); sourceTree = "<group>";')
source_phase=add('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(source_builds)},); runOnlyForDeploymentPostprocessing = 0;')
resource_phase=add('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resource_builds)},); runOnlyForDeploymentPostprocessing = 0;')
framework_phase=add('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
target_configs=[];project_configs=[]
for name in ['Debug','Release']:
    project_configs.append(add('project-'+name,f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{CLANG_ENABLE_MODULES = YES; IPHONEOS_DEPLOYMENT_TARGET = 15.0; SDKROOT = iphoneos; }};'))
    target_configs.append(add('target-'+name,f'''isa = XCBuildConfiguration; name = {name}; buildSettings = {{
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; CODE_SIGNING_ALLOWED = NO; CODE_SIGNING_REQUIRED = NO;
GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = Info.plist; IPHONEOS_DEPLOYMENT_TARGET = 15.0;
PRODUCT_BUNDLE_IDENTIFIER = net.minyue.lxcompanion; PRODUCT_NAME = LXCompanion;
SWIFT_VERSION = 5.0; SWIFT_STRICT_CONCURRENCY = minimal; SWIFT_OPTIMIZATION_LEVEL = {q('-Onone' if name=='Debug' else '-O')};
TARGETED_DEVICE_FAMILY = "1,2"; SUPPORTS_MACCATALYST = NO; CURRENT_PROJECT_VERSION = 1;
LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
}};'''))
target_config=add('target-config',f'isa = XCConfigurationList; buildConfigurations = ({",".join(target_configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
project_config=add('project-config',f'isa = XCConfigurationList; buildConfigurations = ({",".join(project_configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target=add('target',f'isa = PBXNativeTarget; name = LXCompanion; productName = LXCompanion; productReference = {product}; productType = "com.apple.product-type.application"; buildConfigurationList = {target_config}; buildPhases = ({source_phase},{framework_phase},{resource_phase},); buildRules = (); dependencies = ();')
project=add('project',f'isa = PBXProject; buildConfigurationList = {project_config}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (en,zh_CN,Base,); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},); attributes = {{LastUpgradeCheck = 1600; }};')
directory=root/'LXCompanion.xcodeproj';directory.mkdir(exist_ok=True)
content='// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(f'{key} = {{{value}}};' for key,value in objects.items())+f'\n}}; rootObject = {project};}}\n'
(directory/'project.pbxproj').write_text(content)
schemes=directory/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
(schemes/'LXCompanion.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="LXCompanion.app" BlueprintName="LXCompanion" ReferencedContainer="container:LXCompanion.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"/><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print(f'Generated Xcode project with {len(sources)} Swift source files.')
