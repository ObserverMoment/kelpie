import ProjectDescription

let workspace = Workspace(
  name: "kelpie",
  projects: [
    ".",
  ],
  schemes: [
    .scheme(
      name: "kelpie",
      buildAction: .buildAction(
        targets: [
          .project(path: "kelpie.xcodeproj", target: "kelpie"),
        ],
        runPostActionsOnFailure: true
      ),
      testAction: .targets(
        [
          .testableTarget(
            target: .project(path: "kelpie.xcodeproj", target: "kelpieTests")
          ),
        ],
        configuration: .debug,
        expandVariableFromTarget: .project(path: "kelpie.xcodeproj", target: "kelpie")
      ),
      runAction: .runAction(
        configuration: .debug,
        executable: .executable(.project(path: "kelpie.xcodeproj", target: "kelpie")),
        expandVariableFromTarget: .project(path: "kelpie.xcodeproj", target: "kelpie")
      ),
      archiveAction: .archiveAction(configuration: .release),
      profileAction: .profileAction(
        configuration: .release,
        executable: .project(path: "kelpie.xcodeproj", target: "kelpie")
      ),
      analyzeAction: .analyzeAction(configuration: .debug)
    ),
  ]
)
