// SPDX-License-Identifier: GPL-3.0-or-later
// macport: an install made elsewhere (copied from a Mac, or prepared earlier) adopted as this install: the
// selected depots' manifests are fetched and retained and a receipt is written for the existing folder, without
// downloading anything. `repair` then re-hashes every file and re-downloads only the ones that differ.
import Foundation

extension TitleInstaller {
    public func adopt(_ r: Request, folder: String, say: @escaping @Sendable (String) -> Void) async throws -> InstallReceipt {
        guard let session else { throw SteamError.notLoggedOn }
        let branch = r.branch ?? Branch.publicName
        let app = try await Library(session: session).depots(appID: r.appID).onBranch(branch)
        var options = r.selection
        if options.ownedDepots == nil, options.explicit == nil {
            options.ownedDepots = await ownedDepots(session, say: say)
        }
        let selection = try DepotSelection.select(app, options)
        let name = try Self.destinationName(folder)
        let refs = selection.depots.map { DepotRef(depotID: $0.depotID, gid: $0.publicManifestGID!) }
        let content = await ContentClient(session: session)
        let servers = try await content.servers(appID: r.appID)
        var manifests: [DepotManifest] = []
        for ref in refs {
            let keyApp = app.keyAppID(depot: ref.depotID)
            let key = try await depotKey(content, appID: keyApp, depotID: ref.depotID, for: r.appID)
            manifests.append(try await manifest(ref, appID: keyApp, branch: branch, key: key, content: content,
                                                servers: servers, say: say))
        }
        let plan = try InstallPlan.make(appID: r.appID, buildID: app.publicBuildID, manifests: manifests)
        let receipt = InstallReceipt(appID: r.appID, name: app.name, installDir: name, buildID: app.publicBuildID, depots: refs,
                                     files: plan.files.count, bytes: plan.totalBytes,
                                     skippedDepots: selection.skipped.map { "\($0.depotID): \($0.reason)" },
                                     skippedSymlinks: plan.skippedSymlinks.count,
                                     installedAt: ISO8601DateFormatter().string(from: Date()),
                                     branch: branch == Branch.publicName ? nil : branch,
                                     executable: app.launchExecutable, arguments: app.launchArguments)
        try saveReceipt(receipt)
        // Symlinks the folder lacks (a copy made without them).
        if options.platform != "windows" {
            let root = layout.gamesRoot.appendingPathComponent(name, isDirectory: true)
            var made = 0
            for link in plan.symlinks {
                let at = root.appendingPathComponent(link.path.replacingOccurrences(of: "\\", with: "/"))
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: at.path)) != nil { continue }
                try FileManager.default.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(atPath: at.path,
                                                           withDestinationPath: link.target.replacingOccurrences(of: "\\", with: "/"))
                made += 1
            }
            if made > 0 { say("adopt: \(made) symlinks made") }
        }
        say("adopt: Games/\(name) recorded as app \(r.appID) build \(app.publicBuildID.map(String.init) ?? "?"): "
            + "\(plan.files.count) files, \(plan.totalBytes) bytes; run repair to check and fix it")
        return receipt
    }
}
