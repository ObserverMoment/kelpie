import Foundation

/// Turns the bytes of a streamed 16-bit little-endian PCM response into whole
/// samples, skipping a leading WAV header if there is one. Bytes arrive in
/// arbitrary pieces, so a half sample at the end of one piece is held back
/// and completed by the next.
nonisolated struct StreamedPCM {
  private static let bytesPerSample = MemoryLayout<Int16>.size
  private static let fullScale = Float(Int16.max) + 1
  /// "RIFF", the file size, "WAVE".
  private static let riffHeaderLength = 12
  /// A four-character chunk id and its 32-bit size.
  private static let chunkHeaderLength = 8

  private var pending = Data()
  private var isPastHeader = false

  /// Samples scaled to -1...1 that `piece` completes, possibly none yet.
  mutating func samples(appending piece: Data) -> [Float] {
    pending.append(piece)
    if !isPastHeader {
      guard let audioStart = Self.audioStart(in: pending) else { return [] }
      pending = pending.subdata(in: audioStart..<pending.endIndex)
      isPastHeader = true
    }
    let wholeSampleBytes = pending.count - pending.count % Self.bytesPerSample
    let whole = pending.prefix(wholeSampleBytes)
    pending = pending.subdata(in: wholeSampleBytes..<pending.endIndex)
    return Self.samples(in: whole)
  }

  private static func samples(in bytes: Data) -> [Float] {
    bytes.withUnsafeBytes { raw in
      stride(from: 0, to: raw.count, by: bytesPerSample).map { offset in
        Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / fullScale
      }
    }
  }

  /// Where audio begins: at the start when the bytes are not a WAV file,
  /// otherwise after the `data` chunk header. `nil` while the bytes so far
  /// could still be a WAV header that has not fully arrived.
  private static func audioStart(in bytes: Data) -> Int? {
    let isRIFFSoFar = bytes.prefix(4).elementsEqual("RIFF".utf8.prefix(bytes.count))
    guard isRIFFSoFar else { return 0 }
    var offset = riffHeaderLength
    while bytes.count >= offset + chunkHeaderLength {
      let id = bytes.subdata(in: offset..<offset + 4)
      let size = Int(
        bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self) }.littleEndian)
      if id.elementsEqual("data".utf8) { return offset + chunkHeaderLength }
      offset += chunkHeaderLength + size + size % 2
    }
    return nil
  }
}
