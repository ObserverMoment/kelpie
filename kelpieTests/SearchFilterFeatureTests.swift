import ComposableArchitecture
import Foundation
import Testing

@testable import kelpie

@MainActor
struct SearchFilterFeatureTests {
  @Test func requestedShowsTheFieldAndAsksForFocus() async {
    let store = TestStore(initialState: SearchFilterFeature.State()) { SearchFilterFeature() }
    await store.send(.requested) {
      $0.query = ""
      $0.focusRequestCount = 1
      $0.isFocused = true
    }
    #expect(store.state.isPresented)
    #expect(store.state.activeQuery == nil)
  }

  @Test func repeatedRequestKeepsTheTextAndRefocuses() async {
    let store = TestStore(initialState: SearchFilterFeature.State(query: "kel", focusRequestCount: 1)) {
      SearchFilterFeature()
    }
    await store.send(.requested) {
      $0.focusRequestCount = 2
      $0.isFocused = true
    }
    #expect(store.state.query == "kel")
  }

  @Test func queryChangedTrimsForTheActiveQuery() async {
    let store = TestStore(initialState: SearchFilterFeature.State(query: "")) { SearchFilterFeature() }
    await store.send(.queryChanged(" kel ")) { $0.query = " kel " }
    #expect(store.state.activeQuery == "kel")
    await store.send(.queryChanged("  ")) { $0.query = "  " }
    #expect(store.state.activeQuery == nil)
  }

  @Test func dismissedHidesAndReleasesFocus() async {
    let store = TestStore(initialState: SearchFilterFeature.State(query: "kel", isFocused: true)) {
      SearchFilterFeature()
    }
    await store.send(.dismissed) {
      $0.query = nil
      $0.isFocused = false
    }
    #expect(!store.state.isPresented)
  }

  @Test func focusChangedIsRecorded() async {
    let store = TestStore(initialState: SearchFilterFeature.State(query: "")) { SearchFilterFeature() }
    await store.send(.focusChanged(true)) { $0.isFocused = true }
    await store.send(.focusChanged(false)) { $0.isFocused = false }
  }
}
