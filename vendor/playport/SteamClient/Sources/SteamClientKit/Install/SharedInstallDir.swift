// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Several Steam apps in one install folder, as Steam installs them:
/// Counter-Strike (10) and Half-Life (70) both name `Half-Life` and share
/// Half-Life's engine depots. Each app keeps its own record and retained
/// manifests; the folder holds the union of their files. A file two apps list
/// must have the same content in both, so an install or update that would
/// change another app's file is refused rather than overwrite it. Leaving the
/// folder removes only the files (and empty directories) no other app lists.
public enum SharedInstallDir {
    /// What another app in the folder lists at a path.
    struct Listed: Equatable {
        var appID: UInt32
        var size: UInt64
        var sha: [UInt8]?
    }

    /// The other apps' files and directories, by lower-cased path (the guest compares without case).
    struct Others {
        var files: [String: Listed] = [:]
        var directories: Set<String> = []
        var appIDs: [UInt32] = []

        init(_ plans: [InstallPlan]) {
            for p in plans {
                appIDs.append(p.appID)
                for f in p.files where files[f.path.lowercased()] == nil {
                    files[f.path.lowercased()] = Listed(appID: p.appID, size: f.size, sha: f.sha)
                }
                for d in p.directories { directories.insert(d.lowercased()) }
            }
        }

        /// Lists `path` as a file, a directory, or the parent of either.
        func needs(directory path: String) -> Bool {
            let key = path.lowercased()
            if directories.contains(key) { return true }
            let prefix = key + "/"
            return files.keys.contains { $0.hasPrefix(prefix) } || directories.contains { $0.hasPrefix(prefix) }
        }
    }

    /// The paths of `plan` to download into the folder: those no other app
    /// lists. A file another app lists with the same size and SHA-1 is already
    /// there; one with other content is that app's, and the install is refused.
    static func pathsToStage(_ plan: InstallPlan, others: Others, folder: String) throws -> Set<String> {
        var out = Set<String>()
        for f in plan.files {
            guard let o = others.files[f.path.lowercased()] else {
                out.insert(f.path)
                continue
            }
            let same = o.size == f.size && o.sha == f.sha && (f.sha != nil || f.size == 0)
            guard same else {
                throw SteamError.unsafeContent("Games/\(folder)/\(f.path) is app \(o.appID)'s file with other content; "
                                               + "refusing to overwrite another app's file in a shared folder")
            }
        }
        return out
    }

    /// The paths of `own` that no other app lists: what leaving the folder removes.
    static func removable(_ own: [String], others: Others) -> [String] {
        own.filter { others.files[$0.lowercased()] == nil }
    }
}
