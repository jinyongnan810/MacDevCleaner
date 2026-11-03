import AppKit
import SwiftUI

/// Category filter options available in the sidebar.
private enum ScanFilter: String, CaseIterable, Identifiable {
    case all, caches, dependencies, tools, vms, apps, ignored

    /// Unique identifier for each filter case.
    var id: String { rawValue }

    /// Localized display name for the filter.
    var title: LocalizedStringResource {
        switch self {
        case .all: "All findings"
        case .caches: "Caches & builds"
        case .dependencies: "Project dependencies"
        case .tools: "CLIs & runtimes"
        case .vms: "VMs & models"
        case .apps: "Apps & support"
        case .ignored: "Ignored"
        }
    }

    /// SF Symbol name representing this filter.
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .caches: "shippingbox"
        case .dependencies: "folder.badge.gearshape"
        case .tools: "terminal"
        case .vms: "desktopcomputer"
        case .apps: "app.badge"
        case .ignored: "eye.slash"
        }
    }
}

/// Primary navigation split view containing sidebar, findings list, and inspector details.
struct ContentView: View {
    /// Shared view model driving the scan state and user interactions.
    @State private var model = CleanerModel()

    /// Currently selected category filter in the sidebar.
    @State private var filter: ScanFilter? = .all

    /// ID of the currently selected finding or group in the content list.
    @State private var selection: String?

    /// Current search query filtering visible findings.
    @State private var search = ""

    /// Controls presentation of the scan access and diagnostic sheet.
    @State private var showingIssues = false

    /// Findings matching the active category filter and search query.
    private var visibleFindings: [Finding] {
        model.findings.filter { item in
            let ignored = model.ignored.contains(item.id)
            let matches = switch filter ?? .all {
            case .all: !ignored
            case .ignored: ignored
            case .caches: !ignored && item.category == .caches
            case .dependencies: !ignored && item.category == .dependencies
            case .tools: !ignored && item.category == .tools
            case .vms: !ignored && item.category == .vms
            case .apps: !ignored && item.category == .apps
            }
            return matches && (search.isEmpty || "\(item.title) \(item.groupTitle ?? "") \(item.ecosystem) \(item.id)".localizedCaseInsensitiveContains(search))
        }
    }

    /// Display items organized into individual findings and clustered groups.
    private var visibleDisplayItems: [FindingDisplayItem] {
        var singles: [FindingDisplayItem] = []
        var groupedBuckets: [String: [Finding]] = [:]
        for item in visibleFindings {
            if let key = item.groupKey {
                groupedBuckets[key, default: []].append(item)
            } else {
                singles.append(.single(item))
            }
        }
        var result = singles
        for (key, members) in groupedBuckets {
            let sortedMembers = members.sorted { $0.bytes > $1.bytes }
            guard let first = sortedMembers.first else { continue }
            let group = FindingGroup(id: key,
                                     title: first.groupTitle ?? first.title,
                                     ecosystem: first.ecosystem,
                                     category: first.category,
                                     explanation: first.explanation,
                                     consequence: first.consequence,
                                     items: sortedMembers)
            result.append(.group(group))
        }
        return result.sorted { $0.bytes > $1.bytes }
    }

    /// Main user interface layout using a three-pane NavigationSplitView.
    var body: some View {
        NavigationSplitView {
            CleanerSidebar(filter: $filter, showingAccess: $showingIssues)
                .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 300)
        } content: {
            VStack(spacing: 0) {
                ScanOverview(findings: model.findings.filter { !model.ignored.contains($0.id) }, completedAt: model.completedAt)
                Divider()
                FindingsPanel(items: visibleDisplayItems, selectedIDs: model.selectedGroupItemIDs,
                              selection: $selection, isScanning: model.isScanning,
                              hasScanned: model.completedAt != nil, filter: filter ?? .all,
                              progress: model.progress, scan: model.scan)
                    .frame(maxHeight: .infinity)
                ScanFooter(model: model, showingIssues: $showingIssues)
            }
            .frame(minWidth: 440, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Storage audit")
            .navigationSplitViewColumnWidth(min: 360, ideal: 490)
            .searchable(text: $search, prompt: "Find a tool, project, or path")
        } detail: {
            if let displayItem = visibleDisplayItems.first(where: { $0.id == selection }) {
                switch displayItem {
                case let .single(item):
                    FindingInspector(item: item, ignored: model.ignored.contains(item.id), isBusy: model.isBusy,
                                     toggleIgnored: { model.toggleIgnored(item) }, commandCopied: model.commandCopied, refresh: model.refreshResults)
                case let .group(group):
                    GroupInspector(group: group, model: model)
                }
            } else {
                ContentUnavailableView("A little context before cleanup", systemImage: "terminal",
                                       description: Text("Select a finding to see what it is, what removal means, and a command you can review."))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Storage audit")
        .toolbar {
            ToolbarItem {
                Button("Refresh results", systemImage: "arrow.clockwise", action: model.refreshResults)
                    .disabled(model.isBusy || model.findings.isEmpty)
                    .help("Recheck existing findings after running cleanup commands")
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isBusy {
                    Button("Cancel", systemImage: "stop.circle", action: model.cancel)
                } else {
                    Button("Scan this Mac", systemImage: "viewfinder", action: model.scan)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .modifier(RefreshOnReturn(model: model))
        .onDisappear { model.cancel() }
        .tint(.teal)
        .sheet(isPresented: $showingIssues) {
            ScanIssuesView(issues: model.allIssues, inaccessibleLocations: model.totalInaccessibleLocations, isSandboxedBuild: model.isSandboxedBuild, openSettings: model.openPrivacySettings)
        }
    }
}

/// View modifier triggering a refresh when the app transitions to the active state.
private struct RefreshOnReturn: ViewModifier {
    /// View model to notify when returning to active state.
    let model: CleanerModel

    /// Listens for application did-become-active notifications to refresh results.
    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAfterReturning()
        }
    }
}

/// Sidebar view displaying category filters, scan scopes, and safety information.
private struct CleanerSidebar: View {
    /// Binding to the selected sidebar category filter.
    @Binding var filter: ScanFilter?

    /// Binding to present the scan access issues sheet.
    @Binding var showingAccess: Bool

    /// Layout for the navigation sidebar.
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.title).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacDevCleaner").font(.headline)
                    Text("Make room for what’s next.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 24)
            List(selection: $filter) {
                Section("YOUR STORAGE") {
                    ForEach(ScanFilter.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("SCAN SCOPE") {
                    Label("This Mac", systemImage: "desktopcomputer")
                    Text("Startup disk & local drives")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Scan access…", systemImage: "lock.shield") { showingAccess = true }
                }
            }
            .listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 8) {
                Label("You’re in control", systemImage: "hand.raised")
                    .font(.subheadline.weight(.medium))
                Text("Read-only scans. Local results. Commands run only when you run them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.teal.opacity(0.07))
        }
    }
}

/// Header banner displaying total storage discovered and category breakdown cards.
private struct ScanOverview: View {
    /// Non-ignored findings included in the overview calculation.
    let findings: [Finding]

    /// Timestamp of scan completion, used to toggle placeholder display.
    let completedAt: Date?

    /// Total aggregated bytes across all visible findings.
    private var bytes: Int64 { findings.reduce(0) { $0 + $1.bytes } }

    /// Layout for the overview metrics and category cards.
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A clearer view of your dev storage").font(.title2.weight(.semibold))
                    Text("Find the leftovers. Understand the tradeoffs.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "internaldrive").font(.largeTitle).foregroundStyle(.teal)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(completedAt == nil ? "—" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
                Text("developer storage found").font(.caption).foregroundStyle(.secondary)
            }
            Text("Measured file allocation, not guaranteed reclaimable space. Shared files and APFS snapshots can affect recovery.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(FindingCategory.allCases) { category in
                    CategoryMetric(category: category, bytes: findings.filter { $0.category == category }.reduce(0) { $0 + $1.bytes })
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.teal.opacity(0.045))
    }
}

/// Card displaying an individual category's icon, title, and disk usage.
private struct CategoryMetric: View {
    /// Finding category represented by this metric card.
    let category: FindingCategory

    /// Total byte size accumulated in this category.
    let bytes: Int64

    /// Layout for the category metric card.
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: category.symbol).foregroundStyle(.teal)
            Text(category.title).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 85, alignment: .topLeading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Middle column displaying the list of findings, scan progress, or empty state.
private struct FindingsPanel: View {
    /// Display items to render in the list.
    let items: [FindingDisplayItem]

    /// IDs of selected items for count badges.
    let selectedIDs: Set<String>

    /// Binding to the currently selected finding ID.
    @Binding var selection: String?

    /// Flag indicating whether a scan is currently running.
    let isScanning: Bool

    /// Flag indicating whether a scan has finished at least once.
    let hasScanned: Bool

    /// Active category filter for title display.
    let filter: ScanFilter

    /// Current scan progress metrics.
    let progress: ScanProgress

    /// Callback closure to trigger a new scan.
    let scan: () -> Void

    /// Layout for the findings list and status placeholders.
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(filter.title).font(.headline)
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Largest first").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            if isScanning {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Scanning this Mac…").font(.headline)
                    Text("\(progress.directoriesVisited.formatted()) folders checked · \(progress.findingsCount.formatted()) findings")
                        .font(.subheadline).monospacedDigit()
                    Text(progress.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).padding(.horizontal, 24)
                    Text("Large dependency trees can take a moment.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label(hasScanned ? "Nothing here" : "Make room for your next project", systemImage: hasScanned ? "checkmark.circle" : "desktopcomputer")
                } description: {
                    Text(hasScanned ? "No matching findings. Try another category or check scan access for coverage limitations." : "Find developer caches, dependencies, and tools across this Mac. No folders to choose. You decide what to clean.")
                } actions: {
                    Button(hasScanned ? "Scan again" : "Scan this Mac", systemImage: "viewfinder", action: scan)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items, selection: $selection) { item in
                    FindingDisplayRow(item: item, selectedIDs: selectedIDs).tag(item.id)
                }.listStyle(.inset)
            }
        }
    }
}

/// Row view rendering either an individual finding or a grouped cluster.
private struct FindingDisplayRow: View {
    /// Display item representing either a single finding or group.
    let item: FindingDisplayItem

    /// Set of currently selected item IDs.
    let selectedIDs: Set<String>

    /// Layout for the list row.
    var body: some View {
        HStack(spacing: 12) {
            switch item {
            case let .single(finding):
                Image(systemName: finding.category.symbol)
                    .font(.title3).foregroundStyle(.teal)
                    .frame(width: 38, height: 42)
                    .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(finding.title).font(.headline).lineLimit(1)
                    Text(finding.ecosystem).font(.caption).foregroundStyle(.secondary)
                    Text(finding.url.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(finding.displaySize).font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text(finding.measurementIsStale ? "Needs recheck" : finding.incomplete ? "Partial size" : finding.uninstallCommand != nil ? "Uninstallable" : finding.inspectionCommand != nil ? "Review usage" : "Regenerable")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            case let .group(group):
                let checkedCount = group.items.filter { selectedIDs.contains($0.id) }.count
                let isAppGroup = group.category == .apps
                Image(systemName: isAppGroup ? "app.badge" : "checklist")
                    .font(.title3).foregroundStyle(.teal)
                    .frame(width: 38, height: 42)
                    .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(group.title).font(.headline).lineLimit(1)
                        Text("\(group.items.count)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.teal.opacity(0.15), in: Capsule())
                    }
                    Text("\(group.ecosystem) · \(checkedCount) of \(group.items.count) selected")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(isAppGroup ? "App bundle & support folders — choose what to remove" : "Grouped folders — select to choose which projects to delete")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(group.displaySize).font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text(isAppGroup ? "App + support" : "Batch select")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 8)
    }
}

/// Bottom status bar showing scan status, timestamps, and access warnings.
private struct ScanFooter: View {
    /// Model providing scan status and timestamps.
    let model: CleanerModel

    /// Binding to present the access issues sheet.
    @Binding var showingIssues: Bool

    /// Layout for the footer bar.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isSandboxedBuild {
                Button { showingIssues = true } label: {
                    Label("This build has limited scan access", systemImage: "lock.shield")
                }.buttonStyle(.plain).foregroundStyle(.orange)
            }
            if !model.allIssues.isEmpty {
                Button { showingIssues = true } label: {
                    Label("\(model.totalInaccessibleLocations.formatted()) locations couldn’t be read — review access", systemImage: "exclamationmark.circle")
                }.buttonStyle(.plain).foregroundStyle(.orange)
            }
            HStack {
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
            }
            if let date = model.refreshedAt {
                HStack {
                    Text("Results refreshed")
                    Text(date, format: .dateTime.hour().minute())
                }.font(.caption2).foregroundStyle(.secondary)
            }
            if let date = model.completedAt {
                HStack {
                    Text("Last completed scan")
                    Text(date, format: .dateTime.hour().minute())
                    Text("· \(model.volumesScanned) local volumes")
                }.font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(.bar)
    }
}

/// Detail view showing metadata, consequences, and commands for a single finding.
private struct FindingInspector: View {
    /// Finding item being inspected.
    let item: Finding

    /// Whether the item is currently hidden/ignored.
    let ignored: Bool

    /// Whether the cleaner model is currently performing background work.
    let isBusy: Bool

    /// Action closure to toggle the item's ignored status.
    let toggleIgnored: () -> Void

    /// Action closure called when the cleanup command is copied.
    let commandCopied: () -> Void

    /// Action closure to trigger a refresh of existing findings.
    let refresh: () -> Void

    /// Layout for the single finding inspector.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: item.category.symbol).font(.largeTitle).foregroundStyle(.teal)
                    Text(item.ecosystem).font(.subheadline).foregroundStyle(.secondary)
                    Text(item.title).font(.title.weight(.semibold))
                    Text(item.displaySize).font(.system(.title, design: .rounded, weight: .medium)).monospacedDigit()
                    Label(item.measurementIsStale ? "Previous measurement — recheck needed" : item.incomplete ? "Partial measurement" : "Measured on disk", systemImage: "internaldrive")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DetailSection(title: "What you’re looking at", text: item.explanation)
                DetailSection(title: "Before you decide", text: item.consequence)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Location").font(.headline)
                    Text(item.url.path).font(.caption.monospaced()).textSelection(.enabled)
                    if let date = item.modified {
                        LabeledContent("Directory modified") { Text(date, format: .dateTime.year().month().day()) }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Modification time is a clue, not proof of inactivity.").font(.caption).foregroundStyle(.secondary)
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                }
                if item.measurementIsStale {
                    DetailSection(title: "Location couldn’t be rechecked", text: "The previous size is shown. Reconnect the drive or restore access, then refresh. Cleanup commands are hidden until the location can be checked again.")
                } else {
                    CommandCard(command: item.command, isUninstall: item.uninstallCommand != nil, isInspection: item.inspectionCommand != nil, onCopy: commandCopied)
                        .id(item.id)
                }
                Button("Refresh results", systemImage: "arrow.clockwise", action: refresh)
                    .disabled(isBusy)
                Button(ignored ? "Restore finding" : "Ignore this finding", systemImage: ignored ? "eye" : "eye.slash", action: toggleIgnored)
                    .frame(maxWidth: .infinity)
                Text("After copying a command, results refresh when you return to the app. You can also use Refresh results at any time. A whole-Mac scan discovers new locations.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .frame(minWidth: 300)
        .background(.background)
    }
}

/// Detail view for managing and batch-deleting items in a grouped finding.
private struct GroupInspector: View {
    /// Finding group being inspected.
    let group: FindingGroup

    /// Bindable reference to the cleaner model for selection and deletion.
    @Bindable var model: CleanerModel

    /// Controls display of the batch deletion confirmation dialog.
    @State private var confirmingDelete = false

    /// Filtered list of items currently selected within this group.
    private var selectedItems: [Finding] {
        model.selectedItems(in: group)
    }

    /// Total bytes calculated across all selected items.
    private var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.bytes }
    }

    /// Formatted byte count string for selected items.
    private var selectedSizeText: String {
        ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)
    }

    /// Combined rm command to delete all selected items in Terminal.
    private var combinedCommand: String {
        let needsSudo = selectedItems.contains { $0.url.path.hasPrefix("/Applications/") || $0.url.path.hasPrefix("/Library/") }
        let paths = selectedItems.map { Finding.quote($0.url.path) }.joined(separator: " ")
        return "\(needsSudo ? "sudo " : "")/bin/rm -rf -- \(paths)"
    }

    /// Layout for the group inspector.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.teal)
                    Text("\(group.ecosystem) · \(group.items.count) folders").font(.subheadline).foregroundStyle(.secondary)
                    Text(group.title).font(.title.weight(.semibold))
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(group.displaySize)
                            .font(.system(.title, design: .rounded, weight: .medium)).monospacedDigit()
                        Text("total (\(selectedSizeText) selected)")
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }

                DetailSection(title: "What you’re looking at", text: group.explanation)
                DetailSection(title: "Before you decide", text: group.consequence)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Choose folders to delete (\(selectedItems.count)/\(group.items.count))")
                            .font(.headline)
                        Spacer()
                        Button("Select All") { model.selectAll(in: group) }
                            .buttonStyle(.link)
                        Text("·").foregroundStyle(.secondary)
                        Button("Deselect All") { model.deselectAll(in: group) }
                            .buttonStyle(.link)
                    }

                    VStack(spacing: 8) {
                        ForEach(group.items) { member in
                            GroupMemberRow(member: member,
                                           isSelected: $model[isSelected: member.id],
                                           isIgnored: model.ignored.contains(member.id),
                                           toggleIgnored: { model.toggleIgnored(member) })
                        }
                    }
                }

                if selectedItems.isEmpty {
                    DetailSection(title: "No folders selected",
                                  text: "Check one or more folders above to generate a batch cleanup command or delete them.")
                } else {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete \(selectedItems.count) Selected Folders (\(selectedSizeText))…", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(model.isBusy)

                    CommandCard(command: combinedCommand, isUninstall: false, isInspection: false, onCopy: model.commandCopied)
                        .id(combinedCommand)
                }

                Button("Refresh results", systemImage: "arrow.clockwise", action: model.refreshResults)
                    .disabled(model.isBusy)
            }
            .padding(28)
        }
        .frame(minWidth: 320)
        .background(.background)
        .confirmationDialog("Delete \(selectedItems.count) selected folders (\(selectedSizeText))?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible)
        {
            Button("Delete \(selectedItems.count) Folders", role: .destructive) {
                model.deleteSelected(in: group)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the \(selectedItems.count) checked \(group.title) from disk and cannot be undone.")
        }
    }
}

/// Row view representing a single member within a grouped finding inspector.
private struct GroupMemberRow: View {
    /// Finding item represented by this row.
    let member: Finding

    /// Binding to the member's checkbox selection state.
    @Binding var isSelected: Bool

    /// Whether the member is currently marked as ignored.
    let isIgnored: Bool

    /// Action closure to toggle the member's ignored state.
    let toggleIgnored: () -> Void

    /// Layout for the group member row.
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $isSelected)
                .labelsHidden()
                .disabled(member.measurementIsStale)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(member.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text(member.displaySize).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
                Text(member.url.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    if let date = member.modified {
                        Text(date, format: .dateTime.year().month().day())
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([member.url])
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                    Button(isIgnored ? "Restore" : "Ignore", systemImage: isIgnored ? "eye" : "eye.slash", action: toggleIgnored)
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            }
        }
        .padding(10)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Reusable section displaying a title and localized explanatory text block.
private struct DetailSection: View {
    /// Section header title.
    let title: LocalizedStringResource

    /// Body text explaining the section topic.
    let text: LocalizedStringResource

    /// Layout for the detail text section.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Card displaying a terminal command with one-click copy and usage guidance.
private struct CommandCard: View {
    /// Shell command string to display and copy.
    let command: String

    /// Indicates if the command is a package uninstall command.
    var isUninstall = false

    /// Indicates if the command is an inspection command.
    let isInspection: Bool

    /// Callback invoked when the user copies the command.
    let onCopy: () -> Void

    /// State tracking whether the command was recently copied to clipboard.
    @State private var copied = false

    /// Layout for the command display card.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(isUninstall ? "How to uninstall" : isInspection ? "Inspect in Terminal" : "Cleanup command", systemImage: "terminal")
                .font(.headline)
            Text(command).font(.callout.monospaced()).textSelection(.enabled)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            Text(isUninstall ? "Run this command in Terminal to uninstall this CLI or runtime version and reclaim its storage." : isInspection ? "This command lists information. Use the owning tool to choose what to remove." : "Recursively deletes this directory without confirmation and bypasses Trash. Review the exact path and back up local changes before running.")
                .font(.caption).foregroundStyle(.secondary)
            Button(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(command, forType: .string)
                if copied { onCopy() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(16)
        .background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Sheet view listing scan access restrictions, sandbox warnings, and path errors.
private struct ScanIssuesView: View {
    /// List of diagnostic error messages encountered during scanning.
    let issues: [String]

    /// Count of locations that could not be read.
    let inaccessibleLocations: Int

    /// Flag indicating if the current app build is sandboxed.
    let isSandboxedBuild: Bool

    /// Callback to open macOS System Settings.
    let openSettings: () -> Void

    /// Dismiss action to close the modal sheet.
    @Environment(\.dismiss) private var dismiss

    /// Layout for the scan issues sheet.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Scan access & coverage", systemImage: "lock.shield").font(.title2.bold())
            Text("The scan searches the startup disk and mounted local drives for supported developer storage. System directories, app bundles, backups, network drives, and symbolic links are skipped.")
                .foregroundStyle(.secondary)
            if isSandboxedBuild {
                Label("This build uses App Sandbox", systemImage: "exclamationmark.shield").font(.headline)
                Text("Automatic whole-Mac coverage requires a build without App Sandbox. Full Disk Access does not remove the sandbox restriction.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text("For broader access, open System Settings → Privacy & Security → Full Disk Access and enable MacDevCleaner. Relaunch the app, then scan again. macOS permissions can still prevent reading some locations.")
                .font(.subheadline)
            Button("Open System Settings", systemImage: "gear", action: openSettings)
            Divider()
            Text("\(inaccessibleLocations.formatted()) locations could not be read in the latest scan or refresh.")
                .font(.headline)
            Text("Unreadable files are excluded from totals. Notes below include measurement limitations; at most 100 traversal errors per volume are listed.")
                .font(.caption).foregroundStyle(.secondary)
            List(issues, id: \.self) { issue in
                Text(issue).font(.caption.monospaced()).textSelection(.enabled)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(24).frame(width: 680, height: 650)
    }
}

#Preview {
    ContentView()
        .frame(width: 1280, height: 820)
}
