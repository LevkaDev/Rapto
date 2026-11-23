import Testing
import Foundation
@testable import Rapto

@Suite("Startup disk among mounted volumes")
struct VolumeDetectionTests {
    @Test("The link to the startup disk is not an external volume")
    func startupDiskLinkExcluded() throws {
        let volumes = FileManager.default.temporaryDirectory.appendingPathComponent("rapto-volumes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: volumes.appendingPathComponent("Installer"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: volumes.appendingPathComponent("Macintosh HD").path, withDestinationPath: "/")
        defer { try? FileManager.default.removeItem(at: volumes) }

        #expect(WindowClassifier.externalVolumeNames(in: volumes) == ["Installer"])
    }

    @Test("The real /Volumes never lists the startup disk")
    func realVolumes() {
        let names = WindowClassifier.externalVolumeNames(in: URL(fileURLWithPath: "/Volumes"))
        let startupLinks = ((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []).filter {
            URL(fileURLWithPath: "/Volumes/\($0)").resolvingSymlinksInPath().path == "/"
        }
        #expect(!startupLinks.isEmpty)
        #expect(names.isDisjoint(with: startupLinks))
    }
}
