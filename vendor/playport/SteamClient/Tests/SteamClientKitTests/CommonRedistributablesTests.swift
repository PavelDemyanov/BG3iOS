// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import SteamClientKit

/// Steamworks Common Redistributables (decision 0081): which of app 228980's depots a title
/// lists, which Playport already holds, and where the install scripts are.
final class CommonRedistributablesTests: XCTestCase {
    func receipt(_ appID: UInt32, dir: String, depots: [DepotRef], skipped: [String] = []) -> InstallReceipt {
        InstallReceipt(appID: appID, name: "T", installDir: dir, buildID: 1, depots: depots, files: 0, bytes: 0,
                       skippedDepots: skipped, skippedSymlinks: 0, installedAt: "-")
    }

    func testAReceiptsSkippedRedistributablesAreTheDepotsItLists() {
        // As DepotSelection writes them (Counter-Strike: VC++ 2019 and its Half-Life content's language depot).
        let r = receipt(10, dir: "Half-Life", depots: [], skipped: [
            "228988: \(DepotSelection.sharedInstallReason(228980))", "228990: \(DepotSelection.sharedInstallReason(228980))",
            "141: language russian", "4: \(DepotSelection.sharedInstallReason(70))", "x: shared install from app 228980",
        ])
        XCTAssertEqual(r.commonRedistributableDepots, [228988, 228990])
        XCTAssertNil(DepotSelection.sharedInstall(skipped: "228988: shared install from app 228980 (something else)"))
        XCTAssertEqual(DepotSelection.sharedInstall(skipped: "4: \(DepotSelection.sharedInstallReason(70))")?.appID, 70)
    }

    func testDirectXJun2010IsNeverDownloaded() {
        // Castle Crashers Demo lists DirectX alone: nothing to download.
        XCTAssertEqual(CommonRedistributables.depotsToDownload([228990]), [])
        XCTAssertEqual(CommonRedistributables.depotsToDownload([228988, 228990, 228989]), [228988, 228989])
        XCTAssertEqual(CommonRedistributables.depotsToDownload([]), [])
    }

    func testInstallScriptsAreTheFilesTheRetainedManifestsFlag() throws {
        let dir = try scratchDir("redist")
        defer { try? FileManager.default.removeItem(at: dir) }
        let layout = InstallLayout.root(dir)
        let installer = TitleInstaller(layout: layout, session: nil, log: .silent)
        let script = DepotManifest.File(path: "_CommonRedist/DirectX/Jun2010/installscript.vdf", size: 3,
                                        flags: DepotFileFlag.installScript, shaContent: nil, chunks: [], linkTarget: nil)
        let other = DepotManifest.File(path: "_CommonRedist/DirectX/Jun2010/DXSETUP.exe", size: 3,
                                       flags: 32, shaContent: nil, chunks: [], linkTarget: nil)
        let dx = try DepotManifest(depotID: 228990, gid: 5, files: [script, other])
        let vc = try DepotManifest(depotID: 228988, gid: 6, files: [
            DepotManifest.File(path: "_CommonRedist/vcredist/2019/installscript.vdf", size: 3,
                               flags: DepotFileFlag.installScript | 8, shaContent: nil, chunks: [], linkTarget: nil)])
        for m in [dx, vc] { try RetainedManifest.save(m, to: layout.manifestFile(DepotRef(depotID: m.depotID, gid: m.gid))) }
        XCTAssertEqual(installer.missingCommonRedistributables([228990]), [228990], "none held yet")
        try installer.saveReceipt(receipt(CommonRedistributables.appID, dir: CommonRedistributables.installDir,
                                          depots: [DepotRef(depotID: 228990, gid: 5), DepotRef(depotID: 228988, gid: 6)]))
        let found = installer.installScripts(appID: CommonRedistributables.appID)
        XCTAssertEqual(found.map(\.depotID), [228990, 228988])
        XCTAssertEqual(found.map(\.path), ["_CommonRedist/DirectX/Jun2010/installscript.vdf", "_CommonRedist/vcredist/2019/installscript.vdf"])
        XCTAssertEqual(installer.missingCommonRedistributables([228990, 228988, 228989]), [228989])
        XCTAssertTrue(installer.installScripts(appID: 42).isEmpty, "no record, none")
    }
}
