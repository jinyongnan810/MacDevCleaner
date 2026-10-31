import AppKit
import Observation

@MainActor @Observable
final class CleanerModel {
    var roots: [ScanRoot] = []
    var findings: [Finding] = []
    var issues: [String] = []
    var isScanning = false
    var completedAt: Date?
    var status: LocalizedStringResource = "Choose folders to start your storage audit."
    var ignored: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ignoredPaths") ?? [])
    private var task: Task<Void, Never>?
    private var grantedURLs: [URL] = []
    private let scanner = StorageScanner()

    isolated deinit {
        for url in grantedURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func chooseFolder(home: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = !home
        panel.prompt = "Add to scan"
        panel.message = home ? "Select your home folder. Only known developer cache and tool locations inside it will be scanned." : "Select project folders to look for dependencies and build output."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !roots.contains(where: { $0.url == url }) {
            if url.startAccessingSecurityScopedResource() { grantedURLs.append(url) }
            roots.append(ScanRoot(url: url, isHome: home))
        }
        completedAt = nil
        findings = []
    }

    func removeRoot(_ root: ScanRoot) {
        roots.removeAll { $0.id == root.id }
        if let index = grantedURLs.firstIndex(of: root.url) {
            grantedURLs.remove(at: index).stopAccessingSecurityScopedResource()
        }
        findings = []
        completedAt = nil
    }

    func scan() {
        guard !isScanning, !roots.isEmpty else { return }
        isScanning = true
        issues = []
        status = "Measuring developer storage…"
        let selectedRoots = roots
        task = Task {
            do {
                let report = try await scanner.scan(roots: selectedRoots)
                try Task.checkCancellation()
                findings = report.findings
                issues = Array(Set(report.issues)).sorted()
                completedAt = .now
                status = report.issues.isEmpty ? "Scan complete. Review findings at your own pace." : "Scan complete with access or measurement limitations."
            } catch is CancellationError {
                status = "Scan canceled. Previous results have been kept."
            } catch {
                issues = [error.localizedDescription]
                status = "The scan could not finish."
            }
            isScanning = false
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    func toggleIgnored(_ finding: Finding) {
        if ignored.contains(finding.id) { ignored.remove(finding.id) } else { ignored.insert(finding.id) }
        UserDefaults.standard.set(Array(ignored), forKey: "ignoredPaths")
    }
}
