# MacDevCleaner

A native SwiftUI developer storage audit for macOS. Scans are read-only. Cleanup commands are copied for you to review and run in Terminal; the app never executes them.

## Use

1. Run the MacDevCleaner scheme in Xcode (macOS 27 or later).
2. Click **Scan this Mac** (Command-R). No folders need to be selected. The app discovers supported developer storage across the startup disk and mounted local drives.
3. Search or filter the findings and select an item for context. During scanning, the app shows the current path, folders visited, and findings discovered.
4. Review the path, consequences, and command. Copy it or open the location in Finder. Ignore findings you want to keep; ignored paths persist locally.
5. After running a copied command, return to the app to automatically refresh existing findings, or click **Refresh results** (Command-Shift-R). Deleted directories disappear and remaining directories are remeasured. Use a whole-Mac scan to discover new locations. The app cannot know whether a command ran in Terminal; it verifies the filesystem instead. Inaccessible or unavailable locations retain their previous size, are marked for rechecking, and have cleanup commands hidden.

## Coverage

- Known home locations: Xcode Derived Data, SwiftPM, npm, Yarn, pnpm, pip, uv, Homebrew, Gradle, Cargo, nvm, pyenv, rustup, user Python packages, pipx, Docker VM storage, and Apple container storage.
- Project trees: node_modules, Python environments with pyvenv.cfg, Swift .build next to Package.swift, Rust target next to Cargo.toml, and Terraform .terraform directories.
- Shared installations: /Library/Developer/CommandLineTools, Homebrew Cellar directories, and /Library/Frameworks/Python.framework.
- Network drives, hidden volumes, system trees, application bundles, backups, version-control internals, and symbolic links are excluded. /System/Volumes/Data is excluded to avoid scanning the startup disk twice through APFS firmlinks.

Tool installations, container storage, and Terraform working directories receive inspection commands rather than recursive deletion commands. Other recognized generated directories receive `/bin/rm -rf --` commands for their exact shell-quoted path. Removal is recursive, skips confirmation, and bypasses Trash. The app only copies commands; it does not run them or use sudo.

## Limits

This is a location-based audit, not a complete package-manager inventory or an unused-file detector. Custom cache locations and globally installed packages outside known locations need additional coverage. Container disk allocation is not a reclaimable-space estimate. The app does not connect to Docker or container daemons.

File allocation is measured without following symlinks. Overlapping findings are deduplicated, and hard links within a finding are counted once. APFS clones, shared files across findings, snapshots, and changes during a scan can affect totals and actual recovered space. Unreadable files produce scan notes and partial measurements. Directory modification times are context, not proof of inactivity.

Automatic whole-Mac scanning uses a directly distributed build with App Sandbox disabled. Hardened Runtime remains enabled. This distribution configuration is not suitable for the Mac App Store, which requires App Sandbox.

In an unrestricted build, macOS privacy protections and filesystem permissions still apply. Use **Scan access…** for Full Disk Access guidance and a list of unreadable locations, then relaunch and rescan after changing permissions. The app never grants itself Full Disk Access, requests administrator privileges, or changes permissions. At most 100 traversal error details per volume are retained, with total inaccessible counts reported separately. Review scan notes rather than interpreting missing findings as proof that a tool has no data. Terraform state and container volumes must be reviewed and backed up using their owning tools.

The inspection commands follow the [Docker CLI reference](https://docs.docker.com/reference/cli/docker/system/df/) and [Apple container command reference](https://github.com/apple/container/blob/main/docs/command-reference.md). Installed versions may differ.

## Development

Run `make lint` after Swift changes. Build using Xcode MCP BuildProject. Do not run test suites unless explicitly requested (see AGENTS.md).

## Direct distribution

Distribute a Developer ID–signed, notarized DMG. See [the release guide](docs/distribution.md) for certificate setup, Xcode archive/export, `make dmg`, notarization, and installation verification. Packaging takes an exported app and does not build or modify its signature.
