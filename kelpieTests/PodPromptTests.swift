import Foundation
import Testing

@testable import kelpie

struct PodPromptTests {
  private let surfaceID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!

  @Test func registerNamesThePodTheMemberAndTheSurface() {
    let text = PodPrompt.register(podName: "Chat", memberName: "Frontend agent", surfaceID: surfaceID)
    #expect(text.hasPrefix("[Kelpie] You are being added to the agent pod \"Chat\" as \"Frontend agent\"."))
    #expect(text.contains("ListAgents"))
    #expect(
      text.contains("kelpie pod register --surface 00000000-0000-0000-0000-00000000000A --name <your session name>"))
  }

  @Test func rosterListsPodmatesAsJSONAndSetsTheBar() {
    let you = PodPrompt.Podmate(id: "kelpie-a", name: "Frontend agent", description: "Chat UI")
    let backend = PodPrompt.Podmate(id: "kelpie-b", name: "Backend agent", description: "Chat API")
    let text = PodPrompt.roster(podName: "Chat", podDescription: "Build chat", you: you, podmates: [backend])
    #expect(text.hasPrefix("[Kelpie] You are in the agent pod \"Chat\" (Build chat) as \"Frontend agent\": Chat UI."))
    #expect(text.contains(#"[{"description":"Chat API","id":"kelpie-b","name":"Backend agent"}]"#))
    #expect(!text.contains("kelpie-a"))
    #expect(text.contains("only when you change or decide something they depend on"))
    #expect(text.contains("Do not send progress updates"))
  }

  @Test func rosterLeavesOutEmptyDescriptions() {
    let you = PodPrompt.Podmate(id: "kelpie-a", name: "Frontend agent", description: "")
    let text = PodPrompt.roster(podName: "Chat", podDescription: "", you: you, podmates: [])
    #expect(text.hasPrefix("[Kelpie] You are in the agent pod \"Chat\" as \"Frontend agent\". Your podmates"))
  }

  @Test func disbandedTellsTheMemberToStop() {
    let text = PodPrompt.disbanded(podName: "Chat")
    #expect(text.contains("\"Chat\" was disbanded"))
    #expect(text.contains("Stop messaging your former podmates"))
  }
}
