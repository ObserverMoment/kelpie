import ProjectDescription

let ghosttyXCFrameworkPath: Path = ".build/ghostty/GhosttyKit.xcframework"
let ghosttyResourcesPath: Path = ".build/ghostty/share/ghostty"
let ghosttyTerminfoPath: Path = ".build/ghostty/share/terminfo"
let ghosttyBuildScriptPath: Path = "scripts/build-ghostty.sh"
let verifyGitWtScriptPath: Path = "scripts/verify-git-wt.sh"
let zmxBuildScriptPath: Path = "scripts/build-zmx.sh"
let zmxBinaryPath: Path = ".build/zmx/bin/zmx"
let embedGhosttyResourcesScriptPath: Path = "scripts/embed-ghostty-resources.sh"
let embedRuntimeAssetsScriptPath: Path = "scripts/embed-runtime-assets.sh"

func shellScript(_ path: Path) -> String {
  "\"${SRCROOT}/\(path.pathString)\""
}

let ghosttyFingerprintInputScript = """
"./\(ghosttyBuildScriptPath.pathString)" --print-fingerprint
"""

let appResources: ResourceFileElements = [
  "kelpie/AppIcon.icon",
  "kelpie/Assets.xcassets",
  "kelpie/notification.wav",
]

let appBuildableFolders: [BuildableFolder] = [
  "kelpie/App",
  "kelpie/Clients",
  "kelpie/Commands",
  "kelpie/Domain",
  "kelpie/Features",
  "kelpie/Infrastructure",
  "kelpie/Support",
]

let appDependencies: [TargetDependency] = [
  .target(name: "KelpieSettingsShared"),
  .target(name: "KelpieSettingsFeature"),
  .target(name: "GhosttyKit"),
  .target(name: "kelpie-cli"),
  .external(name: "ComposableArchitecture"),
  .external(name: "CustomDump"),
  .external(name: "Dependencies"),
  .external(name: "IdentifiedCollections"),
  .external(name: "Kingfisher"),
  .external(name: "OrderedCollections"),
  .external(name: "PostHog"),
  .external(name: "Sentry"),
  .external(name: "Sharing"),
  .external(name: "Sparkle"),
]

let testDependencies: [TargetDependency] = [
  .target(name: "GhosttyKit"),
  .target(name: "KelpieSettingsShared"),
  .target(name: "KelpieSettingsFeature"),
  .target(name: "kelpie"),
  .external(name: "Clocks"),
  .external(name: "ComposableArchitecture"),
  .external(name: "ConcurrencyExtras"),
  .external(name: "CustomDump"),
  .external(name: "Dependencies"),
  .external(name: "DependenciesTestSupport"),
  .external(name: "IdentifiedCollections"),
  .external(name: "OrderedCollections"),
  .external(name: "PostHog"),
  .external(name: "Sharing"),
]

// Tests are split into three host-app bundles so xcodebuild can run them in
// separate processes: most tests are MainActor-bound, so one bundle caps the
// whole suite at a single main thread.
let sharedTestSupportSources: [Path] = [
  "kelpieTests/AgentPresence+TestHelpers.swift",
  "kelpieTests/BrandedIDTestSupport.swift",
  "kelpieTests/LoginShellTestSupport.swift",
  "kelpieTests/ProcessTestSupport.swift",
  "kelpieTests/RemoteRepoTestSupport.swift",
  "kelpieTests/RepositoriesSidebarTestHelpers.swift",
  "kelpieTests/RepositoryLocalSettingsTestStorage.swift",
  "kelpieTests/RepositoriesStateTestHelpers.swift",
  "kelpieTests/SettingsTestStorage.swift",
  "kelpieTests/ShellInvocationTestSupport.swift",
  "kelpieTests/SidebarConsistency.swift",
  "kelpieTests/TabContentTestSupport.swift",
  "kelpieTests/WorktreeTestSupport.swift",
  "kelpieTests/WritableKeyPath+Sendable.swift",
]

// Real git / shell subprocess suites.
let gitTestSources: [Path] = [
  "kelpieTests/AgentHook*.swift",
  "kelpieTests/Git*.swift",
  "kelpieTests/RemoteSSHCommandTests.swift",
  "kelpieTests/ShellClient*.swift",
  "kelpieTests/SocketLivenessCLITests.swift",
  "kelpieTests/WorktreeEnvironmentTests.swift",
  "kelpieTests/WorktreeStatusCLITests.swift",
]

// AppFeature and RepositoriesFeature suites, the two biggest TestStore
// families; without their own bundle the main bundle is the wall-clock pole.
let featureTestSources: [Path] = [
  "kelpieTests/AppFeature*.swift",
  "kelpieTests/RepositoriesFeature*.swift",
]

// Ghostty runtime, terminal manager, and zmx suites.
let terminalTestSources: [Path] = [
  "kelpieTests/Ghostty*.swift",
  "kelpieTests/LayoutFeature*.swift",
  "kelpieTests/Layouts*.swift",
  "kelpieTests/SplitTree*.swift",
  "kelpieTests/WorktreeTerminalManager*.swift",
  "kelpieTests/Zmx*.swift",
]

func testBundle(name: String, sources: [SourceFileGlob]) -> Target {
  .target(
    name: name,
    destinations: .macOS,
    product: .unitTests,
    bundleId: "com.observermoment.\(name)",
    deploymentTargets: .macOS("26.1"),
    infoPlist: .default,
    sources: SourceFilesList.sourceFilesList(globs: sources),
    dependencies: testDependencies,
    settings: .settings(
      base: [
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/kelpie.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/kelpie",
      ],
      defaultSettings: .essential
    )
  )
}

let embedGhosttyResourcesInputPaths: [FileListGlob] = [
  "$(SRCROOT)/\(ghosttyResourcesPath.pathString)",
  "$(SRCROOT)/\(ghosttyTerminfoPath.pathString)",
]

let embedGhosttyResourcesOutputPaths: [Path] = [
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ghostty",
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/terminfo",
]

let embedRuntimeAssetsInputPaths: [FileListGlob] = [
  "$(SRCROOT)/Resources/git-wt/wt",
  "$(SRCROOT)/\(zmxBinaryPath.pathString)",
  "$(SRCROOT)/kelpie/Resources/Themes/Kelpie Light",
  "$(SRCROOT)/kelpie/Resources/Themes/Kelpie Dark",
  "$(BUILT_PRODUCTS_DIR)/kelpie",
  "$(UNINSTALLED_PRODUCTS_DIR)/$(PLATFORM_NAME)/kelpie",
]

let embedRuntimeAssetsOutputPaths: [Path] = [
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/git-wt/wt",
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/zmx/zmx",
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Kelpie Light",
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Kelpie Dark",
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/kelpie",
]

let project = Project(
  name: "kelpie",
  settings: .settings(
    base: [
      "CLANG_ENABLE_MODULES": "YES",
      "CODE_SIGN_STYLE": "Automatic",
      "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
      "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
      "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
      "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
      "SWIFT_VERSION": "6.0",
    ],
    configurations: [
      .debug(name: .debug, xcconfig: "Configurations/Project.xcconfig"),
      .release(name: .release, xcconfig: "Configurations/Project.xcconfig"),
    ],
    defaultSettings: .essential
  ),
  targets: [
    .target(
      name: "kelpie-cli",
      destinations: .macOS,
      product: .commandLineTool,
      bundleId: "com.observermoment.kelpie.cli",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .default,
      buildableFolders: [
        "kelpie-cli",
      ],
      dependencies: [
        .external(name: "ArgumentParser"),
      ],
      settings: .settings(
        base: [
          "CODE_SIGNING_ALLOWED": "NO",
          "ENABLE_HARDENED_RUNTIME": "YES",
          "PRODUCT_MODULE_NAME": "kelpie_cli",
          "PRODUCT_NAME": "kelpie",
          "SKIP_INSTALL": "YES",
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
        ],
        defaultSettings: .essential
      )
    ),
    .foreignBuild(
      name: "GhosttyKit",
      destinations: .macOS,
      script: """
        "${SRCROOT}/\(ghosttyBuildScriptPath.pathString)"
        """,
      inputs: [
        .file("mise.toml"),
        .file(ghosttyBuildScriptPath),
        .script(ghosttyFingerprintInputScript),
      ],
      output: .xcframework(path: ghosttyXCFrameworkPath, linking: .static)
    ),
    .target(
      name: "KelpieSettingsShared",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "com.observermoment.kelpie.settings-shared",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .default,
      resources: [
        .folderReference(path: "Resources/Skills"),
      ],
      buildableFolders: [
        "KelpieSettingsShared",
      ],
      dependencies: [
        .external(name: "ComposableArchitecture"),
        .external(name: "Dependencies"),
        .external(name: "PostHog"),
        .external(name: "Sharing"),
      ],
      settings: .settings(
        base: [
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
        ],
        defaultSettings: .essential
      )
    ),
    .target(
      name: "KelpieSettingsFeature",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "com.observermoment.kelpie.settings-feature",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .default,
      buildableFolders: [
        "KelpieSettingsFeature",
      ],
      dependencies: [
        .target(name: "KelpieSettingsShared"),
        .external(name: "ComposableArchitecture"),
        .external(name: "Dependencies"),
        .external(name: "Sharing"),
      ],
      settings: .settings(
        base: [
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
        ],
        defaultSettings: .essential
      )
    ),
    .target(
      name: "kelpie",
      destinations: .macOS,
      product: .app,
      bundleId: "com.observermoment.kelpie",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .file(path: "kelpie/Info.plist"),
      resources: appResources,
      buildableFolders: appBuildableFolders,
      scripts: [
        .pre(
          script: shellScript(verifyGitWtScriptPath),
          name: "Verify git-wt",
          basedOnDependencyAnalysis: false
        ),
        .pre(
          script: shellScript(zmxBuildScriptPath),
          name: "Build zmx",
          basedOnDependencyAnalysis: false
        ),
        .post(
          script: shellScript(embedGhosttyResourcesScriptPath),
          name: "Embed Ghostty Resources",
          inputPaths: embedGhosttyResourcesInputPaths,
          outputPaths: embedGhosttyResourcesOutputPaths,
          basedOnDependencyAnalysis: false
        ),
        .post(
          script: shellScript(embedRuntimeAssetsScriptPath),
          name: "Embed Runtime Assets",
          inputPaths: embedRuntimeAssetsInputPaths,
          outputPaths: embedRuntimeAssetsOutputPaths,
          basedOnDependencyAnalysis: false
        ),
      ],
      dependencies: appDependencies,
      settings: .settings(
        base: [
          "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
          "ENABLE_HARDENED_RUNTIME": "YES",
          "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
          "OTHER_LDFLAGS": "$(inherited) -lc++",
        ],
        debug: [
          "CODE_SIGN_ENTITLEMENTS": "kelpie/kelpieDebug.entitlements",
        ],
        release: [
          "CODE_SIGN_ENTITLEMENTS": "kelpie/kelpie.entitlements",
        ],
        defaultSettings: .essential
      )
    ),
    testBundle(
      name: "kelpieTests",
      sources: [
        SourceFileGlob.glob(
          "kelpieTests/**",
          excluding: featureTestSources + gitTestSources + terminalTestSources
        ),
      ]
    ),
    testBundle(
      name: "kelpieFeatureTests",
      sources: (featureTestSources + sharedTestSupportSources).map { SourceFileGlob.glob($0) }
    ),
    testBundle(
      name: "kelpieGitTests",
      sources: (gitTestSources + sharedTestSupportSources).map { SourceFileGlob.glob($0) }
    ),
    testBundle(
      name: "kelpieTerminalTests",
      sources: (terminalTestSources + sharedTestSupportSources).map { SourceFileGlob.glob($0) }
    ),
  ],
  schemes: [
    // Explicit all-bundles test scheme: the autogenerated `kelpie` scheme
    // only tests kelpieTests, and custom workspace schemes do not generate.
    .scheme(
      name: "kelpie-tests",
      buildAction: .buildAction(targets: ["kelpie"]),
      testAction: .targets(
        [
          .testableTarget(target: "kelpieTests", parallelization: .enabled),
          .testableTarget(target: "kelpieFeatureTests", parallelization: .enabled),
          .testableTarget(target: "kelpieGitTests", parallelization: .enabled),
          .testableTarget(target: "kelpieTerminalTests", parallelization: .enabled),
        ],
        configuration: .debug
      )
    ),
  ],
  additionalFiles: [
    "Configurations/**",
  ],
  resourceSynthesizers: []
)
