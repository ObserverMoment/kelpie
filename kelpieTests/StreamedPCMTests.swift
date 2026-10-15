import Foundation
import Testing

@testable import kelpie

struct StreamedPCMTests {
  private static func wav(_ samples: [Int16], extraChunk: Bool = false) -> Data {
    var data = Data("RIFF".utf8)
    data.append(contentsOf: [0, 0, 0, 0])
    data.append(contentsOf: "WAVEfmt ".utf8)
    data.append(contentsOf: [16, 0, 0, 0] + [UInt8](repeating: 0, count: 16))
    if extraChunk {
      data.append(contentsOf: "LIST".utf8)
      data.append(contentsOf: [3, 0, 0, 0, 1, 2, 3, 0])  // odd size, padded
    }
    data.append(contentsOf: "data".utf8)
    data.append(contentsOf: [0, 0, 0, 0])
    data.append(pcm(samples))
    return data
  }

  private static func pcm(_ samples: [Int16]) -> Data {
    Data(samples.flatMap { withUnsafeBytes(of: $0.littleEndian, Array.init) })
  }

  @Test func rawPCMDecodesToScaledSamples() {
    var stream = StreamedPCM()
    #expect(stream.samples(appending: Self.pcm([0, 16384, -32768])) == [0, 0.5, -1])
  }

  @Test func wavHeaderIsSkipped() {
    var stream = StreamedPCM()
    #expect(stream.samples(appending: Self.wav([16384, -16384])) == [0.5, -0.5])
  }

  @Test func wavHeaderWithExtraChunksIsSkipped() {
    var stream = StreamedPCM()
    #expect(stream.samples(appending: Self.wav([16384], extraChunk: true)) == [0.5])
  }

  @Test func headerSplitAcrossPiecesYieldsNothingUntilAudioStarts() {
    var stream = StreamedPCM()
    let wav = Self.wav([16384, 8192])
    #expect(stream.samples(appending: wav.prefix(10)) == [])
    #expect(stream.samples(appending: wav.subdata(in: 10..<30)) == [])
    #expect(stream.samples(appending: wav.subdata(in: 30..<wav.count)) == [0.5, 0.25])
  }

  @Test func halfSampleIsCarriedToTheNextPiece() {
    var stream = StreamedPCM()
    let pcm = Self.pcm([16384, 8192])
    #expect(stream.samples(appending: pcm.prefix(3)) == [0.5])
    #expect(stream.samples(appending: pcm.suffix(1)) == [0.25])
  }

  @Test func aHeaderWithoutADataChunkYieldsNothing() {
    var stream = StreamedPCM()
    var header = Data("RIFF".utf8)
    header.append(contentsOf: [0, 0, 0, 0])
    header.append(contentsOf: "WAVEfmt ".utf8)
    header.append(contentsOf: [16, 0, 0, 0] + [UInt8](repeating: 0, count: 16))
    #expect(stream.samples(appending: header) == [])
    #expect(stream.samples(appending: Self.pcm([16384, 16384])) == [])
  }

  @Test func aChunkWithAnOversizedLengthYieldsNothingAndDoesNotTrap() {
    var stream = StreamedPCM()
    var header = Data("RIFF".utf8)
    header.append(contentsOf: [0, 0, 0, 0])
    header.append(contentsOf: "WAVELIST".utf8)
    header.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
    #expect(stream.samples(appending: header) == [])
    #expect(stream.samples(appending: Self.pcm([16384, 16384, 16384])) == [])
  }
}
