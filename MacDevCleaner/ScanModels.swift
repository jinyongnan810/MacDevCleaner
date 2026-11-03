import Foundation

nonisolated enum FindingCategory: String, CaseIterable, Identifiable, Sendable {
    case caches, dependencies, tools, vms, apps
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .caches: "Caches & builds"
        case .dependencies: "Project dependencies"
        case .tools: "CLIs & runtimes"
        case .vms: "VMs & models"
        case .apps: "Apps & support"
        }
    }

    var symbol: String {
        switch self {
        case .caches: "shippingbox"
        case .dependencies: "folder.badge.gearshape"
        case .tools: "terminal"
        case .vms: "desktopcomputer"
        case .apps: "app.badge"
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
    let uninstallCommand: String?
    let inspectionCommand: String?
    var groupKey: String?
    var groupTitle: String?
    var incomplete: Bool
    var measurementIsStale = false
    var volumeURL: URL?
    var id: String { url.path }
    var command: String { uninstallCommand ?? inspectionCommand ?? "/bin/rm -rf -- \(Self.quote(url.path))" }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    var displaySize: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

nonisolated struct FindingGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let ecosystem: String
    let category: FindingCategory
    let explanation: LocalizedStringResource
    let consequence: LocalizedStringResource
    let items: [Finding]
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var displaySize: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
}

nonisolated enum FindingDisplayItem: Identifiable, Sendable {
    case single(Finding)
    case group(FindingGroup)

    var id: String {
        switch self {
        case let .single(finding): finding.id
        case let .group(group): group.id
        }
    }

    var bytes: Int64 {
        switch self {
        case let .single(finding): finding.bytes
        case let .group(group): group.totalBytes
        }
    }
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
        var uninstallCommand: String?
        var command: String?
        var groupKey: String?
        var groupTitle: String?
        var explanation: LocalizedStringResource?
        var consequence: LocalizedStringResource?
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
                let values = try location.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if finding.ecosystem == "Ollama LLM", values.isRegularFile == true {
                    if let updated = try measureOllamaManifest(location) {
                        report.findings.append(updated)
                    } else {
                        retainStale(finding, in: &report)
                    }
                    continue
                }
                guard values.isDirectory == true else { throw CocoaError(.fileReadUnknown) }
                let rule = Rule(path: "", title: finding.title, ecosystem: finding.ecosystem,
                                category: finding.category, uninstallCommand: finding.uninstallCommand,
                                command: finding.inspectionCommand, groupKey: finding.groupKey,
                                groupTitle: finding.groupTitle, explanation: finding.explanation,
                                consequence: finding.consequence)
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
                                     Rule(path: ".aws/cli/cache", title: "AWS CLI credential & response cache", ecosystem: "AWS CLI"),
                                     Rule(path: ".aws/sso/cache", title: "AWS SSO token cache", ecosystem: "AWS CLI"),
                                     Rule(path: "Library/Containers/com.docker.docker/Data/vms", title: "Docker virtual machines", ecosystem: "Docker", category: .vms, command: "docker system df -v"),
                                     Rule(path: "Library/Application Support/com.apple.container", title: "Apple container storage", ecosystem: "Apple container", category: .vms, command: "container image list"),
                                     Rule(path: "Library/Application Support/nomic.ai/GPT4All", title: "GPT4All local models", ecosystem: "GPT4All LLM", category: .vms,
                                          uninstallCommand: nil,
                                          explanation: "Local large language model files downloaded in GPT4All.",
                                          consequence: "Removing deletes downloaded GPT4All model weights.")]

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
        if let cli = cliRule(for: url) { return cli }
        if let lang = languageVersionRule(for: url) { return lang }
        if let vm = vmAndModelRule(for: url) { return vm }
        if let appSupport = appSupportRule(for: url) { return appSupport }
        switch url.path {
        case "/Library/Developer/CommandLineTools":
            return Rule(path: "", title: "Apple Command Line Tools", ecosystem: "Apple CLI", category: .tools,
                        uninstallCommand: "sudo /bin/rm -rf -- \(Finding.quote(url.path))",
                        explanation: "Apple's standalone command line developer tools (clang, git, make, SDKs).",
                        consequence: "Uninstalling removes command-line compilers and SDKs outside Xcode. Run xcode-select --install to reinstall if needed.")
        default: return projectRule(url)
        }
    }

    private func appSupportRule(for url: URL) -> Rule? {
        let name = url.lastPathComponent
        let parentPath = url.deletingLastPathComponent().path
        guard parentPath.hasSuffix("/Library/Application Support"), !name.hasPrefix(".") else { return nil }
        let skippedSupportDirs: Set<String> = [
            "Apple", "AddressBook", "CallHistoryDB", "CallHistoryTransactions",
            "CloudDocs", "CrashReporter", "DifferentialPrivacy", "DiskImages",
            "Dock", "FileProvider", "icdd", "Knowledge", "MobileSync",
            "SyncServices", "fnm", "mise", "uv", "Jan", "nomic.ai",
        ]
        if name.hasPrefix("com.apple.") || skippedSupportDirs.contains(name) { return nil }
        let needsSudo = url.path.hasPrefix("/Library/")
        return Rule(path: "",
                    title: "\(name) (Application Support)",
                    ecosystem: "Application Support",
                    category: .apps,
                    uninstallCommand: "\(needsSudo ? "sudo " : "")/bin/rm -rf -- \(Finding.quote(url.path))",
                    explanation: "Application Support data, extensions, or local databases stored by \(name).",
                    consequence: "If \(name) is still installed, deleting this resets its local settings and data. If the app was already removed, this leftover support folder can be deleted.")
    }

    private func parseSimulatorRuntime(_ runtime: String?) -> (platform: String, label: String) {
        guard let runtime, !runtime.isEmpty else { return ("Simulator", "") }
        let raw = runtime.components(separatedBy: "SimRuntime.").last ?? runtime
        let parts = raw.split(separator: "-").map(String.init)
        guard let first = parts.first else { return ("Simulator", raw) }
        let platform = switch first.lowercased() {
        case "ios": "iOS"
        case "watchos": "watchOS"
        case "xros", "visionos": "visionOS"
        case "tvos": "tvOS"
        default: first
        }
        let version = parts.dropFirst().joined(separator: ".")
        let label = version.isEmpty ? platform : "\(platform) \(version)"
        return (platform, label)
    }

    private func vmAndModelRule(for url: URL) -> Rule? {
        let path = url.path
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let parentURL = url.deletingLastPathComponent()
        let parentPath = parentURL.path
        let parentName = parentURL.lastPathComponent
        let grandparentPath = parentURL.deletingLastPathComponent().path

        // Apple CoreSimulator Devices (iOS, watchOS, visionOS, tvOS)
        if parentPath.hasSuffix("/Library/Developer/CoreSimulator/Devices"), UUID(uuidString: name) != nil {
            let plistURL = url.appendingPathComponent("device.plist")
            let dict = NSDictionary(contentsOf: plistURL) as? [String: Any]
            let deviceName = dict?["name"] as? String ?? "Simulator \(name.prefix(8))"
            let runtimeID = dict?["runtime"] as? String
            let (platform, runtimeLabel) = parseSimulatorRuntime(runtimeID)
            let displayTitle = runtimeLabel.isEmpty ? "\(deviceName) Simulator" : "\(deviceName) (\(runtimeLabel))"
            return Rule(path: "", title: displayTitle, ecosystem: "Xcode Simulator (\(platform))", category: .vms,
                        uninstallCommand: "xcrun simctl delete \(Finding.quote(name))",
                        explanation: "Simulated \(platform) device storage (\(deviceName)), including installed apps, app data, and system logs.",
                        consequence: "Deleting removes this \(platform) simulator device and all data inside it. You can recreate the simulator in Xcode at any time.")
        }

        // CoreSimulator Runtime profiles & volumes
        if parentPath == "/Library/Developer/CoreSimulator/Profiles/Runtimes" || ext == "simruntime" {
            let cleanName = name.replacingOccurrences(of: ".simruntime", with: "")
            return Rule(path: "", title: "\(cleanName) Simulator Runtime", ecosystem: "Xcode Simulator Runtime", category: .vms,
                        uninstallCommand: "sudo /bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Installed Xcode Simulator OS runtime bundle (\(cleanName)).",
                        consequence: "Removing this runtime prevents booting simulators of this OS version until re-downloaded in Xcode.")
        }
        if parentPath == "/Library/Developer/CoreSimulator/Volumes" {
            return Rule(path: "", title: "Simulator Runtime Volume (\(name))", ecosystem: "Xcode Simulator Runtime", category: .vms,
                        uninstallCommand: "xcrun simctl runtime delete \(Finding.quote(name))",
                        explanation: "Mounted Apple Simulator runtime disk image volume (\(name)) for iOS, watchOS, visionOS, or tvOS.",
                        consequence: "Deleting unmounts and removes this simulator OS runtime image.")
        }
        if grandparentPath.hasSuffix("/Library/Developer/CoreSimulator/Caches/dyld") {
            let (platform, label) = parseSimulatorRuntime(name)
            let display = label.isEmpty ? name : label
            return Rule(path: "", title: "Simulator dyld cache (\(display))", ecosystem: "Xcode Simulator (\(platform))", category: .caches,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Shared dyld library cache built for \(display) simulators.",
                        consequence: "Safe to remove when simulators are closed; Xcode will rebuild the cache on next simulator boot.")
        }

        // UTM Virtual Machines (.utm bundles anywhere or in com.utmapp.UTM)
        if ext == "utm" {
            let configURL = url.appendingPathComponent("config.plist")
            let config = NSDictionary(contentsOf: configURL) as? [String: Any]
            let info = config?["Information"] as? [String: Any]
            let vmName = info?["Name"] as? String ?? url.deletingPathExtension().lastPathComponent
            return Rule(path: "", title: "\(vmName) (UTM VM)", ecosystem: "UTM Virtual Machine", category: .vms,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "UTM virtual machine bundle (\(vmName)) containing virtual disk images and guest OS state.",
                        consequence: "Deleting permanently removes the \(vmName) virtual machine and all data stored on its virtual disks.")
        }

        // Parallels (.pvm) & VMware Fusion (.vmwarevm) Virtual Machines
        if ext == "pvm" {
            let vmName = url.deletingPathExtension().lastPathComponent
            return Rule(path: "", title: "\(vmName) (Parallels VM)", ecosystem: "Parallels Desktop", category: .vms,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Parallels Desktop virtual machine bundle (\(vmName)).",
                        consequence: "Deleting permanently removes this Parallels virtual machine and its virtual hard disks.")
        }
        if ext == "vmwarevm" {
            let vmName = url.deletingPathExtension().lastPathComponent
            return Rule(path: "", title: "\(vmName) (VMware VM)", ecosystem: "VMware Fusion", category: .vms,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "VMware Fusion virtual machine bundle (\(vmName)).",
                        consequence: "Deleting permanently removes this VMware virtual machine and its virtual hard disks.")
        }

        // Android Emulator AVDs (~/.android/avd/<name>.avd)
        if parentPath.hasSuffix("/.android/avd"), ext == "avd" {
            let avdName = url.deletingPathExtension().lastPathComponent
            let iniPath = parentURL.appendingPathComponent(avdName + ".ini").path
            return Rule(path: "", title: "\(avdName) (Android Emulator)", ecosystem: "Android Emulator", category: .vms,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path)) \(Finding.quote(iniPath))",
                        explanation: "Android Virtual Device (\(avdName)) disk images and snapshots.",
                        consequence: "Deleting removes this Android emulator instance and all data inside it.")
        }

        // Lima, Colima, Tart, and Vagrant VMs
        if parentPath.hasSuffix("/.lima"), !name.hasPrefix("_"), !name.hasPrefix(".") {
            return Rule(path: "", title: "\(name) (Lima VM)", ecosystem: "Lima VM", category: .vms,
                        uninstallCommand: "limactl delete -f \(Finding.quote(name))",
                        explanation: "Linux virtual machine instance (\(name)) managed by Lima.",
                        consequence: "Deleting destroys the \(name) Linux VM and its virtual disk.")
        }
        if parentPath.hasSuffix("/.colima/_lima") {
            return Rule(path: "", title: "\(name) (Colima VM)", ecosystem: "Colima VM", category: .vms,
                        uninstallCommand: "colima delete -f \(Finding.quote(name))",
                        explanation: "Container runtime virtual machine (\(name)) managed by Colima.",
                        consequence: "Deleting destroys the Colima VM and all container volumes stored inside it.")
        }
        if parentPath.hasSuffix("/.tart/vms") {
            return Rule(path: "", title: "\(name) (Tart VM)", ecosystem: "Tart VM", category: .vms,
                        uninstallCommand: "tart delete \(Finding.quote(name))",
                        explanation: "macOS or Linux virtual machine image (\(name)) managed by Tart.",
                        consequence: "Deleting removes the \(name) VM image from Tart.")
        }
        if parentPath.hasSuffix("/.vagrant.d/boxes") {
            return Rule(path: "", title: "\(name) (Vagrant Box)", ecosystem: "Vagrant VM", category: .vms,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Cached Vagrant virtual machine base box (\(name)).",
                        consequence: "Removing deletes this base box; running VMs are separate.")
        }

        // LM Studio local LLMs: ~/.lmstudio/models/<publisher>/<model> or ~/.cache/lm-studio/models/<publisher>/<model>
        if grandparentPath.hasSuffix("/.lmstudio/models") || grandparentPath.hasSuffix("/.cache/lm-studio/models"),
           !parentName.hasPrefix("."), !name.hasPrefix(".")
        {
            let modelID = "\(parentName)/\(name)"
            return Rule(path: "", title: "\(modelID) (LM Studio)", ecosystem: "LM Studio LLM", category: .vms,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Local large language model weights (\(modelID)) stored by LM Studio.",
                        consequence: "Removing deletes the local GGUF/MLX model files from LM Studio.")
        }

        // Hugging Face Hub cached models: ~/.cache/huggingface/hub/models--<org>--<repo>
        if parentPath.hasSuffix("/.cache/huggingface/hub"), name.hasPrefix("models--") {
            let parts = name.dropFirst("models--".count).components(separatedBy: "--")
            let modelID = parts.joined(separator: "/")
            return Rule(path: "", title: "\(modelID) (Hugging Face)", ecosystem: "Hugging Face LLM", category: .vms,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Local model weights and snapshots (\(modelID)) cached in Hugging Face Hub.",
                        consequence: "Removing deletes cached weights for \(modelID). Tools using it will re-download if needed.")
        }

        // Jan AI local LLMs: ~/jan/models/<model> or ~/Library/Application Support/Jan/data/models/<model>
        if parentPath.hasSuffix("/jan/models") || parentPath.hasSuffix("/Jan/data/models"), !name.hasPrefix(".") {
            return Rule(path: "", title: "\(name) (Jan AI)", ecosystem: "Jan AI LLM", category: .vms,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Local language model (\(name)) downloaded in Jan AI.",
                        consequence: "Removing deletes this local model from Jan AI.")
        }

        return nil
    }

    private func displayLanguageName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "node", "nodejs": "Node.js"
        case "python", "cpython": "Python"
        case "ruby": "Ruby"
        case "rust": "Rust"
        case "go", "golang": "Go"
        case "java": "Java"
        case "kotlin": "Kotlin"
        case "gradle": "Gradle"
        case "maven": "Maven"
        case "scala": "Scala"
        case "swift": "Swift"
        case "flutter": "Flutter"
        case "dart": "Dart"
        case "deno": "Deno"
        case "bun": "Bun"
        case "zig": "Zig"
        case "php": "PHP"
        case "elixir": "Elixir"
        case "erlang": "Erlang"
        default: raw
        }
    }

    private func languageVersionRule(for url: URL) -> Rule? {
        let path = url.path
        let name = url.lastPathComponent
        let parentURL = url.deletingLastPathComponent()
        let parentPath = parentURL.path
        let parentName = parentURL.lastPathComponent
        let grandparentPath = parentURL.deletingLastPathComponent().path

        // mise: ~/.local/share/mise/installs/<tool>/<version> or ~/Library/Application Support/mise/installs/<tool>/<version>
        if grandparentPath.hasSuffix("/mise/installs") {
            let lang = displayLanguageName(parentName)
            let spec = "\(parentName)@\(name)"
            return Rule(path: "", title: "\(lang) \(name)", ecosystem: "mise (\(lang))", category: .tools,
                        uninstallCommand: "mise uninstall \(Finding.quote(spec))",
                        explanation: "Installed \(lang) version \(name) managed by mise.",
                        consequence: "Uninstalling removes \(spec) from mise. Projects pinned to this version will need to reinstall it or use another version.")
        }

        // asdf: ~/.asdf/installs/<tool>/<version>
        if grandparentPath.hasSuffix("/.asdf/installs") {
            let lang = displayLanguageName(parentName)
            return Rule(path: "", title: "\(lang) \(name)", ecosystem: "asdf (\(lang))", category: .tools,
                        uninstallCommand: "asdf uninstall \(Finding.quote(parentName)) \(Finding.quote(name))",
                        explanation: "Installed \(lang) version \(name) managed by asdf.",
                        consequence: "Uninstalling removes \(parentName) \(name) from asdf. Projects referencing it in .tool-versions will require reinstallation.")
        }

        // nvm: ~/.nvm/versions/node/<version> or ~/.nvm/versions/io.js/<version>
        if parentPath.hasSuffix("/.nvm/versions/node") || parentPath.hasSuffix("/.nvm/versions/io.js") {
            return Rule(path: "", title: "Node.js \(name)", ecosystem: "nvm (Node.js)", category: .tools,
                        uninstallCommand: "nvm uninstall \(Finding.quote(name))",
                        explanation: "Installed Node.js runtime \(name) and its global npm packages managed by nvm.",
                        consequence: "Uninstalling removes Node.js \(name) and any global npm packages installed under this version.")
        }

        // fnm: ~/Library/Application Support/fnm/node-versions/<version>, ~/.local/share/fnm/node-versions/<version>, ~/.fnm/node-versions/<version>
        if parentPath.hasSuffix("/fnm/node-versions") || parentPath.hasSuffix("/.fnm/node-versions") {
            return Rule(path: "", title: "Node.js \(name)", ecosystem: "fnm (Node.js)", category: .tools,
                        uninstallCommand: "fnm uninstall \(Finding.quote(name))",
                        explanation: "Installed Node.js runtime \(name) managed by Fast Node Manager (fnm).",
                        consequence: "Uninstalling removes Node.js \(name) from fnm.")
        }

        // n (Node version manager): /usr/local/n/versions/node/<version>
        if parentPath.hasSuffix("/n/versions/node") {
            return Rule(path: "", title: "Node.js \(name)", ecosystem: "n (Node.js)", category: .tools,
                        uninstallCommand: "n rm \(Finding.quote(name))",
                        explanation: "Installed Node.js runtime \(name) managed by n.",
                        consequence: "Uninstalling removes Node.js \(name) from n.")
        }

        // Volta: ~/.volta/tools/image/<runtime>/<version>
        if grandparentPath.hasSuffix("/.volta/tools/image"), ["node", "npm", "yarn", "pnpm"].contains(parentName) {
            let lang = displayLanguageName(parentName)
            return Rule(path: "", title: "\(lang) \(name)", ecosystem: "Volta (\(lang))", category: .tools,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Installed \(lang) \(name) toolchain image managed by Volta.",
                        consequence: "Removing this directory deletes the cached \(lang) \(name) runtime from Volta.")
        }

        // pyenv: ~/.pyenv/versions/<version>
        if parentPath.hasSuffix("/.pyenv/versions") {
            return Rule(path: "", title: "Python \(name)", ecosystem: "pyenv (Python)", category: .tools,
                        uninstallCommand: "pyenv uninstall -f \(Finding.quote(name))",
                        explanation: "Installed Python version or virtualenv (\(name)) managed by pyenv.",
                        consequence: "Uninstalling removes Python \(name) and all site-packages installed in it.")
        }

        // uv Python installations: ~/.local/share/uv/python/<version> or ~/Library/Application Support/uv/python/<version>
        if parentPath.hasSuffix("/uv/python") {
            return Rule(path: "", title: "Python \(name)", ecosystem: "uv (Python)", category: .tools,
                        uninstallCommand: "uv python uninstall \(Finding.quote(name))",
                        explanation: "Standalone Python toolchain (\(name)) managed by uv.",
                        consequence: "Uninstalling removes this uv-managed Python version. Virtual environments linking to it will require reinstallation.")
        }

        // Conda / Miniconda / Miniforge / Anaconda environments
        if parentPath.hasSuffix("/miniconda3/envs") || parentPath.hasSuffix("/anaconda3/envs")
            || parentPath.hasSuffix("/miniforge3/envs") || parentPath.hasSuffix("/mambaforge/envs")
            || parentPath.hasSuffix("/.conda/envs")
        {
            return Rule(path: "", title: "Conda env: \(name)", ecosystem: "Conda (Python)", category: .tools,
                        uninstallCommand: "conda env remove -n \(Finding.quote(name))",
                        explanation: "Isolated Conda environment (\(name)) with its Python interpreter and native packages.",
                        consequence: "Removing this environment deletes all packages installed inside \(name).")
        }

        // Python.framework per-version in /Library/Frameworks/Python.framework/Versions/<version>
        if parentPath == "/Library/Frameworks/Python.framework/Versions" || parentPath.hasSuffix("/Python.framework/Versions"),
           name != "Current"
        {
            return Rule(path: "", title: "Python \(name) (Framework)", ecosystem: "Python", category: .tools,
                        uninstallCommand: "sudo /bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "System-wide Python \(name) framework installation in /Library/Frameworks.",
                        consequence: "Removing this deletes Python \(name) and its framework site-packages.")
        }

        // User Python packages per-version in ~/Library/Python/<version>
        if parentPath.hasSuffix("/Library/Python") {
            return Rule(path: "", title: "Python \(name) user packages", ecosystem: "Python", category: .tools,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "User-level pip packages installed for Python \(name).",
                        consequence: "Removing this deletes user-scoped Python \(name) packages and scripts.")
        }

        // rbenv: ~/.rbenv/versions/<version>
        if parentPath.hasSuffix("/.rbenv/versions") {
            return Rule(path: "", title: "Ruby \(name)", ecosystem: "rbenv (Ruby)", category: .tools,
                        uninstallCommand: "rbenv uninstall -f \(Finding.quote(name))",
                        explanation: "Installed Ruby version \(name) and its gems managed by rbenv.",
                        consequence: "Uninstalling removes Ruby \(name) and all gems installed under it.")
        }

        // RVM: ~/.rvm/rubies/<version>
        if parentPath.hasSuffix("/.rvm/rubies") {
            return Rule(path: "", title: "Ruby \(name)", ecosystem: "RVM (Ruby)", category: .tools,
                        uninstallCommand: "rvm remove \(Finding.quote(name))",
                        explanation: "Installed Ruby runtime (\(name)) managed by RVM.",
                        consequence: "Uninstalling removes Ruby \(name) and its associated gemsets.")
        }

        // chruby / ruby-install: ~/.rubies/<version>
        if parentPath.hasSuffix("/.rubies") {
            return Rule(path: "", title: "Ruby \(name)", ecosystem: "chruby (Ruby)", category: .tools,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Installed Ruby runtime (\(name)) in ~/.rubies.",
                        consequence: "Removing this deletes Ruby \(name) and its gems.")
        }

        // rustup toolchains: ~/.rustup/toolchains/<toolchain>
        if parentPath.hasSuffix("/.rustup/toolchains") {
            return Rule(path: "", title: "Rust \(name)", ecosystem: "rustup (Rust)", category: .tools,
                        uninstallCommand: "rustup toolchain uninstall \(Finding.quote(name))",
                        explanation: "Installed Rust compiler toolchain (\(name)) and components managed by rustup.",
                        consequence: "Uninstalling removes the \(name) toolchain from rustup.")
        }

        // SDKMAN!: ~/.sdkman/candidates/<candidate>/<version>
        if grandparentPath.hasSuffix("/.sdkman/candidates"), name != "current" {
            let lang = displayLanguageName(parentName)
            return Rule(path: "", title: "\(lang) \(name)", ecosystem: "SDKMAN (\(lang))", category: .tools,
                        uninstallCommand: "sdk uninstall \(Finding.quote(parentName)) \(Finding.quote(name))",
                        explanation: "Installed \(lang) version \(name) managed by SDKMAN!.",
                        consequence: "Uninstalling removes \(parentName) \(name) from SDKMAN!.")
        }

        // Java JDK bundles: /Library/Java/JavaVirtualMachines/<jdk> or ~/Library/Java/JavaVirtualMachines/<jdk>
        if parentPath.hasSuffix("/Library/Java/JavaVirtualMachines") {
            let needsSudo = path.hasPrefix("/Library/")
            let jdkName = name.replacingOccurrences(of: ".jdk", with: "")
            return Rule(path: "", title: "JDK \(jdkName)", ecosystem: "Java JDK", category: .tools,
                        uninstallCommand: "\(needsSudo ? "sudo " : "")/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Installed Java Development Kit bundle (\(name)).",
                        consequence: "Removing this deletes the \(jdkName) JDK bundle.")
        }

        // goenv & Go SDKs: ~/.goenv/versions/<version> or ~/sdk/go<version>
        if parentPath.hasSuffix("/.goenv/versions") {
            return Rule(path: "", title: "Go \(name)", ecosystem: "goenv (Go)", category: .tools,
                        uninstallCommand: "goenv uninstall -f \(Finding.quote(name))",
                        explanation: "Installed Go toolchain \(name) managed by goenv.",
                        consequence: "Uninstalling removes Go \(name) from goenv.")
        }
        if parentPath.hasSuffix("/sdk"), name.hasPrefix("go"), name.count > 2 {
            let ver = String(name.dropFirst(2))
            return Rule(path: "", title: "Go \(ver)", ecosystem: "Go SDK", category: .tools,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Downloaded Go SDK version \(ver) in ~/sdk.",
                        consequence: "Removing this deletes the Go \(ver) SDK.")
        }

        // fvm (Flutter Version Management): ~/fvm/versions/<version> or ~/.fvm/versions/<version>
        if parentPath.hasSuffix("/fvm/versions") || parentPath.hasSuffix("/.fvm/versions") {
            return Rule(path: "", title: "Flutter \(name)", ecosystem: "fvm (Flutter)", category: .tools,
                        uninstallCommand: "fvm remove \(Finding.quote(name))",
                        explanation: "Installed Flutter SDK version \(name) managed by fvm.",
                        consequence: "Uninstalling removes Flutter \(name) from fvm.")
        }

        // swiftenv & swiftly: ~/.swiftenv/versions/<version>, ~/.local/share/swiftly/toolchains/<version>
        if parentPath.hasSuffix("/.swiftenv/versions") {
            return Rule(path: "", title: "Swift \(name)", ecosystem: "swiftenv (Swift)", category: .tools,
                        uninstallCommand: "swiftenv uninstall \(Finding.quote(name))",
                        explanation: "Installed Swift toolchain \(name) managed by swiftenv.",
                        consequence: "Uninstalling removes Swift \(name) from swiftenv.")
        }
        if parentPath.hasSuffix("/swiftly/toolchains") {
            return Rule(path: "", title: "Swift \(name)", ecosystem: "swiftly (Swift)", category: .tools,
                        uninstallCommand: "swiftly uninstall \(Finding.quote(name))",
                        explanation: "Installed Swift toolchain \(name) managed by swiftly.",
                        consequence: "Uninstalling removes Swift \(name) from swiftly.")
        }

        // phpenv: ~/.phpenv/versions/<version>
        if parentPath.hasSuffix("/.phpenv/versions") {
            return Rule(path: "", title: "PHP \(name)", ecosystem: "phpenv (PHP)", category: .tools,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path)) && phpenv rehash",
                        explanation: "Installed PHP version \(name) managed by phpenv.",
                        consequence: "Removing this deletes PHP \(name) from phpenv.")
        }

        return nil
    }

    private func cliRule(for url: URL) -> Rule? {
        let path = url.path
        let name = url.lastPathComponent
        let parentPath = url.deletingLastPathComponent().path

        // Homebrew Cellar per-formula CLI storage
        if parentPath == "/opt/homebrew/Cellar" || parentPath == "/usr/local/Cellar"
            || parentPath.hasSuffix("/homebrew/Cellar") || parentPath.hasSuffix("/local/Cellar")
        {
            return Rule(path: "", title: "\(name) CLI", ecosystem: "Homebrew CLI", category: .tools,
                        uninstallCommand: "brew uninstall \(Finding.quote(name))",
                        explanation: "Installed Homebrew formula (\(name)) and its versioned files in the Cellar.",
                        consequence: "Uninstalling removes the \(name) CLI unless other formulae depend on it. Run brew uses --installed \(Finding.quote(name)) to check dependents first.")
        }

        // Homebrew Caskroom per-cask CLI/tool storage
        if parentPath == "/opt/homebrew/Caskroom" || parentPath == "/usr/local/Caskroom"
            || parentPath.hasSuffix("/homebrew/Caskroom") || parentPath.hasSuffix("/local/Caskroom")
        {
            return Rule(path: "", title: "\(name) (Homebrew Cask)", ecosystem: "Homebrew Cask", category: .tools,
                        uninstallCommand: "brew uninstall --cask \(Finding.quote(name))",
                        explanation: "Staged Homebrew Cask installation files and metadata for \(name).",
                        consequence: "Uninstalling removes \(name) and its linked command-line binaries.")
        }

        // pipx isolated CLI environments
        if parentPath.hasSuffix("/.local/pipx/venvs") || parentPath.hasSuffix("/.local/share/pipx/venvs") {
            return Rule(path: "", title: "\(name) CLI", ecosystem: "pipx CLI", category: .tools,
                        uninstallCommand: "pipx uninstall \(Finding.quote(name))",
                        explanation: "Isolated Python virtual environment for the \(name) CLI installed via pipx.",
                        consequence: "Uninstalling removes the \(name) command and its dedicated virtual environment.")
        }

        // uv tool isolated CLI environments
        if parentPath.hasSuffix("/.local/share/uv/tools") {
            return Rule(path: "", title: "\(name) CLI", ecosystem: "uv tool CLI", category: .tools,
                        uninstallCommand: "uv tool uninstall \(Finding.quote(name))",
                        explanation: "Isolated Python environment for the \(name) CLI installed via uv tool.",
                        consequence: "Uninstalling removes the \(name) executable and its tool environment.")
        }

        // Global npm CLI packages in ~/.npm-global/lib/node_modules
        if parentPath.hasSuffix("/.npm-global/lib/node_modules"), !name.hasPrefix(".") {
            return Rule(path: "", title: "\(name) CLI", ecosystem: "npm global CLI", category: .tools,
                        uninstallCommand: "npm uninstall -g \(Finding.quote(name))",
                        explanation: "Globally installed npm CLI package (\(name)).",
                        consequence: "Uninstalling removes the global \(name) command.")
        }

        // AWS CLI v2 standalone installation
        if path == "/usr/local/aws-cli" || path.hasSuffix("/aws-cli/v2") {
            return Rule(path: "", title: "AWS CLI v2", ecosystem: "AWS CLI", category: .tools,
                        uninstallCommand: "sudo /bin/rm -rf -- \(Finding.quote(path)) /usr/local/bin/aws /usr/local/bin/aws_completer",
                        explanation: "Standalone AWS Command Line Interface v2 installation.",
                        consequence: "Uninstalling removes the aws and aws_completer binaries. Configuration in ~/.aws is preserved.")
        }

        // Google Cloud SDK (gcloud CLI)
        if name == "google-cloud-sdk" {
            return Rule(path: "", title: "Google Cloud CLI (gcloud)", ecosystem: "Google Cloud CLI", category: .tools,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path)) ~/.config/gcloud",
                        explanation: "Google Cloud SDK installation including gcloud, gsutil, and bq CLI tools.",
                        consequence: "Removing this deletes the gcloud CLI components. Also remove its PATH initialization lines from your shell profile.")
        }
        if path.hasSuffix("/.config/gcloud") {
            return Rule(path: "", title: "Google Cloud CLI config & logs", ecosystem: "Google Cloud CLI", category: .tools,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Google Cloud CLI credentials, active configurations, and command logs.",
                        consequence: "Removing this clears local gcloud auth sessions and configurations. Run gcloud auth login to re-authenticate if still using gcloud.")
        }

        // Azure CLI data & extensions
        if path.hasSuffix("/.azure") {
            return Rule(path: "", title: "Azure CLI data & extensions", ecosystem: "Azure CLI", category: .tools,
                        uninstallCommand: "brew uninstall azure-cli && /bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Azure CLI (az) installed extensions, token cache, and telemetry logs.",
                        consequence: "Uninstalling removes the Azure CLI and clears local login state and extensions.")
        }

        // GitHub CLI extensions & data
        if path.hasSuffix("/.local/share/gh") {
            return Rule(path: "", title: "GitHub CLI extensions", ecosystem: "GitHub CLI", category: .tools,
                        uninstallCommand: "brew uninstall gh && /bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Installed GitHub CLI (gh) extensions and local state.",
                        consequence: "Removing this deletes installed gh extensions.")
        }

        // Standalone CLI runtimes (Bun, Deno, Flyctl, Heroku)
        if path.hasSuffix("/.bun") {
            return Rule(path: "", title: "Bun CLI & package cache", ecosystem: "Bun CLI", category: .tools,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Bun CLI installation, global packages, and install cache.",
                        consequence: "Removing ~/.bun uninstalls the standalone Bun CLI and its global packages.")
        }
        if path.hasSuffix("/.deno") {
            return Rule(path: "", title: "Deno CLI", ecosystem: "Deno CLI", category: .tools,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Deno CLI binary and globally installed scripts.",
                        consequence: "Removing ~/.deno uninstalls the standalone Deno CLI.")
        }
        if path.hasSuffix("/.fly") {
            return Rule(path: "", title: "Fly.io CLI (flyctl)", ecosystem: "Fly.io CLI", category: .tools,
                        uninstallCommand: "/bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Fly.io command-line interface (flyctl) binary and state.",
                        consequence: "Removing ~/.fly uninstalls flyctl.")
        }
        if path.hasSuffix("/.local/share/heroku") {
            return Rule(path: "", title: "Heroku CLI runtime & plugins", ecosystem: "Heroku CLI", category: .tools,
                        uninstallCommand: "brew uninstall heroku && /bin/rm -rf -- \(Finding.quote(path))",
                        explanation: "Heroku CLI embedded Node runtime, plugins, and autoupdate files.",
                        consequence: "Uninstalling removes the Heroku CLI and all installed Heroku plugins.")
        }

        return nil
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
                if url.path.hasSuffix("/.ollama/models") {
                    walker.skipDescendants()
                    try recordOllamaModels(at: url, measured: &measured, report: &report)
                    await progress(ScanProgress(path: url.path, directoriesVisited: report.directoriesVisited, findingsCount: report.findings.count))
                    lastUpdate = .now
                    continue
                }
                if isApplicationBundle(url) {
                    walker.skipDescendants()
                    try recordApplicationBundle(url, root: root, measured: &measured, report: &report)
                    await progress(ScanProgress(path: url.path, directoriesVisited: report.directoriesVisited, findingsCount: report.findings.count))
                    lastUpdate = .now
                    continue
                }
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
        let projectName = url.deletingLastPathComponent().lastPathComponent
        switch url.lastPathComponent {
        case "node_modules":
            return Rule(path: "", title: "\(projectName) dependencies", ecosystem: "Node.js", category: .dependencies,
                        groupKey: "group:node_modules", groupTitle: "node_modules folders")
        case ".venv", "venv":
            return manager.fileExists(atPath: url.appendingPathComponent("pyvenv.cfg").path)
                ? Rule(path: "", title: "\(projectName) virtual environment", ecosystem: "Python", category: .dependencies,
                       groupKey: "group:python_venv", groupTitle: "Python virtual environments (.venv)")
                : nil
        case "Pods":
            return manager.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("Podfile").path)
                ? Rule(path: "", title: "\(projectName) Pods", ecosystem: "CocoaPods", category: .dependencies,
                       groupKey: "group:cocoapods_pods", groupTitle: "CocoaPods Pods folders")
                : nil
        case ".terraform":
            return Rule(path: "", title: "\(projectName) Terraform data", ecosystem: "Terraform", category: .dependencies,
                        command: "/bin/ls -lah \(Finding.quote(url.path))",
                        groupKey: "group:terraform", groupTitle: "Terraform working directories (.terraform)")
        case ".build":
            return manager.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("Package.swift").path)
                ? Rule(path: "", title: "\(projectName) Swift build", ecosystem: "Swift",
                       groupKey: "group:swift_build", groupTitle: "Swift package build outputs (.build)")
                : nil
        case "target":
            return manager.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("Cargo.toml").path)
                ? Rule(path: "", title: "\(projectName) Rust target", ecosystem: "Rust",
                       groupKey: "group:rust_target", groupTitle: "Rust Cargo build outputs (target)")
                : nil
        case ".next":
            return manager.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("package.json").path)
                ? Rule(path: "", title: "\(projectName) Next.js build", ecosystem: "Next.js",
                       groupKey: "group:nextjs_build", groupTitle: "Next.js build caches (.next)")
                : nil
        default:
            return nil
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
        let isTool = rule.category == .tools || rule.category == .vms
        let isTerraform = rule.ecosystem == "Terraform"
        let explanation: LocalizedStringResource = rule.explanation ?? (isTool
            ? "Installed tools, virtual machines, or local model data. Size alone does not show whether this is still needed."
            : "Generated files associated with this tool or project. Review the folder before removing it.")
        let consequence: LocalizedStringResource = rule.consequence ?? (isTool
            ? "Review versions and usage with the owning tool. Container or VM storage may include databases and disks. Do not delete the storage directory directly."
            : isTerraform
            ? "Review this directory for local state, workspaces, and custom files first. Back up any state. Removing it requires terraform init again; root .tfstate files are outside this finding."
            : rule.category == .dependencies
            ? "Dependencies must be reinstalled before using this project. Preserve manifests and lockfiles, and check for locally modified or untracked files."
            : "Close related builds and tools first. Files may be downloaded or rebuilt later. Locally modified files would be lost.")
        let command = rule.command ?? (isTool && rule.uninstallCommand == nil ? "/bin/ls -lah \(Finding.quote(path))" : nil)
        report.findings.append(Finding(url: url, title: rule.title, ecosystem: rule.ecosystem, category: rule.category, bytes: bytes,
                                       modified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                                       explanation: explanation, consequence: consequence,
                                       uninstallCommand: rule.uninstallCommand, inspectionCommand: command,
                                       groupKey: rule.groupKey, groupTitle: rule.groupTitle, incomplete: incomplete,
                                       volumeURL: try? url.resourceValues(forKeys: [.volumeURLKey]).volume))
    }

    private func isApplicationBundle(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "app", !url.path.hasPrefix("/System/") else { return false }
        let parentPath = url.deletingLastPathComponent().path
        return parentPath == "/Applications" || parentPath.hasSuffix("/Applications")
    }

    private func recordApplicationBundle(_ appURL: URL, root: URL, measured: inout Set<String>, report: inout ScanReport) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let plist = NSDictionary(contentsOf: infoURL) as? [String: Any]
        let bundleID = (plist?["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderAppName = appURL.deletingPathExtension().lastPathComponent
        let displayName = (plist?["CFBundleDisplayName"] as? String) ?? (plist?["CFBundleName"] as? String)
        let appName = (displayName?.isEmpty == false) ? displayName! : folderAppName
        let groupKey = "app:\(bundleID ?? appURL.standardizedFileURL.path)"
        let groupTitle = "\(appName)"
        let needsSudo = appURL.path.hasPrefix("/Applications/")
        let explanation: LocalizedStringResource = "Application bundle (\(folderAppName).app) grouped with its Application Support, Caches, Containers, and Saved State folders."
        let consequence: LocalizedStringResource = "Check both the .app bundle and support folders to completely uninstall \(appName), or uncheck the .app bundle to clear only its support and cache folders."

        let appRule = Rule(path: "",
                           title: "\(folderAppName).app (Application)",
                           ecosystem: "Application & Support",
                           category: .apps,
                           uninstallCommand: "\(needsSudo ? "sudo " : "")/bin/rm -rf -- \(Finding.quote(appURL.path))",
                           groupKey: groupKey,
                           groupTitle: groupTitle,
                           explanation: explanation,
                           consequence: consequence)
        try record(appURL, rule: appRule, measured: &measured, report: &report)

        var userHomes: [URL] = [manager.homeDirectoryForCurrentUser]
        let usersDir = root.path == "/" ? URL(fileURLWithPath: "/Users", isDirectory: true) : root.appendingPathComponent("Users", isDirectory: true)
        if let entries = try? manager.contentsOfDirectory(at: usersDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for entry in entries where entry.lastPathComponent != "Shared" {
                if !userHomes.contains(where: { $0.standardizedFileURL.path == entry.standardizedFileURL.path }) {
                    userHomes.append(entry)
                }
            }
        }

        var candidates: [(url: URL, label: String)] = []
        let sysLib = root.path == "/" ? URL(fileURLWithPath: "/Library", isDirectory: true) : root.appendingPathComponent("Library", isDirectory: true)
        candidates.append((sysLib.appendingPathComponent("Application Support/\(folderAppName)", isDirectory: true), "System Application Support"))
        if let bundleID, !bundleID.isEmpty {
            candidates.append((sysLib.appendingPathComponent("Application Support/\(bundleID)", isDirectory: true), "System Application Support"))
        }

        for home in userHomes {
            let lib = home.appendingPathComponent("Library", isDirectory: true)
            candidates.append((lib.appendingPathComponent("Application Support/\(folderAppName)", isDirectory: true), "Application Support"))
            if appName != folderAppName {
                candidates.append((lib.appendingPathComponent("Application Support/\(appName)", isDirectory: true), "Application Support"))
            }
            candidates.append((lib.appendingPathComponent("Caches/\(folderAppName)", isDirectory: true), "Cache"))
            candidates.append((lib.appendingPathComponent("Logs/\(folderAppName)", isDirectory: true), "Logs"))
            if let bundleID, !bundleID.isEmpty {
                candidates.append((lib.appendingPathComponent("Application Support/\(bundleID)", isDirectory: true), "Application Support"))
                if bundleID == "com.microsoft.VSCode" {
                    candidates.append((lib.appendingPathComponent("Application Support/Code", isDirectory: true), "Application Support"))
                } else if bundleID == "com.google.Chrome" {
                    candidates.append((lib.appendingPathComponent("Application Support/Google/Chrome", isDirectory: true), "Application Support"))
                }
                candidates.append((lib.appendingPathComponent("Caches/\(bundleID)", isDirectory: true), "Cache"))
                candidates.append((lib.appendingPathComponent("Containers/\(bundleID)", isDirectory: true), "Sandbox Container"))
                candidates.append((lib.appendingPathComponent("Saved Application State/\(bundleID).savedState", isDirectory: true), "Saved State"))
                candidates.append((lib.appendingPathComponent("HTTPStorages/\(bundleID)", isDirectory: true), "HTTP Storage"))
                candidates.append((lib.appendingPathComponent("WebKit/\(bundleID)", isDirectory: true), "WebKit Data"))
                candidates.append((lib.appendingPathComponent("Logs/\(bundleID)", isDirectory: true), "Logs"))
            }
        }

        var seenPaths: Set<String> = []
        for candidate in candidates {
            let stdPath = candidate.url.standardizedFileURL.path
            guard seenPaths.insert(stdPath).inserted else { continue }
            guard let values = try? candidate.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true
            else { continue }

            let supportTitle = "\(appName) — \(candidate.label)"
            if let existingIndex = report.findings.firstIndex(where: { $0.id == stdPath }) {
                let old = report.findings[existingIndex]
                report.findings[existingIndex] = Finding(url: old.url,
                                                         title: supportTitle,
                                                         ecosystem: "Application & Support",
                                                         category: .apps,
                                                         bytes: old.bytes,
                                                         modified: old.modified,
                                                         explanation: explanation,
                                                         consequence: consequence,
                                                         uninstallCommand: old.uninstallCommand,
                                                         inspectionCommand: nil,
                                                         groupKey: groupKey,
                                                         groupTitle: groupTitle,
                                                         incomplete: old.incomplete,
                                                         measurementIsStale: old.measurementIsStale,
                                                         volumeURL: old.volumeURL)
            } else {
                let supportNeedsSudo = stdPath.hasPrefix("/Library/")
                let supportRule = Rule(path: "",
                                       title: supportTitle,
                                       ecosystem: "Application & Support",
                                       category: .apps,
                                       uninstallCommand: "\(supportNeedsSudo ? "sudo " : "")/bin/rm -rf -- \(Finding.quote(stdPath))",
                                       groupKey: groupKey,
                                       groupTitle: groupTitle,
                                       explanation: explanation,
                                       consequence: consequence)
                try record(candidate.url, rule: supportRule, measured: &measured, report: &report)
            }
        }
    }

    private func recordOllamaModels(at modelsDir: URL, measured: inout Set<String>, report: inout ScanReport) throws {
        let manifestsRoot = modelsDir.appendingPathComponent("manifests", isDirectory: true)
        var recordedAny = false
        if let walker = manager.enumerator(at: manifestsRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let fileURL as URL in walker {
                try Task.checkCancellation()
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                guard values?.isRegularFile == true, !fileURL.lastPathComponent.hasPrefix(".") else { continue }
                if let finding = try measureOllamaManifest(fileURL) {
                    measured.insert(fileURL.standardizedFileURL.path)
                    report.findings.append(finding)
                    recordedAny = true
                }
            }
        }
        if !recordedAny {
            let fallback = Rule(path: "", title: "Ollama local models", ecosystem: "Ollama LLM", category: .vms,
                                uninstallCommand: "/bin/rm -rf -- \(Finding.quote(modelsDir.path))",
                                command: "ollama list",
                                explanation: "Local large language model blobs and manifests stored by Ollama.",
                                consequence: "Removing deletes all local Ollama models.")
            try record(modelsDir, rule: fallback, measured: &measured, report: &report)
        }
    }

    private func measureOllamaManifest(_ manifestURL: URL) throws -> Finding? {
        let path = manifestURL.standardizedFileURL.path
        guard let markerRange = path.range(of: "/.ollama/models/manifests/") else { return nil }
        let modelsBasePath = String(path[..<markerRange.lowerBound]) + "/.ollama/models"
        let blobsDir = URL(fileURLWithPath: modelsBasePath, isDirectory: true).appendingPathComponent("blobs", isDirectory: true)
        let relative = String(path[markerRange.upperBound...])
        let components = relative.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let tag = components.last!
        let modelParts = components.dropFirst().dropLast()
        let modelPath: String = if modelParts.first == "library", modelParts.count > 1 {
            modelParts.dropFirst().joined(separator: "/")
        } else if !modelParts.isEmpty {
            modelParts.joined(separator: "/")
        } else {
            components.dropLast().joined(separator: "/")
        }
        let modelSpec = "\(modelPath):\(tag)"

        let data = try Data(contentsOf: manifestURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var digests: [(digest: String, fallbackSize: Int64)] = []
        if let config = json["config"] as? [String: Any], let digest = config["digest"] as? String {
            let size = (config["size"] as? NSNumber)?.int64Value ?? 0
            digests.append((digest, size))
        }
        if let layers = json["layers"] as? [[String: Any]] {
            for layer in layers {
                if let digest = layer["digest"] as? String {
                    let size = (layer["size"] as? NSNumber)?.int64Value ?? 0
                    digests.append((digest, size))
                }
            }
        }
        var totalBytes: Int64 = (try? manifestURL.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]))
            .map { Int64($0.fileAllocatedSize ?? $0.fileSize ?? 0) } ?? Int64(data.count)
        for item in digests {
            let blobName = item.digest.replacingOccurrences(of: ":", with: "-")
            let blobURL = blobsDir.appendingPathComponent(blobName)
            if let values = try? blobURL.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]),
               let diskBytes = values.fileAllocatedSize ?? values.fileSize
            {
                totalBytes += Int64(diskBytes)
            } else {
                totalBytes += item.fallbackSize
            }
        }
        return Finding(url: manifestURL,
                       title: "\(modelSpec) (Ollama model)",
                       ecosystem: "Ollama LLM",
                       category: .vms,
                       bytes: totalBytes,
                       modified: try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       explanation: "Local large language model (\(modelSpec)) weights and manifest stored in Ollama.",
                       consequence: "Uninstalling removes \(modelSpec) and frees its unshared layer blobs in Ollama.",
                       uninstallCommand: "ollama rm \(Finding.quote(modelSpec))",
                       inspectionCommand: nil,
                       incomplete: false,
                       volumeURL: try? manifestURL.resourceValues(forKeys: [.volumeURLKey]).volume)
    }
}
