import AppKit
import SwiftUI

private enum ScanFilter: String, CaseIterable, Identifiable {
    case all, caches, dependencies, tools, ignored
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .all: "All findings"
        case .caches: "Caches & builds"
        case .dependencies: "Project dependencies"
        case .tools: "Tools & containers"
        case .ignored: "Ignored"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .caches: "shippingbox"
        case .dependencies: "folder.badge.gearshape"
        case .tools: "terminal"
        case .ignored: "eye.slash"
        }
    }
}

struct ContentView: View {
    @State private var model = CleanerModel()
    @State private var filter: ScanFilter? = .all
    @State private var selection: String?
    @State private var search = ""
    @State private var showingIssues = false

    private var visibleFindings: [Finding] {
        model.findings.filter { item in
            let ignored = model.ignored.contains(item.id)
            let matches = switch filter ?? .all {
            case .all: !ignored
            case .ignored: ignored
            case .caches: !ignored && item.category == .caches
            case .dependencies: !ignored && item.category == .dependencies
            case .tools: !ignored && item.category == .tools
            }
            return matches && (search.isEmpty || "\(item.title) \(item.ecosystem) \(item.id)".localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationSplitView {
            CleanerSidebar(model: model, filter: $filter)
                .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 300)
        } content: {
            VStack(spacing: 0) {
                ScanOverview(findings: model.findings.filter { !model.ignored.contains($0.id) }, completedAt: model.completedAt)
                Divider()
                FindingsPanel(items: visibleFindings, selection: $selection, isScanning: model.isScanning,
                              hasScanned: model.completedAt != nil, hasRoots: !model.roots.isEmpty, filter: filter ?? .all,
                              addFolder: { model.chooseFolder(home: false) }, scan: model.scan)
                    .frame(maxHeight: .infinity)
                ScanFooter(model: model, showingIssues: $showingIssues)
            }
            .frame(minWidth: 440, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Storage audit")
            .navigationSplitViewColumnWidth(min: 360, ideal: 490)
            .searchable(text: $search, prompt: "Find a tool, project, or path")
        } detail: {
            if let item = visibleFindings.first(where: { $0.id == selection }) {
                FindingInspector(item: item, ignored: model.ignored.contains(item.id), toggleIgnored: { model.toggleIgnored(item) })
            } else {
                ContentUnavailableView("A little context before cleanup", systemImage: "terminal",
                                       description: Text("Select a finding to see what it is, what removal means, and a command you can review."))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Storage audit")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isScanning {
                    Button("Cancel scan", systemImage: "stop.circle", action: model.cancel)
                } else {
                    Button("Scan folders", systemImage: "viewfinder", action: model.scan)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.roots.isEmpty)
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .onDisappear { model.cancel() }
        .tint(.teal)
        .sheet(isPresented: $showingIssues) {
            ScanIssuesView(issues: model.issues)
        }
    }
}

private struct CleanerSidebar: View {
    let model: CleanerModel
    @Binding var filter: ScanFilter?

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
                Section("SCAN LOCATIONS") {
                    ForEach(model.roots) { root in
                        HStack {
                            Image(systemName: root.isHome ? "house" : "folder")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(root.url.lastPathComponent).lineLimit(1)
                                Text(root.isHome ? "Known tool locations" : "Projects & dependencies")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button {
                                model.removeRoot(root)
                            } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove scan location")
                            .accessibilityLabel("Remove \(root.url.lastPathComponent)")
                            .disabled(model.isScanning)
                        }
                        .help(root.url.path)
                    }
                    Button("Add home folder", systemImage: "house.badge.plus") { model.chooseFolder(home: true) }
                    Button("Add project folder", systemImage: "folder.badge.plus") { model.chooseFolder(home: false) }
                }
                .disabled(model.isScanning)
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

private struct ScanOverview: View {
    let findings: [Finding]
    let completedAt: Date?
    private var bytes: Int64 { findings.reduce(0) { $0 + $1.bytes } }

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

private struct CategoryMetric: View {
    let category: FindingCategory
    let bytes: Int64
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

private struct FindingsPanel: View {
    let items: [Finding]
    @Binding var selection: String?
    let isScanning: Bool
    let hasScanned: Bool
    let hasRoots: Bool
    let filter: ScanFilter
    let addFolder: () -> Void
    let scan: () -> Void

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
                    Text("Measuring your selected folders…").font(.headline)
                    Text("Large dependency trees can take a moment.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label(hasScanned ? "Nothing here" : "Start with your dev folders", systemImage: hasScanned ? "checkmark.circle" : "folder.badge.plus")
                } description: {
                    Text(hasScanned ? "No matching findings. Try another category or add more scan locations. Check scan notes for access limitations." : "Add a home folder for known caches, or a project folder for dependencies and build output.")
                } actions: {
                    if hasRoots, !hasScanned {
                        Button("Scan selected folders", action: scan).buttonStyle(.borderedProminent)
                    }
                    Button("Add project folder", action: addFolder)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items, selection: $selection) { item in
                    FindingRow(item: item).tag(item.id)
                }.listStyle(.inset)
            }
        }
    }
}

private struct FindingRow: View {
    let item: Finding
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.category.symbol)
                .font(.title3).foregroundStyle(.teal)
                .frame(width: 38, height: 42)
                .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(item.ecosystem).font(.caption).foregroundStyle(.secondary)
                Text(item.url.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 5) {
                Text(item.displaySize).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(item.incomplete ? "Partial size" : item.inspectionCommand != nil ? "Review usage" : "Regenerable")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8)
    }
}

private struct ScanFooter: View {
    let model: CleanerModel
    @Binding var showingIssues: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.issues.isEmpty {
                Button { showingIssues = true } label: {
                    Label("\(model.issues.count) scan notes — review access limitations", systemImage: "exclamationmark.circle")
                }.buttonStyle(.plain).foregroundStyle(.orange)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            if let date = model.completedAt {
                Text(date, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(.bar)
    }
}

private struct FindingInspector: View {
    let item: Finding
    let ignored: Bool
    let toggleIgnored: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: item.category.symbol).font(.largeTitle).foregroundStyle(.teal)
                    Text(item.ecosystem).font(.subheadline).foregroundStyle(.secondary)
                    Text(item.title).font(.title.weight(.semibold))
                    Text(item.displaySize).font(.system(.title, design: .rounded, weight: .medium)).monospacedDigit()
                    Label(item.incomplete ? "Partial measurement" : "Measured on disk", systemImage: "internaldrive")
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
                CommandCard(command: item.command, isInspection: item.inspectionCommand != nil)
                    .id(item.id)
                Button(ignored ? "Restore finding" : "Ignore this finding", systemImage: ignored ? "eye" : "eye.slash", action: toggleIgnored)
                    .frame(maxWidth: .infinity)
                Text("After running a command yourself, scan again to refresh these results.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .frame(minWidth: 300)
        .background(.background)
    }
}

private struct DetailSection: View {
    let title: LocalizedStringResource
    let text: LocalizedStringResource
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CommandCard: View {
    let command: String
    let isInspection: Bool
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(isInspection ? "Inspect in Terminal" : "Cleanup command", systemImage: "terminal")
                .font(.headline)
            Text(command).font(.callout.monospaced()).textSelection(.enabled)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            Text(isInspection ? "This command lists information. Use the owning tool to choose what to remove." : "Interactive removal asks before deleting files. Review the exact path and back up local changes. Deletion bypasses Trash.")
                .font(.caption).foregroundStyle(.secondary)
            Button(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(command, forType: .string)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(16)
        .background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ScanIssuesView: View {
    let issues: [String]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan notes").font(.title2.bold())
            Text("Inaccessible files are excluded from totals. You can select a location again to grant access; macOS privacy restrictions may still apply.")
                .foregroundStyle(.secondary)
            List(issues, id: \.self) { issue in
                Text(issue).font(.caption.monospaced()).textSelection(.enabled)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(24).frame(width: 650, height: 440)
    }
}

#Preview {
    ContentView()
        .frame(width: 1280, height: 820)
}
