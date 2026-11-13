import Foundation
import Testing
@testable import FilsynkCore

@Suite struct VolumesTests {
    private func volume(_ uuid: String?, _ name: String, _ path: String,
                        format: VolumeFormat = .exfat, isSystem: Bool = false) -> VolumeInfo {
        VolumeInfo(uuid: uuid, name: name, mountPath: path, format: format, isSystem: isSystem)
    }

    @Test func formatFromTypeName() {
        #expect(VolumeFormat(fileSystemTypeName: "apfs") == .apfs)
        #expect(VolumeFormat(fileSystemTypeName: "hfs") == .hfs)
        #expect(VolumeFormat(fileSystemTypeName: "exfat") == .exfat)
        #expect(VolumeFormat(fileSystemTypeName: "msdos") == .other("msdos"))
        #expect(VolumeFormat.apfs.isSupported); #expect(VolumeFormat.hfs.isSupported)
        #expect(VolumeFormat.exfat.isSupported); #expect(!VolumeFormat.exfat.keepsPermissions)
        #expect(!VolumeFormat.other("ntfs").isSupported); #expect(!VolumeFormat.other("ntfs").keepsPermissions)
        #expect(VolumeFormat.hfs.keepsPermissions); #expect(VolumeFormat.apfs.keepsPermissions)
    }

    @Test func findsVolumeByUUID() throws {
        let hdd = volume("AAAA-1111", "HDD", "/Volumes/HDD")
        let other = volume("BBBB-2222", "Annan", "/Volumes/Annan")
        let found = try VolumeLookup.find(uuid: "BBBB-2222", in: [hdd, other]).get()
        #expect(found == other)
        // Ids är hex och jämförs utan hänsyn till skiftläge.
        #expect(try VolumeLookup.find(uuid: "aaaa-1111", in: [hdd, other]).get() == hdd)
    }

    @Test func sameNameOtherUUIDIsNotFound() {
        let hdd = volume("AAAA-1111", "HDD", "/Volumes/HDD")
        let result = VolumeLookup.find(uuid: "CCCC-3333", in: [hdd])
        #expect(result == .failure(.notMounted))
        let noId = volume(nil, "HDD", "/Volumes/HDD")
        #expect(VolumeLookup.find(uuid: "AAAA-1111", in: [noId]) == .failure(.notMounted))
    }

    @Test func emptyIdNeverMatches() {
        let blank = volume("", "Utan id", "/Volumes/Utan")
        let none = volume(nil, "Okänd", "/Volumes/Okand")
        for id in ["", "  ", "\n"] {
            #expect(VolumeLookup.find(uuid: id, in: [blank, none]) == .failure(.notMounted), "\(id.debugDescription)")
        }
        #expect(VolumeLookup.find(uuid: "AAAA-1111", in: [blank, none]) == .failure(.notMounted))
    }

    @Test func duplicateUUIDIsAProblem() {
        let a = volume("AAAA-1111", "HDD", "/Volumes/HDD")
        let b = volume("aaaa-1111", "HDD 1", "/Volumes/HDD 1")
        #expect(VolumeLookup.find(uuid: "AAAA-1111", in: [a, b]) == .failure(.duplicate))
    }

    @Test func volumeContainingPathUsesLongestMountPoint() {
        let root = volume("R", "Macintosh HD", "/", format: .apfs, isSystem: true)
        let hdd = volume("H", "HDD", "/Volumes/HDD")
        let all = [root, hdd]
        #expect(VolumeLookup.volume(containing: "/Volumes/HDD/a/b", in: all) == hdd)
        #expect(VolumeLookup.volume(containing: "/Volumes/HDD", in: all) == hdd)
        #expect(VolumeLookup.volume(containing: "/Volumes/HDD2/a", in: all) == root)
        #expect(VolumeLookup.volume(containing: "/Users/x", in: all) == root)
        #expect(VolumeLookup.volume(containing: "/Volumes/HDD2/a", in: [hdd]) == nil)
    }

    @Test func relativePathOnVolume() {
        let hdd = volume("H", "HDD", "/Volumes/HDD")
        let root = volume("R", "Macintosh HD", "/", format: .apfs, isSystem: true)
        #expect(VolumeLookup.relativePath(of: "/Volumes/HDD/Filsynk/A", on: hdd) == "Filsynk/A")
        #expect(VolumeLookup.relativePath(of: "/Volumes/HDD", on: hdd) == "")
        #expect(VolumeLookup.relativePath(of: "/Volumes/HDD/", on: hdd) == "")
        #expect(VolumeLookup.relativePath(of: "/Volumes/HDD2/a", on: hdd) == nil)
        #expect(VolumeLookup.relativePath(of: "/Users/x", on: hdd) == nil)
        #expect(VolumeLookup.relativePath(of: "/Users/x", on: root) == "Users/x")
        #expect(VolumeLookup.relativePath(of: "/", on: root) == "")
    }

    @Test func systemMonitorListsTheSystemVolume() {
        let v = SystemVolumeMonitor().mountedVolumes()
        #expect(v.contains { $0.isSystem && $0.format == .apfs && $0.uuid != nil })
        #expect(v.allSatisfy { $0.mountPath == "/" || !$0.mountPath.hasSuffix("/") })
    }

    @Test func startAndStopTwiceIsHarmless() {
        let monitor = SystemVolumeMonitor()
        monitor.stop()
        monitor.start(onMount: { _ in }, onWillUnmount: { _ in }, onUnmount: { _ in })
        monitor.start(onMount: { _ in }, onWillUnmount: { _ in }, onUnmount: { _ in })
        monitor.stop()
        monitor.stop()
        monitor.start(onMount: { _ in }, onWillUnmount: { _ in }, onUnmount: { _ in })
        monitor.stop()
    }
}
