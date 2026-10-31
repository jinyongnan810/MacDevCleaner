import AppKit
import Observation

@MainActor @Observable
final class CleanerModel {
    let isSandboxedBuild = Bundle.main.object(forInfoDictionaryKey: "MacDevCleanerSandboxEnabled") as? String != "NO"
    var findings: [Finding] = []
    var issues: [String] = []
    var isScanning = false
    var isRefreshing = false
    var refreshedAt: Date?
    var refreshIssues: [String] = []
    var refreshInaccessibleLocations = 0
    var needsRefreshAfterCopy = false
    var isBusy: Bool { isScanning || isRefreshing }
    var allIssues: [String] { Array(Set(issues + refreshIssues)).sorted() }
    var totalInaccessibleLocations: Int { inaccessibleLocations + refreshInaccessibleLocations }
    var completedAt: Date?
    var progress = ScanProgress()
    var inaccessibleLocations = 0
    var volumesScanned = 0
    var status: LocalizedStringResource = "Ready to find developer storage across this Mac."
    var ignored: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ignoredPaths") ?? [])
    private var task: Task<Void, Never>?
    private let scanner = StorageScanner()

    func scan() {
        guard !isBusy else { return }
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
                refreshIssues = []
                refreshInaccessibleLocations = 0
                refreshedAt = nil
                needsRefreshAfterCopy = false
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

    func refreshResults() {
        guard !isBusy, !findings.isEmpty else { return }
        isRefreshing = true
        status = "Rechecking findings after cleanup…"
        let previous = findings
        task = Task {
            do {
                let report = try await scanner.refresh(previous)
                try Task.checkCancellation()
                findings = report.findings
                refreshIssues = report.issues
                refreshInaccessibleLocations = report.inaccessibleLocations
                refreshedAt = .now
                needsRefreshAfterCopy = false
                let removed = previous.count - findings.count
                status = report.inaccessibleLocations == 0
                    ? "Results refreshed. \(removed) removed locations no longer appear."
                    : "Results refreshed. Some locations could not be rechecked."
            } catch is CancellationError {
                status = "Refresh canceled. Previous results have been kept."
            } catch {
                refreshIssues = [error.localizedDescription]
                status = "Could not refresh results. Previous results have been kept."
            }
            isRefreshing = false
            task = nil
        }
    }

    func commandCopied() { needsRefreshAfterCopy = true }

    func refreshAfterReturning() {
        if needsRefreshAfterCopy { refreshResults() }
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
