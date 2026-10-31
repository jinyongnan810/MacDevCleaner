# MacDevCleaner

A native SwiftUI developer storage audit for macOS. Scans are read-only. Cleanup commands are copied for you to review and run in Terminal; the app never executes them.

## Use

1. Run the MacDevCleaner scheme in Xcode (macOS 27 or later).
2. Add your home folder to scan known developer cache and tool locations. Add project folders to find dependencies and build output. Folder access is granted for the current app session.
3. Scan folders (Command-R), search or filter the findings, and select an item for context.
4. Review the path, consequences, and command. Copy it or open the location in Finder. Ignore findings you want to keep; ignored paths persist locally.
5. After performing cleanup yourself, scan again.

## Coverage

- Known home locations: Xcode Derived Data, SwiftPM, npm, Yarn, pnpm, pip, uv, Homebrew, Gradle, Cargo, nvm, pyenv, rustup, user Python packages, pipx, Docker VM storage, and Apple container storage.
- Project trees: node_modules, Python environments with pyvenv.cfg, Swift .build next to Package.swift, Rust target next to Cargo.toml, and Terraform .terraform directories.
- Select /Library/Developer/CommandLineTools as a project scan location to inspect Apple command line tools.

Tool installations, container storage, and Terraform working directories receive inspection commands rather than recursive deletion commands. Other recognized generated directories receive interactive removal commands for their exact shell-quoted path. Commands do not use sudo or force flags, and deletion bypasses Trash.

## Limits

This is a location-based audit, not a complete package-manager inventory or an unused-file detector. Custom cache locations and globally installed packages outside known locations need additional coverage. Container disk allocation is not a reclaimable-space estimate. The app does not connect to Docker or container daemons.

File allocation is measured without following symlinks. Overlapping findings are deduplicated, and hard links within a finding are counted once. APFS clones, shared files across findings, snapshots, and changes during a scan can affect totals and actual recovered space. Unreadable files produce scan notes and partial measurements. Directory modification times are context, not proof of inactivity.

macOS can restrict access even after folder selection. Review scan notes rather than interpreting missing findings as proof that a tool has no data. Terraform state and container volumes must be reviewed and backed up using their owning tools.

The inspection commands follow the [Docker CLI reference](https://docs.docker.com/reference/cli/docker/system/df/) and [Apple container command reference](https://github.com/apple/container/blob/main/docs/command-reference.md). Installed versions may differ.

## Development

Run `make lint` after Swift changes. Build using Xcode MCP BuildProject. Do not run test suites unless explicitly requested (see AGENTS.md).
