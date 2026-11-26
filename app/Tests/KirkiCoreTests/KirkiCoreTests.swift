import CryptoKit
import XCTest
@testable import KirkiCore

final class ImageTests: XCTestCase {
    struct Sample: Decodable { var size: Int64; var sha256: String; var xzSize: Int64; var xzSha256: String }

    var sample: Sample!
    var xz: URL!
    var tmp: URL!

    override func setUpWithError() throws {
        xz = try XCTUnwrap(Bundle.module.url(forResource: "sample.img", withExtension: "xz", subdirectory: "Fixtures"))
        let info = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "json", subdirectory: "Fixtures"))
        sample = try JSONDecoder().decode(Sample.self, from: Data(contentsOf: info))
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kirki-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// macOS's own LZMA decoder reads what `xz -T` makes (several blocks, CRC64), and the disk it
    /// writes is sparse: the zero blocks take no space.
    func testUnpackMultiBlockXZIntoSparseFile() throws {
        let out = tmp.appendingPathComponent("disk.img")
        var lastProgress: Int64 = 0
        let result = try ImageUnpacker.unpack(parts: [xz], to: out, expectedSize: sample.size,
                                              expectedSHA256: sample.sha256) { lastProgress = $0 }
        XCTAssertEqual(result.size, sample.size)
        XCTAssertEqual(result.sha256, sample.sha256)
        XCTAssertEqual(lastProgress, sample.xzSize)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), sample.sha256)
        var st = stat()
        XCTAssertEqual(stat(out.path, &st), 0)
        // 2 MiB of the 4 MiB are zeros, written as holes
        XCTAssertLessThan(Int64(st.st_blocks) * 512, sample.size - (1 << 20), "the zero blocks should be holes")
    }

    /// The download can come in parts: they're one xz stream, split anywhere.
    func testUnpackSplitParts() throws {
        let whole = try Data(contentsOf: xz)
        let cut = 300_001
        let a = tmp.appendingPathComponent("part00"), b = tmp.appendingPathComponent("part01")
        try whole[..<cut].write(to: a)
        try whole[cut...].write(to: b)
        let result = try ImageUnpacker.unpack(parts: [a, b], to: tmp.appendingPathComponent("disk.img"),
                                              expectedSize: sample.size, expectedSHA256: sample.sha256)
        XCTAssertEqual(result.sha256, sample.sha256)
    }

    func testUnpackDetectsWrongChecksum() throws {
        XCTAssertThrowsError(try ImageUnpacker.unpack(parts: [xz], to: tmp.appendingPathComponent("disk.img"),
                                                      expectedSize: sample.size, expectedSHA256: String(repeating: "0", count: 64))) {
            XCTAssertEqual($0 as? ImageError, .checksum)
        }
    }

    func testUnpackDetectsDamagedData() throws {
        var data = try Data(contentsOf: xz)
        data[data.count / 2] ^= 0xFF
        let bad = tmp.appendingPathComponent("bad.xz")
        try data.write(to: bad)
        XCTAssertThrowsError(try ImageUnpacker.unpack(parts: [bad], to: tmp.appendingPathComponent("disk.img"),
                                                      expectedSize: sample.size, expectedSHA256: sample.sha256))
    }

    func testDiskGrowsButNeverShrinks() throws {
        let disk = tmp.appendingPathComponent("disk.img")
        FileManager.default.createFile(atPath: disk.path, contents: Data(count: 4096))
        try DiskFile.grow(disk, toGB: 2)
        XCTAssertEqual(DiskFile.size(disk), 2 << 30)
        try DiskFile.grow(disk, toGB: 1)
        XCTAssertEqual(DiskFile.size(disk), 2 << 30)
    }

    /// A part downloads, checked against its SHA-256; a leftover .partial is carried on from.
    func testPartDownloadResumesAndVerifies() async throws {
        let part = ImageManifest.Part(url: xz, size: sample.xzSize, sha256: sample.xzSha256)
        let dest = tmp.appendingPathComponent("sample.img.xz")
        try Data(try Data(contentsOf: xz).prefix(1000)).write(to: dest.appendingPathExtension("partial"))
        let download = PartDownload(part: part, destination: dest)
        try await download.run()
        XCTAssertEqual(try Data(contentsOf: dest), try Data(contentsOf: xz))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathExtension("partial").path))
        // already there: nothing to do
        try await PartDownload(part: part, destination: dest).run()
    }

    func testPartDownloadRejectsWrongChecksum() async throws {
        let part = ImageManifest.Part(url: xz, size: sample.xzSize, sha256: String(repeating: "a", count: 64))
        let dest = tmp.appendingPathComponent("sample.img.xz")
        do {
            try await PartDownload(part: part, destination: dest).run()
            XCTFail("a damaged download must not be accepted")
        } catch {
            XCTAssertEqual(error as? DownloadError, .checksum("sample.img.xz"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathExtension("partial").path))
    }

    /// The whole installer, from a kirki-vm.json on disk: download, check, unpack, size the disk.
    func testInstallFromLocalManifest() async throws {
        setenv("KIRKI_HOME", tmp.appendingPathComponent("home").path, 1)
        defer { unsetenv("KIRKI_HOME") }
        let manifest = ImageManifest(format: 1, version: "26.11.26", kirki: "abc", image: .init(
            compression: "xz", size: sample.xzSize, sha256: sample.xzSha256, uncompressedSize: sample.size,
            uncompressedSha256: sample.sha256, parts: [.init(url: xz, size: sample.xzSize, sha256: sample.xzSha256)]))
        let manifestURL = tmp.appendingPathComponent("kirki-vm.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        var stages: [String] = []
        let installed = try await ImageInstaller(manifestURL: manifestURL, diskGB: 24).install { stage in
            if stages.last != stage.name { stages.append(stage.name) }
        }
        XCTAssertEqual(installed.version, "26.11.26")
        XCTAssertEqual(stages, ["checking", "downloading", "unpacking", "finishing"])
        XCTAssertEqual(DiskFile.size(Paths.disk), 24 << 30)
        XCTAssertEqual(InstalledImage.load()?.version, "26.11.26")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.downloads.path), "downloads are cleaned up")
    }
}

final class ProtocolTests: XCTestCase {
    func testGuestMessages() {
        XCTAssertEqual(GuestMessage(line: "ready 1"), .ready(version: "1"))
        XCTAssertEqual(GuestMessage(line: "power reboot"), .power("reboot"))
        XCTAssertEqual(GuestMessage(line: "pong"), .pong)
        XCTAssertEqual(GuestMessage(line: "status kernel=7.3.6-1-ARCH sound=yes failed=none"),
                       .status(["kernel": "7.3.6-1-ARCH", "sound": "yes", "failed": "none"]))
        XCTAssertEqual(GuestMessage(line: "what"), .unknown("what"))
        XCTAssertEqual(PowerIntent.fromPowerMessage("reboot"), .reboot)
        XCTAssertEqual(PowerIntent.fromPowerMessage("poweroff"), .poweroff)
        XCTAssertEqual(PowerIntent.fromConsole("[ 123.4] reboot: Restarting system"), .reboot)
        XCTAssertEqual(PowerIntent.fromConsole("[ 123.4] reboot: Power down"), .poweroff)
        XCTAssertNil(PowerIntent.fromConsole("systemd[1]: Started something"))
    }

    func testHostMessages() {
        let info = HostMessage.hostinfo(["MAC_MODEL": "MacBook Air", "TIMEZONE": "America/Argentina/Buenos_Aires", "X": "a=b;c'd"])
        XCTAssertEqual(info.line, "hostinfo MAC_MODEL=MacBook%20Air TIMEZONE=America/Argentina/Buenos_Aires X=a%3Db%3Bc%27d")
        XCTAssertEqual(HostMessage.time(Date(timeIntervalSince1970: 1764140000.25)).line, "time 1764140000.250")
        XCTAssertEqual(HostMessage.shutdown.line, "shutdown")
    }

    func testLineSplitter() {
        let s = LineSplitter()
        XCTAssertEqual(s.append(Data("rea".utf8)), [])
        XCTAssertEqual(s.append(Data("dy 1\r\npower re".utf8)), ["ready 1"])
        XCTAssertEqual(s.append(Data("boot\n\n".utf8)), ["power reboot", ""])
    }
}

final class SettingsTests: XCTestCase {
    let mac8 = HostInfo(physicalMemory: 8 << 30, processorCount: 8, model: "Mac14,2", chip: "Apple M2", freeDiskBytes: 200 << 30)
    let mac16 = HostInfo(physicalMemory: 16 << 30, processorCount: 10, model: "Mac15,3", chip: "Apple M3", freeDiskBytes: 40 << 30)
    let mac64 = HostInfo(physicalMemory: 64 << 30, processorCount: 12, model: "Mac14,6", chip: "Apple M2 Max", freeDiskBytes: 900 << 30)

    func testDefaultsFitTheMac() {
        XCTAssertEqual(Settings.defaults(for: mac8).memoryGB, 5)
        XCTAssertEqual(Settings.defaults(for: mac16).memoryGB, 10)
        XCTAssertEqual(Settings.defaults(for: mac64).memoryGB, 32)
        XCTAssertEqual(Settings.defaults(for: mac8).processors, 8)
        XCTAssertEqual(Settings.defaults(for: mac8).diskGB, 64)
        XCTAssertEqual(Settings.defaults(for: mac16).diskGB, Settings.minimumDiskGB, "short of space: a smaller disk")
    }

    func testOldSettingsGetNewDefaults() throws {
        let old = #"{"memoryGB": 6, "retina": false}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        XCTAssertEqual(s.memoryGB, 6)
        XCTAssertFalse(s.retina)
        XCTAssertEqual(s.whenKirkiShutsDown, .logOut)
        XCTAssertEqual(s.macMenuBar, .showAtTop)
    }

    func testClamping() {
        var s = Settings.defaults(for: mac8)
        s.memoryGB = 100
        s.processors = 99
        s.diskGB = 1
        let c = s.clamped(to: mac8)
        XCTAssertEqual(c.memoryGB, 6)
        XCTAssertEqual(c.processors, 8)
        XCTAssertEqual(c.diskGB, Settings.minimumDiskGB)
    }

    func testKeyboardLayouts() {
        XCTAssertEqual(KeyboardLayouts.xkb(forMacLayoutID: "com.apple.keylayout.German")?.layout, "de")
        XCTAssertEqual(KeyboardLayouts.xkb(forMacLayoutID: "com.apple.keylayout.USInternational-PC")?.variant, "intl")
        XCTAssertNil(KeyboardLayouts.xkb(forMacLayoutID: "com.apple.keylayout.Klingon"))
        XCTAssertNil(KeyboardLayouts.xkb(forMacLayoutID: "com.apple.inputmethod.Kotoeri"))
    }

    func testVersions() {
        XCTAssertLessThan(Version("26.11.18")!, Version("26.11.18.1")!)
        XCTAssertLessThan(Version("26.11.18.1")!, Version("26.12.01")!)
        XCTAssertNil(Version("v1"))
    }

    func testManifestValidation() throws {
        let good = """
        {"format": 1, "version": "26.11.26", "image": {"compression": "xz", "size": 10, "sha256": "\(String(repeating: "a", count: 64))",
         "uncompressedSize": 100, "parts": [{"url": "https://example.com/a", "size": 10, "sha256": "\(String(repeating: "b", count: 64))"}]}}
        """
        XCTAssertNoThrow(try ImageManifest.decode(Data(good.utf8)))
        XCTAssertThrowsError(try ImageManifest.decode(Data(good.replacingOccurrences(of: "\"format\": 1", with: "\"format\": 2").utf8)))
        XCTAssertThrowsError(try ImageManifest.decode(Data(good.replacingOccurrences(of: "\"size\": 10,", with: "\"size\": 11,").utf8)))
        XCTAssertThrowsError(try ImageManifest.decode(Data(good.replacingOccurrences(of: "https://", with: "http://").utf8)))
    }
}
