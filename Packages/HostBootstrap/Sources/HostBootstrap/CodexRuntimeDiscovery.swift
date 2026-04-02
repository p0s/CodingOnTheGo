import Foundation
import SharedModels

public struct CodexRuntimeDiscoveryResult: Hashable, Sendable {
    public var runtime: CodexResolvedRuntime
    public var appServerAvailable: Bool
    public var websocketSupported: Bool

    public init(
        runtime: CodexResolvedRuntime,
        appServerAvailable: Bool,
        websocketSupported: Bool
    ) {
        self.runtime = runtime
        self.appServerAvailable = appServerAvailable
        self.websocketSupported = websocketSupported
    }
}

public enum CodexRuntimeDiscovery {
    public static func resolverShell() -> String {
        """
        export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
        resolve_codex_runtime() {
          local candidate
          local version
          local provenance
          local bundle_path
          local help_output
          local -a bundle_candidates
          bundle_candidates=(
            "/Applications/Codex.app/Contents/Resources/codex"
            "$HOME/Applications/Codex.app/Contents/Resources/codex"
          )

          while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            bundle_candidates+=("$candidate")
          done < <(
            {
              if [[ -d /Applications ]]; then
                find /Applications -maxdepth 4 -type f -path '*/Codex.app/Contents/Resources/codex' 2>/dev/null
              fi
              if [[ -d "$HOME/Applications" ]]; then
                find "$HOME/Applications" -maxdepth 4 -type f -path '*/Codex.app/Contents/Resources/codex' 2>/dev/null
              fi
            } | sort -u
          )

          for candidate in "${bundle_candidates[@]}"; do
            [[ -n "$candidate" ]] || continue
            [[ -x "$candidate" ]] || continue
            help_output="$("$candidate" app-server --help 2>/dev/null || true)"
            [[ -n "$help_output" ]] || continue

            if [[ "$candidate" == "/Applications/Codex.app/Contents/Resources/codex" ]] || [[ "$candidate" == "$HOME/Applications/Codex.app/Contents/Resources/codex" ]]; then
              provenance="appBundle"
            else
              provenance="otherAppBundle"
            fi

            version="$("$candidate" --version 2>/dev/null | head -n 1 | tr -d '\\r')"
            bundle_path="${candidate%/Contents/Resources/codex}"
            CODEX_RUNTIME_PATH="$candidate"
            CODEX_RUNTIME_VERSION="$version"
            CODEX_RUNTIME_PROVENANCE="$provenance"
            CODEX_RUNTIME_APP_BUNDLE="$bundle_path"
            CODEX_RUNTIME_HELP="$help_output"
            return 0
          done

          if command -v codex >/dev/null 2>&1; then
            candidate="$(command -v codex)"
            help_output="$("$candidate" app-server --help 2>/dev/null || true)"
            if [[ -n "$help_output" ]]; then
              version="$("$candidate" --version 2>/dev/null | head -n 1 | tr -d '\\r')"
              CODEX_RUNTIME_PATH="$candidate"
              CODEX_RUNTIME_VERSION="$version"
              CODEX_RUNTIME_PROVENANCE="pathFallback"
              CODEX_RUNTIME_APP_BUNDLE=""
              CODEX_RUNTIME_HELP="$help_output"
              return 0
            fi
          fi

          return 1
        }
        """
    }

    public static func summaryCommand() -> String {
        "bash -lc \(shellQuote(summaryScript()))"
    }

    public static func parseSummary(_ output: String) -> CodexRuntimeDiscoveryResult? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let rawLine = String(line)
            guard let separator = rawLine.firstIndex(of: "=") else {
                continue
            }
            let key = String(rawLine[..<separator])
            let value = String(rawLine[rawLine.index(after: separator)...])
            values[key] = value
        }

        guard let binaryPath = values["binaryPath"],
              let provenanceRaw = values["provenance"],
              let provenance = CodexRuntimeBinaryProvenance(rawValue: provenanceRaw) else {
            return nil
        }

        let bundlePath = values["appBundlePath"].flatMap { $0.isEmpty ? nil : $0 }
        let runtime = CodexResolvedRuntime(
            binaryPath: binaryPath,
            version: values["version"].flatMap { $0.isEmpty ? nil : $0 },
            provenance: provenance,
            appBundlePath: bundlePath
        )

        return CodexRuntimeDiscoveryResult(
            runtime: runtime,
            appServerAvailable: true,
            websocketSupported: values["websocketSupported"] == "true"
        )
    }

    private static func summaryScript() -> String {
        """
        \(resolverShell())
        resolve_codex_runtime || exit 1
        printf "binaryPath=%s\\nversion=%s\\nprovenance=%s\\nappBundlePath=%s\\nwebsocketSupported=%s\\n" \
          "$CODEX_RUNTIME_PATH" \
          "$CODEX_RUNTIME_VERSION" \
          "$CODEX_RUNTIME_PROVENANCE" \
          "$CODEX_RUNTIME_APP_BUNDLE" \
          "$( [[ "$CODEX_RUNTIME_HELP" == *"ws://"* ]] && echo true || echo false )"
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
