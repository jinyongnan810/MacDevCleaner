import AppKit
import Observation

@MainActor @Observable
final class CleanerModel {
    let isSandboxedBuild = Bundle.main.object(forInfoDictionaryKey: "MacDevCleanerSandboxEnabled") as? String != "NO"
    var findings: [Finding] = []
    var issues: [String] = []
    var isScanning = false
    var completedAt: Date?
    var progress = ScanProgress()
    var inaccessibleLocations = 0
    var volumesScanned = 0
    var status: LocalizedStringResource = "Ready to find developer storage across this Mac."
    var ignored: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ignoredPaths") ?? [])
    private var task: Task<Void, Never>?
    private let scanner = StorageScanner()

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        progress = ScanProgress()
        status = "Discovering developer storage on this Mac…"
        task = Task {
            do {
                let report = try await scanner.scanMac { [weak self] update in
                    await self?.updateProgress(update)
                }
                try Task.checkCancellation()
                findings = report.findings
                issues = Array(Set(report.issues)).sorted()
                inaccessibleLocations = report.inaccessibleLocations
                volumesScanned = report.volumesScanned
                progress = ScanProgress(directoriesVisited: report.directoriesVisited, findingsCount: findings.count)
                completedAt = .now
                status = report.inaccessibleLocations == 0 ? "Scan complete. Review findings at your own pace." : "Scan complete. Some locations could not be read."
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

    private func updateProgress(_ update: ScanProgress) { progress = update }

    func cancel() { task?.cancel() }

    func toggleIgnored(_ finding: Finding) {
        if ignored.contains(finding.id) { ignored.remove(finding.id) } else { ignored.insert(finding.id) }
        UserDefaults.standard.set(Array(ignored), forKey: "ignoredPaths")
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
