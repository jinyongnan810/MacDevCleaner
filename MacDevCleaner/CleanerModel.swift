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
    var selectedGroupItemIDs: Set<String> = []
    private var task: Task<Void, Never>?
    private let scanner = StorageScanner()

    subscript(isSelected id: String) -> Bool {
        get { selectedGroupItemIDs.contains(id) }
        set {
            if newValue {
                selectedGroupItemIDs.insert(id)
            } else {
                selectedGroupItemIDs.remove(id)
            }
        }
    }

    func selectAll(in group: FindingGroup) {
        for item in group.items where !item.measurementIsStale {
            selectedGroupItemIDs.insert(item.id)
        }
    }

    func deselectAll(in group: FindingGroup) {
        for item in group.items {
            selectedGroupItemIDs.remove(item.id)
        }
    }

    func selectedItems(in group: FindingGroup) -> [Finding] {
        group.items.filter { selectedGroupItemIDs.contains($0.id) && !$0.measurementIsStale }
    }

    func deleteSelected(in group: FindingGroup) {
        let targets = selectedItems(in: group)
        guard !isBusy, !targets.isEmpty else { return }
        isRefreshing = true
        status = "Deleting \(targets.count) selected folders…"
        let previous = findings
        task = Task {
            var deleteErrors: [String] = []
            for item in targets {
                do {
                    try FileManager.default.removeItem(at: item.url)
                    selectedGroupItemIDs.remove(item.id)
                } catch {
                    deleteErrors.append("\(item.url.path): \(error.localizedDescription)")
                }
            }
            do {
                let report = try await scanner.refresh(previous)
                try Task.checkCancellation()
                findings = report.findings
                let validIDs = Set(report.findings.map(\.id))
                selectedGroupItemIDs.formIntersection(validIDs)
                refreshIssues = report.issues + deleteErrors
                refreshInaccessibleLocations = report.inaccessibleLocations + deleteErrors.count
                refreshedAt = .now
                needsRefreshAfterCopy = false
                let removed = previous.count - findings.count
                status = deleteErrors.isEmpty
                    ? "Deleted \(removed) selected locations and refreshed results."
                    : "Some selected locations could not be deleted. Review access issues."
            } catch is CancellationError {
                status = "Cleanup canceled."
            } catch {
                refreshIssues = [error.localizedDescription] + deleteErrors
                status = "Could not refresh results after deletion."
            }
            isRefreshing = false
            task = nil
        }
    }

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
                selectedGroupItemIDs = Set(report.findings.filter { $0.groupKey != nil }.map(\.id))
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
                let validIDs = Set(report.findings.map(\.id))
                selectedGroupItemIDs.formIntersection(validIDs)
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
