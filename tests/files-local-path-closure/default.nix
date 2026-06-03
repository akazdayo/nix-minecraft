{
  lib,
  pkgs,
  outputs,
  ...
}:

let
  system = pkgs.nixos {
    imports = [ outputs.nixosModules.minecraft-servers ];

    system.stateVersion = "24.11";

    services.minecraft-servers = {
      enable = true;
      eula = true;
      servers.local-path = {
        enable = true;
        package = pkgs.writeShellScriptBin "fake-mc-server" "echo fake";
        managementSystem.tmux.enable = false;
        managementSystem.systemd-socket.enable = true;
        files = {
          "local-text.txt" = ./fixtures/local-text.txt;
          "local-binary.bin" = ./fixtures/local-binary.bin;
          "local-dir" = ./fixtures/local-dir;
          "generated.json".value = {
            ok = true;
          };
        };
        symlinks = {
          "linked-local-text.txt" = ./fixtures/local-text.txt;
          "linked-coreutils" = "${pkgs.coreutils}";
        };
      };
    };
  };

  execStartPre =
    system.config.systemd.services.minecraft-server-local-path.serviceConfig.ExecStartPre;
in
pkgs.runCommand "files-local-path-closure" { nativeBuildInputs = [ pkgs.nix ]; } ''
  set -euo pipefail

  script=${lib.escapeShellArg execStartPre}
  scriptContent="$(cat "$script")"

  echo "ExecStartPre path: $script"
  echo "--- ExecStartPre script content ---"
  cat "$script"
  echo "--- end ExecStartPre script content ---"

  if grep -E -- '-source/.*/?tests/files-local-path-closure/fixtures/local-(text\.txt|binary\.bin|dir)' "$script"; then
    echo "ERROR: ExecStartPre contains raw fixture source paths instead of materialized store outputs" >&2
    exit 1
  fi

  if grep -E -- '-source/.*/?tests/files-local-path-closure/fixtures/local-text\.txt' "$script"; then
    echo "ERROR: symlink target contains raw fixture source path instead of materialized store output" >&2
    exit 1
  fi

  # Assert: generated config (JSON via format.generate) is NOT materialized as minecraft-server-local-path
  if echo "$scriptContent" | grep -q 'generated.json'; then
    echo "generated.json found in script" >&2
    if echo "$scriptContent" | grep 'generated.json' | grep -q 'minecraft-server-local-path'; then
      echo "ERROR: generated.json was incorrectly materialized as local-path derivation" >&2
      exit 1
    fi
  fi

  # Assert: derivation/package path (coreutils) is NOT materialized as minecraft-server-local-path
  if echo "$scriptContent" | grep -q 'linked-coreutils'; then
    echo "linked-coreutils found in script" >&2
    if echo "$scriptContent" | grep 'linked-coreutils' | grep -q 'minecraft-server-local-path'; then
      echo "ERROR: coreutils derivation was incorrectly materialized as local-path derivation" >&2
      exit 1
    fi
  fi

  echo "PASS: Generated config and derivation values not incorrectly materialized" >&2

  # Assert: materialized store outputs present in generated script with correct references
  # After materialization, the script should reference minecraft-server-local-path outputs, not source paths
  materialized_refs="$(echo "$scriptContent" | grep -oP '/nix/store/[a-z0-9]+-minecraft-server-local-path' | sort -u || true)"
  if [ -z "$materialized_refs" ]; then
    echo "ERROR: No materialized minecraft-server-local-path references found in generated script" >&2
    exit 1
  fi

  count="$(echo "$materialized_refs" | wc -l)"
  echo "Materialized references in script: $count" >&2

  if [ "$count" -lt 2 ]; then
    echo "ERROR: Expected at least 2 materialized local-path references, got $count" >&2
    exit 1
  fi

  # Verify materialized outputs exist and contain fixture content
  text_ok=0
  binary_ok=0
  dir_ok=0
  for ref in $materialized_refs; do
    if [ -f "$ref" ] && grep -qF 'motd=@MOTD@' "$ref" 2>/dev/null; then
      text_ok=1
      echo "OK: materialized text fixture verified: $ref" >&2
    fi
    if [ -f "$ref" ] && grep -aqF 'BIN' "$ref" 2>/dev/null; then
      binary_ok=1
      echo "OK: materialized binary fixture verified: $ref" >&2
    fi
    if [ -d "$ref" ] && [ -f "$ref/nested.txt" ] && grep -qF 'nested fixture' "$ref/nested.txt" 2>/dev/null; then
      dir_ok=1
      echo "OK: materialized directory fixture verified: $ref" >&2
    fi
  done

  if [ "$text_ok" -ne 1 ]; then
    echo "ERROR: No materialized output contains text fixture content" >&2
    exit 1
  fi
  if [ "$binary_ok" -ne 1 ]; then
    echo "ERROR: No materialized output contains binary fixture bytes" >&2
    exit 1
  fi
  if [ "$dir_ok" -ne 1 ]; then
    echo "ERROR: No materialized output contains directory fixture" >&2
    exit 1
  fi

  echo "PASS: Materialized output references verified with content assertions" >&2

  mkdir "$out"
''
