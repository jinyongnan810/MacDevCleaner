import Foundation

nonisolated enum FindingCategory: String, CaseIterable, Identifiable, Sendable {
    case caches, dependencies, tools
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .caches: "Caches & builds"
        case .dependencies: "Project dependencies"
        case .tools: "Tools & containers"
        }
    }

    var symbol: String {
        switch self {
        case .caches: "shippingbox"
        case .dependencies: "folder.badge.gearshape"
        case .tools: "terminal"
        }
    }
}

nonisolated struct Finding: Identifiable, Sendable {
    let url: URL
    let title: String
    let ecosystem: String
    let category: FindingCategory
    let bytes: Int64
    let modified: Date?
    let explanation: LocalizedStringResource
    let consequence: LocalizedStringResource
    let inspectionCommand: String?
    var incomplete: Bool
    var measurementIsStale = false
    var volumeURL: URL?
    var id: String { url.path }
    var command: String { inspectionCommand ?? "/bin/rm -rf -- \(Self.quote(url.path))" }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    var displaySize: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

nonisolated struct ScanReport: Sendable {
    var findings: [Finding] = []
    var issues: [String] = []
    var directoriesVisited = 0
    var inaccessibleLocations = 0
    var volumesScanned = 0
}

nonisolated struct ScanProgress: Sendable {
    var path = "/"
    var directoriesVisited = 0
    var findingsCount = 0
}

/// Filesystem work is isolated from the UI. Never launches a process or modifies scanned files.
actor StorageScanner {
    private let manager = FileManager.default
    private let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
                                             .fileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
    private struct Rule {
        let path: String
        let title: String
        let ecosystem: String
        var category: FindingCategory = .caches
        var command: String?
    }

    /// Discover local volumes automatically; never request a folder or elevate privileges.
    func scanMac(progress: @Sendable (ScanProgress) async -> Void) async throws -> ScanReport {
        var roots = [URL(fileURLWithPath: "/", isDirectory: true)]
        let volumes = manager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeIsBrowsableKey], options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path.hasPrefix("/Volumes/") {
            let values = try? volume.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsBrowsableKey])
            if values?.volumeIsLocal == true, values?.volumeIsBrowsable != false {
                roots.append(volume)
            }
        }
        return try await scan(roots: roots, progress: progress)
    }

    // The explicit roots entry point also supports isolated filesystem verification.
    func scan(roots: [URL], progress: @Sendable (ScanProgress) async -> Void) async throws -> ScanReport {
        var report = ScanReport()
        var measured: Set<String> = []
        for root in roots {
            try Task.checkCancellation()
            try await scanTree(root, measured: &measured, report: &report, progress: progress)
            report.volumesScanned += 1
        }
        report.findings.sort { $0.bytes > $1.bytes }
        return report
    }

    /// Recheck only known findings after cleanup; no whole-disk discovery is needed.
    func refresh(_ findings: [Finding]) throws -> ScanReport {
        var report = ScanReport()
        var measured: Set<String> = []
        for finding in findings {
            try Task.checkCancellation()
            do {
                // Enumerator URLs retain resource-value caches. Build a fresh URL so
                // refresh observes external deletion, replacement, and size changes.
                let location = URL(fileURLWithPath: finding.url.path, isDirectory: true)
                var current = location
                while current.path != "/" {
                    let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
                    if values.isSymbolicLink == true {
                        throw CocoaError(.fileReadInvalidFileName)
                    }
                    current = current.deletingLastPathComponent()
                }
                let values = try location.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { throw CocoaError(.fileReadUnknown) }
                let rule = Rule(path: "", title: finding.title, ecosystem: finding.ecosystem,
                                category: finding.category, command: finding.inspectionCommand)
                let count = report.findings.count
                try record(location, rule: rule, measured: &measured, report: &report)
                if report.findings.count == count { retainStale(finding, in: &report) }
            } catch is CancellationError { throw CancellationError() }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // An unmounted or unreadable drive does not prove cleanup succeeded.
                if let volume = finding.volumeURL, manager.isReadableFile(atPath: volume.path) {
                    continue
                }
                retainStale(finding, in: &report)
            } catch {
                retainStale(finding, in: &report)
            }
        }
        report.findings.sort { $0.bytes > $1.bytes }
        return report
    }

    private func retainStale(_ finding: Finding, in report: inout ScanReport) {
        var previous = finding
        previous.measurementIsStale = true
        report.findings.append(previous)
        report.inaccessibleLocations += 1
        report.issues.append("Could not recheck \(finding.url.path). The previous size is retained; the location may be inaccessible, changed, or on an unavailable drive.")
    }

    private let homeRules: [Rule] = [Rule(path: "Library/Developer/Xcode/DerivedData", title: "Xcode Derived Data", ecosystem: "Xcode"),
                                     Rule(path: "Library/Caches/org.swift.swiftpm", title: "Swift package cache", ecosystem: "Swift"),
                                     Rule(path: ".npm/_cacache", title: "npm download cache", ecosystem: "Node.js"),
                                     Rule(path: "Library/Caches/Yarn", title: "Yarn cache", ecosystem: "Node.js"),
                                     Rule(path: "Library/pnpm/store", title: "pnpm store", ecosystem: "Node.js"),
                                     Rule(path: "Library/Caches/pip", title: "pip download cache", ecosystem: "Python"),
                                     Rule(path: "Library/Caches/uv", title: "uv cache", ecosystem: "Python"),
                                     Rule(path: "Library/Caches/Homebrew", title: "Homebrew downloads", ecosystem: "Homebrew"),
                                     Rule(path: ".gradle/caches", title: "Gradle cache", ecosystem: "Java / Kotlin"),
                                     Rule(path: ".cargo/registry", title: "Cargo registry", ecosystem: "Rust"),
                                     Rule(path: ".nvm/versions", title: "Node.js versions", ecosystem: "nvm", category: .tools),
                                     Rule(path: ".pyenv/versions", title: "Python versions", ecosystem: "pyenv", category: .tools),
                                     Rule(path: ".rustup/toolchains", title: "Rust toolchains", ecosystem: "Rust", category: .tools),
                                     Rule(path: "Library/Python", title: "User Python packages", ecosystem: "Python", category: .tools),
                                     Rule(path: ".local/pipx/venvs", title: "pipx environments", ecosystem: "Python", category: .tools),
                                     Rule(path: "Library/Containers/com.docker.docker/Data/vms", title: "Docker virtual machines", ecosystem: "Docker", category: .tools, command: "docker system df -v"),
                                     Rule(path: "Library/Application Support/com.apple.container", title: "Apple container storage", ecosystem: "Apple container", category: .tools, command: "container image list")]

    /// The startup volume exposes Data through firmlinks. Skip its /System alias,
    /// and scan mounted local volumes separately so each file tree is visited once.
    private func shouldSkip(_ url: URL) -> Bool {
        let path = url.path
        let excluded = ["/System", "/dev", "/bin", "/sbin", "/Volumes", "/Network",
                        "/private/var/db", "/private/var/vm", "/private/var/run", "/private/var/protected"]
        if excluded.contains(path) { return true }
        if path.hasPrefix("/usr/"), path != "/usr/local", !path.hasPrefix("/usr/local/") { return true }
        return [".git", ".svn", ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", "Backups.backupdb"].contains(url.lastPathComponent)
    }

    private func rule(for url: URL) -> Rule? {
        if let rule = homeRules.first(where: { url.path.hasSuffix("/" + $0.path) }) { return rule }
        switch url.path {
        case "/opt/homebrew/Cellar", "/usr/local/Cellar":
            return Rule(path: "", title: "Homebrew installations", ecosystem: "Homebrew", category: .tools)
        case "/Library/Developer/CommandLineTools":
            return Rule(path: "", title: "Apple command line tools", ecosystem: "Apple", category: .tools)
        case "/Library/Frameworks/Python.framework":
            return Rule(path: "", title: "Python framework", ecosystem: "Python", category: .tools)
        default: return projectRule(url)
        }
    }

    private func scanTree(_ root: URL, measured: inout Set<String>, report: inout ScanReport,
                          progress: @Sendable (ScanProgress) async -> Void) async throws
    {
        var errors: [String] = []
        var errorCount = 0
        var lastUpdate = ContinuousClock.now
        let traversalKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: Array(traversalKeys), options: [.skipsPackageDescendants], errorHandler: { url, error in
            errorCount += 1
            if errors.count < 100 { errors.append("\(url.path): \(error.localizedDescription)") }
            return true
        }) else {
            report.issues.append("Could not enumerate \(root.path)")
            report.inaccessibleLocations += 1
            return
        }
        await progress(ScanProgress(path: root.path, directoriesVisited: report.directoriesVisited, findingsCount: report.findings.count))
        for case let url as URL in walker {
            try Task.checkCancellation()
            do {
                let values = try url.resourceValues(forKeys: traversalKeys)
                if values.isSymbolicLink == true { walker.skipDescendants(); continue }
                guard values.isDirectory == true else { continue }
                if shouldSkip(url) { walker.skipDescendants(); continue }
                report.directoriesVisited += 1
                let rule = rule(for: url)
                if rule != nil || lastUpdate.duration(to: .now) > .milliseconds(150) {
                    await progress(ScanProgress(path: url.path, directoriesVisited: report.directoriesVisited, findingsCount: report.findings.count))
                    lastUpdate = .now
                }
                if let rule {
                    walker.skipDescendants()
                    try record(url, rule: rule, measured: &measured, report: &report)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                errorCount += 1
                if errors.count < 100 { errors.append("\(url.path): \(error.localizedDescription)") }
            }
        }
        report.issues.append(contentsOf: errors)
        report.inaccessibleLocations += errorCount
        if errorCount > errors.count {
            report.issues.append("\(errorCount - errors.count) additional access errors on \(root.path).")
        }
    }

    private func projectRule(_ url: URL) -> Rule? {
        switch url.lastPathComponent {
        case "node_modules": Rule(path: "", title: "\(url.deletingLastPathComponent().lastPathComponent) dependencies", ecosystem: "Node.js", category: .dependencies)
        case ".venv", "venv": manager.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path)
            ? Rule(path: "", title: "\(url.deletingLastPathComponent().lastPathComponent) virtual environment", ecosystem: "Python", category: .dependencies) : nil
        case ".terraform": Rule(path: "", title: "Terraform working data", ecosystem: "Terraform", category: .dependencies, command: "/bin/ls -lah \(Finding.quote(url.path))")
        case ".build": manager.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("Package.swift").path)
            ? Rule(path: "", title: "Swift build output", ecosystem: "Swift") : nil
        case "target": manager.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("Cargo.toml").path)
            ? Rule(path: "", title: "Rust build output", ecosystem: "Rust") : nil
        default: nil
        }
    }

    private func record(_ url: URL, rule: Rule, measured: inout Set<String>, report: inout ScanReport) throws {
        let path = url.standardizedFileURL.path
        guard !measured.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return }
        // Do not double count when overlapping roots are selected in either order.
        report.findings.removeAll { $0.id.hasPrefix(path + "/") }
        measured.insert(path)
        var bytes: Int64 = 0
        var incomplete = false
        var fileIDs: Set<AnyHashable> = []
        let sizeKeys = keys.union([.fileResourceIdentifierKey])
        guard let walker = manager.enumerator(at: url, includingPropertiesForKeys: Array(sizeKeys), errorHandler: { _, _ in
            incomplete = true
            return true
        }) else {
            report.inaccessibleLocations += 1
            if report.issues.count < 200 { report.issues.append("Could not measure \(path)") }
            return
        }
        for case let child as URL in walker {
            try Task.checkCancellation()
            do {
                let values = try child.resourceValues(forKeys: sizeKeys)
                if values.isSymbolicLink == true { walker.skipDescendants(); continue }
                guard values.isRegularFile == true else { continue }
                if let identifier = values.fileResourceIdentifier as? AnyHashable {
                    guard fileIDs.insert(identifier).inserted else { continue }
                }
                bytes += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
            } catch { incomplete = true }
        }
        if incomplete {
            report.inaccessibleLocations += 1
            if report.issues.count < 200 { report.issues.append("Some files could not be measured in \(path). Size is a lower bound.") }
        }
        let isTool = rule.category == .tools
        let isTerraform = rule.ecosystem == "Terraform"
        let explanation: LocalizedStringResource = isTool
            ? "Installed tools or container data. Size alone does not show whether this is still needed."
            : "Generated files associated with this tool or project. Review the folder before removing it."
        let consequence: LocalizedStringResource = isTool
            ? "Review versions and usage with the owning tool. Container storage may include databases and volumes. Do not delete the storage directory directly."
            : isTerraform
            ? "Review this directory for local state, workspaces, and custom files first. Back up any state. Removing it requires terraform init again; root .tfstate files are outside this finding."
            : rule.category == .dependencies
            ? "Dependencies must be reinstalled before using this project. Preserve manifests and lockfiles, and check for locally modified or untracked files."
            : "Close related builds and tools first. Files may be downloaded or rebuilt later. Locally modified files would be lost."
        let command = rule.command ?? (isTool ? "/bin/ls -lah \(Finding.quote(path))" : nil)
        report.findings.append(Finding(url: url, title: rule.title, ecosystem: rule.ecosystem, category: rule.category, bytes: bytes,
                                       modified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                                       explanation: explanation, consequence: consequence, inspectionCommand: command, incomplete: incomplete,
                                       volumeURL: try? url.resourceValues(forKeys: [.volumeURLKey]).volume))
    }
}
