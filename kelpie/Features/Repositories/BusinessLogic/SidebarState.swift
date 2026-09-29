import Foundation
import KelpieSettingsShared
import OrderedCollections

/// User-curated sidebar state persisted to `~/.kelpie/sidebar.json`.
///
/// The shape mirrors the rendered tree: the root holds sections (one
/// per repository row), each section holds buckets (pinned /
/// unpinned / archived), and each bucket holds items (one per
/// worktree row). Readers access everything via keyed lookup —
/// `sections[repo]?.buckets[.pinned]?.items[wt]` — so callers never
/// rely on bucket iteration order. `Item.archivedAt` is non-`nil`
/// only inside the `.archived` bucket; the mutating API clears it
/// when an item leaves `.archived`, so the field is a reliable "is
/// this currently archived?" signal without a separate bucket
/// check.
///
/// Mutations go through typed primitives that take full coordinates
/// — repo + worktree + source bucket — so every helper is O(1) by
/// construction and the sidebar stays the single source of truth for
/// pin/order/archive state. `move`, `insert`, `archive`, `unarchive`,
/// `remove`, `reorder` cover the full mutation surface; callers
/// always know the source bucket from their reducer context.
nonisolated struct SidebarState: Equatable, Sendable, Codable {
  var schemaVersion: Int
  var sections: OrderedDictionary<Repository.ID, Section>
  var focusedWorktreeID: Worktree.ID?
  /// User-defined accordion groups of repositories. Membership lives on the
  /// group; the top-down order of a group's members is the `sections` key
  /// order, so there is exactly one persisted sidebar order. Additive key
  /// with no schema bump: a build that predates groups decodes the blob
  /// fine, and its next save drops the key, so a downgrade loses groups.
  var groups: OrderedDictionary<RepositoryGroupID, RepositoryGroup>

  /// Memberwise initializer. `schemaVersion` defaults to `0`, meaning
  /// "not migrated yet, or migrator failed". The boot-time migrator
  /// is the only writer that sets it to `1`; every other writer
  /// (including the default `SidebarState()` path and mutations
  /// persisted by `SidebarKey.save`) leaves it at `0`.
  init(
    schemaVersion: Int = 0,
    sections: OrderedDictionary<Repository.ID, Section> = [:],
    focusedWorktreeID: Worktree.ID? = nil,
    groups: OrderedDictionary<RepositoryGroupID, RepositoryGroup> = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.sections = sections
    self.focusedWorktreeID = focusedWorktreeID
    self.groups = groups
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case sections
    case focusedWorktreeID
    case groups
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Default to `0` when the key is absent so existing
    // `sidebar.json` files written before `schemaVersion` existed
    // decode as "not migrated yet".
    self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
    self.sections =
      try container.decodeIfPresent(
        OrderedDictionary<Repository.ID, Section>.self,
        forKey: .sections
      ) ?? [:]
    self.focusedWorktreeID = try container.decodeIfPresent(Worktree.ID.self, forKey: .focusedWorktreeID)
    // Additive field: blobs written before groups existed have no key. `try?`
    // so one malformed group entry costs the groups, not every pin and title.
    self.groups =
      (try? container.decodeIfPresent(
        OrderedDictionary<RepositoryGroupID, RepositoryGroup>.self,
        forKey: .groups
      )) ?? [:]
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    // Always encode `schemaVersion` so the value round-trips and the
    // migrator can distinguish "written by migrator" from "written by
    // first-mutation after migrator failure".
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(sections, forKey: .sections)
    try container.encodeIfPresent(focusedWorktreeID, forKey: .focusedWorktreeID)
    // Omit when empty so blobs for users who never made a group stay
    // byte-identical to what older builds wrote.
    if !groups.isEmpty {
      try container.encode(groups, forKey: .groups)
    }
  }

  /// A user-named accordion of repositories. Only `name`, the open/closed
  /// bit, and membership are stored; row order comes from `sections`.
  nonisolated struct RepositoryGroup: Equatable, Sendable, Codable, Identifiable {
    var id: RepositoryGroupID
    var name: String
    var collapsed: Bool
    /// Member repositories. Membership only: readers order members by
    /// their position in `sections`, so this array is never sorted.
    var repositoryIDs: [Repository.ID]

    init(id: RepositoryGroupID, name: String, collapsed: Bool = false, repositoryIDs: [Repository.ID] = []) {
      self.id = id
      self.name = name
      self.collapsed = collapsed
      self.repositoryIDs = repositoryIDs
    }

    private enum CodingKeys: String, CodingKey {
      case id
      case name
      case collapsed
      case repositoryIDs
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.id = try container.decode(RepositoryGroupID.self, forKey: .id)
      self.name = try container.decode(String.self, forKey: .name)
      self.collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
      self.repositoryIDs = try container.decodeIfPresent([Repository.ID].self, forKey: .repositoryIDs) ?? []
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .id)
      try container.encode(name, forKey: .name)
      if collapsed {
        try container.encode(collapsed, forKey: .collapsed)
      }
      if !repositoryIDs.isEmpty {
        try container.encode(repositoryIDs, forKey: .repositoryIDs)
      }
    }
  }

  nonisolated enum BucketID: String, Codable, Hashable, Sendable {
    case pinned
    case unpinned
    case archived
  }

  /// Curation state of a worktree row, flattened for external consumers.
  /// The raw values are the `kelpie worktree` wire and stdout contract.
  nonisolated enum WorktreeStatus: String, Equatable, Sendable, CaseIterable {
    case main
    case pinned
    case unpinned
    case archived

    var isArchived: Bool { self == .archived }
  }

  nonisolated struct Section: Equatable, Sendable, Codable {
    var collapsed: Bool
    var buckets: OrderedDictionary<BucketID, Bucket>
    /// Optional user-supplied display title that overrides the
    /// repository folder name in the sidebar header. `nil` (or
    /// whitespace-only after trim) means "use the default name".
    var title: String?
    /// Optional user-supplied tint applied to the sidebar header.
    /// `nil` means "default / no tint".
    var color: RepositoryColor?

    init(
      collapsed: Bool = false,
      buckets: OrderedDictionary<BucketID, Bucket> = [:],
      title: String? = nil,
      color: RepositoryColor? = nil
    ) {
      self.collapsed = collapsed
      self.buckets = buckets
      self.title = title
      self.color = color
    }

    private enum SectionCodingKeys: String, CodingKey {
      case collapsed
      case buckets
      case title
      case color
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: SectionCodingKeys.self)
      // Default to `false` / empty when the key is absent so existing
      // `sidebar.json` files written before these fields became
      // non-optional still decode cleanly.
      self.collapsed = try container.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
      self.buckets =
        try container.decodeIfPresent(
          OrderedDictionary<BucketID, Bucket>.self,
          forKey: .buckets
        ) ?? [:]
      self.title = try container.decodeIfPresent(String.self, forKey: .title)
      self.color = try container.decodeIfPresent(RepositoryColor.self, forKey: .color)
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: SectionCodingKeys.self)
      // Always encode `collapsed` and `buckets` so the wire format
      // stays exhaustive and the migrator can rely on a stable shape.
      try container.encode(collapsed, forKey: .collapsed)
      try container.encode(buckets, forKey: .buckets)
      // Customization fields are only emitted when set so the file
      // stays clean for repos the user never touched.
      try container.encodeIfPresent(title, forKey: .title)
      try container.encodeIfPresent(color, forKey: .color)
    }
  }

  nonisolated struct Bucket: Equatable, Sendable, Codable {
    var items: OrderedDictionary<Worktree.ID, Item> = [:]
    /// Path-component prefixes whose grouped children are currently
    /// collapsed in the sidebar. Survives the View menu's grouping
    /// toggle so a user can toggle grouping off and back on without
    /// losing their collapse layout.
    var collapsedBranchPrefixes: Set<String> = []

    private enum CodingKeys: String, CodingKey {
      case items
      case collapsedBranchPrefixes
    }

    init(
      items: OrderedDictionary<Worktree.ID, Item> = [:],
      collapsedBranchPrefixes: Set<String> = []
    ) {
      self.items = items
      self.collapsedBranchPrefixes = collapsedBranchPrefixes
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.items =
        try container.decodeIfPresent(
          OrderedDictionary<Worktree.ID, Item>.self,
          forKey: .items
        ) ?? [:]
      // Use `try?` so a malformed value (number, string, object) drops just
      // this one field rather than killing the whole sidebar layout decode.
      self.collapsedBranchPrefixes =
        (try? container.decodeIfPresent(Set<String>.self, forKey: .collapsedBranchPrefixes)) ?? []
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(items, forKey: .items)
      // Omit when empty so `sidebar.json` stays clean for users who never collapsed anything.
      if !collapsedBranchPrefixes.isEmpty {
        try container.encode(collapsedBranchPrefixes, forKey: .collapsedBranchPrefixes)
      }
    }
  }

  nonisolated struct Item: Equatable, Sendable, Codable {
    /// Timestamp the worktree was archived at. Non-`nil` only inside
    /// the `.archived` bucket — the mutating API clears it when an
    /// item leaves `.archived`, so the field is a reliable "is this
    /// currently archived?" signal without a bucket check.
    var archivedAt: Date?
    /// Optional user-supplied display title that overrides the
    /// worktree's branch / folder name in the sidebar row. `nil` (or
    /// whitespace-only after trim) means "use the default name".
    var title: String?
    /// Optional user-supplied tint applied to the sidebar row title.
    /// `nil` means "default styling".
    var color: RepositoryColor?

    private enum CodingKeys: String, CodingKey {
      case archivedAt
      case title
      case color
    }

    init(archivedAt: Date? = nil, title: String? = nil, color: RepositoryColor? = nil) {
      self.archivedAt = archivedAt
      self.title = title
      self.color = color
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
      self.title = try container.decodeIfPresent(String.self, forKey: .title)
      // Use `try?` so a malformed hex color (introduced by a downgrade
      // that doesn't understand `.custom`, hand-edit, etc.) drops just
      // this field rather than killing the row's entire entry.
      self.color = (try? container.decodeIfPresent(RepositoryColor.self, forKey: .color)) ?? nil
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
      // Customization fields are only emitted when set so the file
      // stays clean for worktrees the user never touched.
      try container.encodeIfPresent(title, forKey: .title)
      try container.encodeIfPresent(color, forKey: .color)
    }
  }

  /// Flat reference to an archived worktree: the owning repo, the
  /// worktree ID, and the timestamp it was archived at. Used by the
  /// `archivedWorktrees` accessor so callers can consume the fan-out
  /// via property access rather than tuple destructuring.
  nonisolated struct ArchivedWorktreeRef: Equatable, Sendable {
    let repositoryID: Repository.ID
    let worktreeID: Worktree.ID
    let archivedAt: Date
  }
}

// MARK: - Read-side accessors.

nonisolated extension SidebarState {
  /// Flat view over every archived worktree across every section.
  /// The only reader that genuinely needs a fan-out iterator is the
  /// auto-delete sweep (and the archived-worktrees detail view),
  /// which can't know the owning repo up front. Every other reader
  /// should reach through `sections[repoID]?.buckets[bucket]?.items[wid]?`
  /// directly.
  ///
  /// Iteration follows `sections` insertion order, then item
  /// insertion order inside `.archived`.
  var archivedWorktrees: [ArchivedWorktreeRef] {
    var result: [ArchivedWorktreeRef] = []
    for (repoID, section) in sections {
      guard let archived = section.buckets[.archived] else {
        continue
      }
      for (worktreeID, item) in archived.items {
        if let archivedAt = item.archivedAt {
          result.append(
            ArchivedWorktreeRef(
              repositoryID: repoID,
              worktreeID: worktreeID,
              archivedAt: archivedAt
            )
          )
        }
      }
    }
    return result
  }

  /// Bucket that currently contains `worktreeID` in `repositoryID`,
  /// or `nil` when the worktree isn't curated in any bucket. Used
  /// by reducer actions that need to pass `from:` to `move` or
  /// `archive` but only know the repo + worktree from their action
  /// payload. O(buckets) = O(3); cheaper than any scan.
  func currentBucket(of worktreeID: Worktree.ID, in repositoryID: Repository.ID) -> BucketID? {
    guard let section = sections[repositoryID] else {
      return nil
    }
    for (bucketID, bucket) in section.buckets where bucket.items[worktreeID] != nil {
      return bucketID
    }
    return nil
  }

  /// Whether `worktreeID` sits in the archived bucket. Not a proxy for "on
  /// screen": collapsed or failed repositories render no rows, and an archived
  /// worktree re-enters the sidebar while its delete script runs.
  func isArchived(_ worktreeID: Worktree.ID, in repositoryID: Repository.ID) -> Bool {
    sections[repositoryID]?.buckets[.archived]?.items[worktreeID] != nil
  }

  /// Flattens the bucket layout into the four states the CLI reports. Archiving
  /// wins over `isMain` (the default workspace can be archived) and an unbucketed
  /// worktree reads as `unpinned` (the bucket the sidebar renders it into).
  func status(
    of worktreeID: Worktree.ID,
    in repositoryID: Repository.ID,
    isMain: Bool
  ) -> WorktreeStatus {
    guard !isArchived(worktreeID, in: repositoryID) else { return .archived }
    guard !isMain else { return .main }
    return currentBucket(of: worktreeID, in: repositoryID) == .pinned ? .pinned : .unpinned
  }
}

// MARK: - Mutations.

nonisolated extension SidebarState {
  /// Move `worktreeID` from `from` to `to` inside `repositoryID`,
  /// preserving the existing `Item` payload. Clears `archivedAt`
  /// when `to != .archived`. `position` is the insertion index
  /// inside `to` (default `0` = top of bucket; `nil` = append).
  /// No-op when the item isn't in `from`.
  mutating func move(
    worktree worktreeID: Worktree.ID,
    in repositoryID: Repository.ID,
    from: BucketID,
    to destination: BucketID,
    position: Int? = 0
  ) {
    guard var section = sections[repositoryID] else {
      return
    }
    guard var item = section.buckets[from]?.items.removeValue(forKey: worktreeID) else {
      return
    }
    if destination != .archived {
      item.archivedAt = nil
    }
    var bucket = section.buckets[destination] ?? .init()
    insert(item: item, for: worktreeID, into: &bucket, position: position)
    section.buckets[destination] = bucket
    sections[repositoryID] = section
  }

  /// Insert a fresh `Item` into the given bucket at `position`.
  /// Used by the reducer's seed pass when a newly-discovered live
  /// worktree first appears, so every rendered worktree has a
  /// bucketed entry by the time the view reads it.
  mutating func insert(
    worktree worktreeID: Worktree.ID,
    in repositoryID: Repository.ID,
    bucket bucketID: BucketID,
    item: Item = .init(),
    position: Int? = nil
  ) {
    var section = sections[repositoryID] ?? .init()
    var bucket = section.buckets[bucketID] ?? .init()
    insert(item: item, for: worktreeID, into: &bucket, position: position)
    section.buckets[bucketID] = bucket
    sections[repositoryID] = section
  }

  /// Merge a user-supplied title / color into whatever bucket already holds the row, falling back
  /// to `.unpinned` when the row hasn't been seeded yet. Pre-existing non-nil fields on the
  /// bucketed Item win, so a re-seed never clobbers a manual customization. Used by the
  /// post-create and discovered-worktree seed sites so a persisted `.pinned` Item never gets
  /// manufactured into a phantom double-bucket row.
  mutating func mergeCustomization(
    title: String?,
    color: RepositoryColor?,
    worktree worktreeID: Worktree.ID,
    in repositoryID: Repository.ID
  ) {
    let destinationBucket = currentBucket(of: worktreeID, in: repositoryID) ?? .unpinned
    var section = sections[repositoryID] ?? .init()
    var bucket = section.buckets[destinationBucket] ?? .init()
    var item = bucket.items[worktreeID] ?? .init()
    if item.title == nil { item.title = title }
    if item.color == nil { item.color = color }
    bucket.items[worktreeID] = item
    section.buckets[destinationBucket] = bucket
    sections[repositoryID] = section
  }

  /// Pin `worktreeID`: collapse any pre-existing bucket placement into a single
  /// `.pinned` entry at the top, carrying the Item forward so user-set
  /// `title` / `color` survive, and clearing `archivedAt`. See `removeAnywhere`
  /// for the double-bucket recovery rules.
  mutating func pin(worktree worktreeID: Worktree.ID, in repositoryID: Repository.ID) {
    var carried =
      removeAnywhere(
        worktree: worktreeID,
        in: repositoryID,
        preferring: [.unpinned, .pinned, .archived]
      ) ?? .init()
    carried.archivedAt = nil
    insert(worktree: worktreeID, in: repositoryID, bucket: .pinned, item: carried, position: 0)
  }

  /// Unpin `worktreeID`: the mirror of `pin`, collapsing into a single
  /// `.unpinned` entry at the top. Prefers `.pinned` so a corrupted
  /// double-bucket pre-state surfaces the live pinned row's payload.
  mutating func unpin(worktree worktreeID: Worktree.ID, in repositoryID: Repository.ID) {
    var carried =
      removeAnywhere(
        worktree: worktreeID,
        in: repositoryID,
        preferring: [.pinned, .unpinned, .archived]
      ) ?? .init()
    carried.archivedAt = nil
    insert(worktree: worktreeID, in: repositoryID, bucket: .unpinned, item: carried, position: 0)
  }

  /// Overwrite a row's user-supplied title / color, falling back to `.unpinned` when the row
  /// hasn't been seeded yet. Unlike `mergeCustomization`, the incoming values always win, since
  /// this represents an explicit user save intent that must not be silently absorbed.
  mutating func setCustomization(
    title: String?,
    color: RepositoryColor?,
    worktree worktreeID: Worktree.ID,
    in repositoryID: Repository.ID
  ) {
    let destinationBucket = currentBucket(of: worktreeID, in: repositoryID) ?? .unpinned
    var section = sections[repositoryID] ?? .init()
    var bucket = section.buckets[destinationBucket] ?? .init()
    var item = bucket.items[worktreeID] ?? .init()
    item.title = title
    item.color = color
    bucket.items[worktreeID] = item
    section.buckets[destinationBucket] = bucket
    sections[repositoryID] = section
  }

  /// Archive `worktreeID`: drop from `from`, insert into `.archived`
  /// at the tail with the given timestamp. Materialises the section
  /// and the archived bucket when missing so a late-arriving
  /// archive action lands even if the pruner's seed pass hasn't
  /// run yet for this repo.
  mutating func archive(
    worktree worktreeID: Worktree.ID,
    in repositoryID: Repository.ID,
    from: BucketID,
    at timestamp: Date
  ) {
    var section = sections[repositoryID] ?? .init()
    // Carry the source-bucket Item forward so user-set title / color survive
    // archive; fall back to a fresh Item when the source bucket didn't hold it.
    var carried = section.buckets[from]?.items.removeValue(forKey: worktreeID) ?? .init()
    carried.archivedAt = timestamp
    var archived = section.buckets[.archived] ?? .init()
    archived.items[worktreeID] = carried
    section.buckets[.archived] = archived
    sections[repositoryID] = section
  }

  /// Unarchive `worktreeID`: drop from `.archived` and reinsert at
  /// the top of `.unpinned`. Clears `archivedAt`. No-op when the
  /// worktree isn't currently archived in this section.
  mutating func unarchive(worktree worktreeID: Worktree.ID, in repositoryID: Repository.ID) {
    move(worktree: worktreeID, in: repositoryID, from: .archived, to: .unpinned, position: 0)
  }

  /// Remove `worktreeID` from `bucketID` of `repositoryID`.
  /// No-op when the section or bucket or worktree is absent. Used
  /// by callers that know the source bucket.
  mutating func remove(
    worktree worktreeID: Worktree.ID,
    in repositoryID: Repository.ID,
    from bucketID: BucketID
  ) {
    sections[repositoryID]?.buckets[bucketID]?.items.removeValue(forKey: worktreeID)
  }

  /// Remove `worktreeID` from every bucket of `repositoryID`. Used
  /// by the delete flow (the worktree is going away entirely, so
  /// we don't need to know which bucket currently owns it) and by
  /// pin / unpin (which collapse any pre-existing multi-bucket state
  /// before reinserting). Returns the first found Item in
  /// `preferring` order so callers that reinsert (pin / unpin) can
  /// carry user-set `title` / `color` forward; pass the logical
  /// source bucket first (e.g. `.pinned` for unpin) so a corrupted
  /// double-bucket pre-state preserves the live row's payload rather
  /// than a stale sibling's. Default order matches the typical
  /// "where would a curated row live" search. O(1): exactly three
  /// bucket subscripts, no scan.
  @discardableResult
  mutating func removeAnywhere(
    worktree worktreeID: Worktree.ID,
    in repositoryID: Repository.ID,
    preferring: [BucketID] = [.unpinned, .pinned, .archived]
  ) -> Item? {
    guard sections[repositoryID] != nil else {
      return nil
    }
    // Remove from every bucket (the "removeAnywhere" contract); the
    // `preferring` order only determines which carried Item we
    // return. Buckets outside `preferring` are still purged but
    // their payload is discarded.
    var removed: [BucketID: Item] = [:]
    for bucketID in [BucketID.pinned, .unpinned, .archived] {
      if let item = sections[repositoryID]?.buckets[bucketID]?.items.removeValue(forKey: worktreeID) {
        removed[bucketID] = item
      }
    }
    for bucketID in preferring {
      if let item = removed[bucketID] { return item }
    }
    return nil
  }

  /// Reorder `bucketID`'s items in `repositoryID` to exactly
  /// `reorderedIDs`, preserving item payloads. Items in
  /// `reorderedIDs` that don't currently live in this bucket are
  /// ignored; items outside `reorderedIDs` keep their current
  /// relative position after the reordered run. Other buckets
  /// untouched.
  mutating func reorder(
    bucket bucketID: BucketID,
    in repositoryID: Repository.ID,
    to reorderedIDs: [Worktree.ID]
  ) {
    guard var section = sections[repositoryID], var bucket = section.buckets[bucketID] else {
      return
    }
    let reorderedSet = Set(reorderedIDs)
    var rebuilt: OrderedDictionary<Worktree.ID, Item> = [:]
    var reorderedInserted = false
    for (worktreeID, item) in bucket.items {
      if reorderedSet.contains(worktreeID) {
        if !reorderedInserted {
          for id in reorderedIDs {
            if let existing = bucket.items[id] {
              rebuilt[id] = existing
            }
          }
          reorderedInserted = true
        }
        continue
      }
      rebuilt[worktreeID] = item
    }
    if !reorderedInserted {
      for id in reorderedIDs {
        if let existing = bucket.items[id] {
          rebuilt[id] = existing
        }
      }
    }
    bucket.items = rebuilt
    section.buckets[bucketID] = bucket
    sections[repositoryID] = section
  }

  /// Shared insertion helper — clamps `position` to the current
  /// item count and falls back to append when `position` is `nil`
  /// or out of range.
  private func insert(
    item: Item,
    for worktreeID: Worktree.ID,
    into bucket: inout Bucket,
    position: Int?
  ) {
    if let position, position < bucket.items.count {
      bucket.items.updateValue(item, forKey: worktreeID, insertingAt: position)
    } else {
      bucket.items[worktreeID] = item
    }
  }
}

// MARK: - Repository groups.

nonisolated extension SidebarState {
  /// The group `repositoryID` belongs to, or `nil` when ungrouped.
  func groupID(containing repositoryID: Repository.ID) -> RepositoryGroupID? {
    groups.values.first { $0.repositoryIDs.contains(repositoryID) }?.id
  }

  /// Register a new, empty, expanded group. No-op when `id` already exists.
  mutating func addGroup(id: RepositoryGroupID, name: String) {
    guard groups[id] == nil else { return }
    groups[id] = RepositoryGroup(id: id, name: name)
  }

  mutating func renameGroup(_ id: RepositoryGroupID, to name: String) {
    groups[id]?.name = name
  }

  /// Dissolve `id`. Members keep their `sections` slot and simply render
  /// ungrouped again; no repository is removed.
  mutating func removeGroup(_ id: RepositoryGroupID) {
    groups.removeValue(forKey: id)
  }

  /// Move `repositoryID` into `groupID` (or out of every group when `nil`).
  /// Also re-slots its `sections` key so the group's members stay contiguous:
  /// joining lands after the group's last member, leaving lands after the
  /// group's block. Membership is written even when the repo has no
  /// `sections` entry yet; the next reconcile seeds one.
  mutating func assignGroup(of repositoryID: Repository.ID, to groupID: RepositoryGroupID?) {
    let targetExists = groupID.map { groups[$0] != nil } ?? true
    guard targetExists else { return }
    // Every group that lists the repo, so a duplicated membership (hand-edited
    // or older blob) is repaired rather than half-removed.
    let previousGroupIDs = groups.values.filter { $0.repositoryIDs.contains(repositoryID) }.map(\.id)
    let alreadyThere = previousGroupIDs == groupID.map { [$0] } ?? []
    guard !alreadyThere else { return }
    for previousGroupID in previousGroupIDs {
      groups[previousGroupID]?.repositoryIDs.removeAll { $0 == repositoryID }
    }
    if let groupID {
      groups[groupID]?.repositoryIDs.append(repositoryID)
    }
    // Anchor after the last member of the block the repo is joining or
    // leaving; when there is none the key keeps its current slot.
    let anchorGroupID = groupID ?? previousGroupIDs.first
    guard let anchorGroupID,
      let anchorMembers = groups[anchorGroupID]?.repositoryIDs.filter({ $0 != repositoryID }),
      let anchor = sections.keys.last(where: { anchorMembers.contains($0) }),
      let section = sections.removeValue(forKey: repositoryID),
      let anchorIndex = sections.index(forKey: anchor)
    else { return }
    sections.updateValue(section, forKey: repositoryID, insertingAt: anchorIndex + 1)
  }

  /// `ids` split into each group's members (in `ids` order) and the
  /// ungrouped remainder. Ids in `ungroupable` count as ungrouped even when a
  /// group lists them; the sidebar can't draw those inside a card.
  func memberBuckets(
    of ids: [Repository.ID], excluding ungroupable: Set<Repository.ID>
  ) -> (byGroup: [RepositoryGroupID: [Repository.ID]], ungrouped: [Repository.ID]) {
    let groupIDByRepositoryID: [Repository.ID: RepositoryGroupID] = Dictionary(
      groups.values.flatMap { group in group.repositoryIDs.map { ($0, group.id) } },
      uniquingKeysWith: { first, _ in first }
    )
    let grouped = ids.compactMap { id -> (groupID: RepositoryGroupID, repositoryID: Repository.ID)? in
      guard !ungroupable.contains(id), let groupID = groupIDByRepositoryID[id] else { return nil }
      return (groupID, id)
    }
    let byGroup = Dictionary(grouping: grouped, by: \.groupID).mapValues { $0.map(\.repositoryID) }
    let groupedSet = Set(grouped.map(\.repositoryID))
    return (byGroup, ids.filter { !groupedSet.contains($0) })
  }

  /// Sidebar top-down order for `persisted` (the `sections` key order
  /// filtered to live repos): every group's members in group order, each
  /// group's members in persisted order, then the ungrouped repos in
  /// persisted order. Groups always sit above ungrouped repositories.
  func groupedOrder(of persisted: [Repository.ID], excluding ungroupable: Set<Repository.ID>) -> [Repository.ID] {
    let buckets = memberBuckets(of: persisted, excluding: ungroupable)
    return groups.keys.flatMap { buckets.byGroup[$0] ?? [] } + buckets.ungrouped
  }

  /// Rewrite the `sections` key order to the rendered (grouped-first) order
  /// so every consumer of the key order agrees with the sidebar. `knownIDs`
  /// is the live repository order: keys it lists come first in their current
  /// order, live ids without a section yet follow, unknown keys keep the tail.
  mutating func normalizeSectionOrder(knownIDs: [Repository.ID], excluding ungroupable: Set<Repository.ID>) {
    let knownSet = Set(knownIDs)
    let keyed = Set(sections.keys)
    let persisted = sections.keys.filter(knownSet.contains) + knownIDs.filter { !keyed.contains($0) }
    reorderSections(to: groupedOrder(of: persisted, excluding: ungroupable))
  }

  /// Rewrite every group member id through `transform`, for repository id
  /// re-keys (remote connection edits, persistence migrations). Ids that
  /// collide after the rewrite keep their first occurrence, in group order,
  /// matching how the migrator dedupes colliding section keys.
  mutating func rekeyGroupMembers(_ transform: (Repository.ID) -> Repository.ID) {
    var claimed: Set<Repository.ID> = []
    groups = groups.mapValues { group in
      var rekeyed = group
      rekeyed.repositoryIDs = group.repositoryIDs.map(transform).filter { claimed.insert($0).inserted }
      return rekeyed
    }
  }

  /// Rewrite the `sections` key order to `ids`. Sections for repos still
  /// loading / not yet seen are reliably absent from `ids`; they keep their
  /// original relative order at the tail so a live-row reorder doesn't
  /// silently reshuffle curation on them.
  mutating func reorderSections(to ids: [Repository.ID]) {
    var reordered: OrderedDictionary<Repository.ID, Section> = [:]
    for id in ids {
      reordered[id] = sections[id] ?? .init()
    }
    for (id, section) in sections where reordered[id] == nil {
      reordered[id] = section
    }
    sections = reordered
  }

  /// `groups` minus members whose repository is gone. Groups themselves
  /// survive empty so a user's named bucket isn't lost when its last repo is
  /// removed.
  static func pruningGroupMembers(
    of groups: OrderedDictionary<RepositoryGroupID, RepositoryGroup>,
    keeping availableRepositoryIDs: Set<Repository.ID>
  ) -> OrderedDictionary<RepositoryGroupID, RepositoryGroup> {
    groups.mapValues { group in
      var pruned = group
      pruned.repositoryIDs.removeAll { !availableRepositoryIDs.contains($0) }
      return pruned
    }
  }
}
