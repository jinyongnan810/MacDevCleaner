## Mandatory Workflow Rules

> [!IMPORTANT]
> **Code Formatting & Linting Requirement**:
> After you finish updating or editing any Swift code files in this repository, you **MUST** run the following command to format and lint the code:
> ```bash
> make lint
> ```

## Development & Xcode MCP Guidelines

- **Xcode Tooling**: Always use Xcode MCP tools (`BuildProject`, `RunAllTests`, `AddInfoPlist`, `XcodeRM`, etc.) for building, testing, and project configuration.
  - Do not use `xcodebuild` or other command-line tools for building or testing unless explicitly instructed.

## Verification Steps
Before completing any task:
1. Run `make lint` to format all Swift code.
2. Build the project using Xcode MCP (`BuildProject`).
3. Do Not Run test suites unless told to. 