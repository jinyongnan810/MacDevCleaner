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

nonisolated struct ScanRoot: Identifiable, Sendable {
    let url: URL
    let isHome: Bool
    var id: String { url.path }
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
    let incomplete: Bool
    var id: String { url.path }
    var command: String { inspectionCommand ?? "/bin/rm -ri -- \(Self.quote(url.path))" }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    var displaySize: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

nonisolated struct ScanReport: Sendable {
    var findings: [Finding] = []
    var issues: [String] = []
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

    func scan(roots: [ScanRoot]) throws -> ScanReport {
        var report = ScanReport()
        var measured: Set<String> = []
        for root in roots {
            try Task.checkCancellation()
            if root.isHome {
                for rule in homeRules {
                    try Task.checkCancellation()
                    let url = root.url.appendingPathComponent(rule.path)
                    do {
                        guard try hasNoSymlinks(url, within: root.url) else { continue }
                        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                        try record(url, rule: rule, measured: &measured, report: &report)
                    } catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
                    catch is CancellationError { throw CancellationError() }
                    catch { report.issues.append("\(url.path): \(error.localizedDescription)") }
                }
            } else {
                try scanProjects(root.url, measured: &measured, report: &report)
            }
        }
        report.findings.sort { $0.bytes > $1.bytes }
        return report
    }

    private var homeRules: [Rule] {
        [Rule(path: "Library/Developer/Xcode/DerivedData", title: "Xcode Derived Data", ecosystem: "Xcode"),
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
    }

    private func hasNoSymlinks(_ url: URL, within root: URL) throws -> Bool {
        var current = url
        while current.path != root.path {
            if try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { return false }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return false }
            current = parent
        }
        return try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
    }

    private func scanProjects(_ root: URL, measured: inout Set<String>, report: inout ScanReport) throws {
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return }
        // A selected dependency directory is itself a valid scan root.
        if let rule = projectRule(root) {
            try record(root, rule: rule, measured: &measured, report: &report)
            return
        }
        var errors: [String] = []
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants], errorHandler: { url, error in
            errors.append("\(url.path): \(error.localizedDescription)")
            return true
        }) else {
            report.issues.append("Could not enumerate \(root.path)")
            return
        }
        for case let url as URL in walker {
            try Task.checkCancellation()
            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { walker.skipDescendants(); continue }
                guard values.isDirectory == true else { continue }
                if let rule = projectRule(url) {
                    walker.skipDescendants()
                    try record(url, rule: rule, measured: &measured, report: &report)
                } else if [".git", ".svn", "Library", ".Trash"].contains(url.lastPathComponent) {
                    walker.skipDescendants()
                }
            } catch is CancellationError { throw CancellationError() }
            catch { errors.append("\(url.path): \(error.localizedDescription)") }
        }
        report.issues.append(contentsOf: errors)
    }

    private func projectRule(_ url: URL) -> Rule? {
        switch url.lastPathComponent {
        case "node_modules": Rule(path: "", title: "\(url.deletingLastPathComponent().lastPathComponent) dependencies", ecosystem: "Node.js", category: .dependencies)
        case ".venv", "venv": manager.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path)
            ? Rule(path: "", title: "\(url.deletingLastPathComponent().lastPathComponent) virtual environment", ecosystem: "Python", category: .dependencies) : nil
        case ".terraform": Rule(path: "", title: "Terraform working data", ecosystem: "Terraform", category: .dependencies, command: "/bin/ls -lah \(Finding.quote(url.path))")
        case "CommandLineTools": Rule(path: "", title: "Command line tools", ecosystem: "Apple", category: .tools)
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
        }) else { report.issues.append("Could not measure \(path)"); return }
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
        if incomplete { report.issues.append("Some files could not be measured in \(path). Size is a lower bound.") }
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
                                       explanation: explanation, consequence: consequence, inspectionCommand: command, incomplete: incomplete))
    }
}
