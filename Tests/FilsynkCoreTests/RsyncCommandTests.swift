import Foundation
import Testing
@testable import FilsynkCore

@Test func timestampFormat() {
    let d = Date(timeIntervalSince1970: 1_794_922_325) // 2026-11-17 13:32:05 UTC
    #expect(RsyncCommand.timestamp(d, timeZone: TimeZone(identifier: "Europe/Stockholm")!) == "2026-11-17_143205")
}

@Test func buildsExactArguments() {
    var c = Config.initial(home: "/Users/x"); c.server = "u@h"; c.identityFile = "/k/id"
    let f = FolderConfig(path: "/Users/x/Sync", remotePath: "/home/u/Sync")
    let inv = RsyncCommand.sync(config: c, folder: f, timestamp: "2026-11-17_143205", excludeFile: "/tmp/ex")
    #expect(inv.executable == "/usr/bin/rsync")
    #expect(inv.arguments == ["-a", "--delete", "--backup",
        "--backup-dir=/home/u/Sync/Raderat/2026-11-17_143205", "--exclude=/Raderat/", "--exclude-from=/tmp/ex",
        "--partial-dir=.filsynk-partial", "--timeout=60", "--stats",
        "-e", "ssh -i /k/id -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4",
        "/Users/x/Sync/", "u@h:/home/u/Sync/"])
}

@Test func trailingSlashesAreNormalised() {
    var c = Config.initial(home: "/a"); c.server = "u@h"; c.identityFile = "/k/id"
    let plain = RsyncCommand.sync(
        config: c, folder: FolderConfig(path: "/a/Sync", remotePath: "/r/Sync"),
        timestamp: "t", excludeFile: "/tmp/ex")
    let slashed = RsyncCommand.sync(
        config: c, folder: FolderConfig(path: "/a/Sync/", remotePath: "/r/Sync/"),
        timestamp: "t", excludeFile: "/tmp/ex")
    #expect(plain == slashed)
    #expect(slashed.arguments.contains("--backup-dir=/r/Sync/Raderat/t"))
    #expect(Array(slashed.arguments.suffix(2)) == ["/a/Sync/", "u@h:/r/Sync/"])
}

@Test func localTargetHasNoSshAndPlainDestination() {
    var c = Config.initial(home: "/a"); c.server = "u@h"
    let inv = RsyncCommand.sync(
        config: c, folder: FolderConfig(path: "/a/Sync", remotePath: "/r/Sync"),
        timestamp: "t", excludeFile: "/tmp/ex", target: .localForTesting)
    #expect(!inv.arguments.contains("-e"))
    #expect(inv.arguments.last == "/r/Sync/")
    #expect(inv.arguments.dropLast().last == "/a/Sync/")
}

@Test func excludeFileListsBuiltInsThenUsers() {
    var c = Config.initial(home: "/a"); c.exclude = ["node_modules"]
    #expect(RsyncCommand.excludeFileContents(c) == ".DS_Store\n._*\n.localized\n.Trash*\n.Spotlight-V100\n.fseventsd\nnode_modules\n")
}

@Test func sshArgumentsExpandTilde() {
    let args = RsyncCommand.sshArguments(identityFile: "~/.ssh/k")
    #expect(args == ["-i", NSHomeDirectory() + "/.ssh/k", "-o", "IdentitiesOnly=yes",
                     "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                     "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4"])
}

@Suite struct DiskCommandTests {
    private let config = Config(folders: [])

    @Test func diskDryRunArgumentsOnAPFS() {
        let inv = RsyncCommand.diskDryRun(
            config: config, source: "/Users/x/A", destination: "/Volumes/D/Filsynk/A",
            format: .apfs, excludeFile: "/tmp/ex")
        #expect(inv.executable == "/usr/bin/rsync")
        #expect(inv.arguments == ["-a", "--exclude=/Raderat/", "--exclude=/.filsynk", "--exclude-from=/tmp/ex",
            "--partial-dir=.filsynk-partial", "-n", "-i", "-8", "--delete", "/Users/x/A/", "/Volumes/D/Filsynk/A/"])
    }

    @Test func diskDryRunArgumentsOnExFAT() {
        let inv = RsyncCommand.diskDryRun(
            config: config, source: "/Users/x/A/", destination: "/Volumes/D/Filsynk/A/",
            format: .exfat, excludeFile: "/tmp/ex")
        #expect(inv.arguments == ["-rlt", "--modify-window=1", "--exclude=/Raderat/", "--exclude=/.filsynk",
            "--exclude-from=/tmp/ex", "--partial-dir=.filsynk-partial", "-n", "-i", "-8", "--delete",
            "/Users/x/A/", "/Volumes/D/Filsynk/A/"])
    }

    @Test func diskSyncArgumentsOnAPFS() {
        let inv = RsyncCommand.diskSync(
            config: config, source: "/Users/x/A", destination: "/Volumes/D/Filsynk/A",
            format: .hfs, timestamp: "2026-11-17_143205", excludeFile: "/tmp/ex")
        #expect(inv.arguments == ["-a", "--exclude=/Raderat/", "--exclude=/.filsynk", "--exclude-from=/tmp/ex",
            "--partial-dir=.filsynk-partial", "--backup", "--backup-dir=/Volumes/D/Filsynk/A/Raderat/2026-11-17_143205",
            "--timeout=60", "--stats", "/Users/x/A/", "/Volumes/D/Filsynk/A/"])
    }

    @Test func diskSyncArgumentsOnExFAT() {
        let inv = RsyncCommand.diskSync(
            config: config, source: "/Users/x/A", destination: "/Volumes/D/Filsynk/A/",
            format: .exfat, timestamp: "2026-11-17_143205", excludeFile: "/tmp/ex")
        #expect(inv.arguments == ["-rlt", "--modify-window=1", "--exclude=/Raderat/", "--exclude=/.filsynk",
            "--exclude-from=/tmp/ex", "--partial-dir=.filsynk-partial", "--backup",
            "--backup-dir=/Volumes/D/Filsynk/A/Raderat/2026-11-17_143205",
            "--timeout=60", "--stats", "/Users/x/A/", "/Volumes/D/Filsynk/A/"])
    }

    @Test func diskSyncNeverContainsDelete() {
        for format in [VolumeFormat.apfs, .hfs, .exfat] {
            let inv = RsyncCommand.diskSync(
                config: config, source: "/a", destination: "/Volumes/D/A",
                format: format, timestamp: "t", excludeFile: "/tmp/ex")
            #expect(!inv.arguments.contains("--delete"), "\(format)")
            #expect(!inv.arguments.contains("-e"), "\(format)")
            #expect(!inv.arguments.contains { $0.hasPrefix("--delete") }, "\(format)")
        }
    }

    @Test func diskCommandsUseTheConfiguredRsync() {
        var c = config; c.rsyncPath = "/opt/bin/rsync"
        #expect(RsyncCommand.diskDryRun(config: c, source: "/a", destination: "/b", format: .apfs, excludeFile: "/e").executable == "/opt/bin/rsync")
        #expect(RsyncCommand.diskSync(config: c, source: "/a", destination: "/b", format: .apfs, timestamp: "t", excludeFile: "/e").executable == "/opt/bin/rsync")
    }
}
