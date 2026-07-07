{ pkgs, nix-stubs, nixStubsLib }:

let
  inherit (nixStubsLib) mkLazyPackage mkManifest;
  inherit (pkgs) lib;

  # Simple test tool for exec tests
  testPkg = pkgs.writeShellScriptBin "lazy-test-tool" ''echo "lazy-test-output-success"'';

  # Tool with bash/zsh completions
  testPkgWithCompletion = pkgs.runCommand "lazy-complete-tool" {} ''
    mkdir -p $out/bin $out/share/bash-completion/completions $out/share/zsh/site-functions

    cat > $out/bin/lazy-complete-tool <<'SCRIPT'
#!/bin/sh
case "$1" in
  --help) echo "Usage: lazy-complete-tool [--verbose] [--output FILE] [--help]" ;;
  *) echo "lazy-complete-output-success" ;;
esac
SCRIPT
    chmod +x $out/bin/lazy-complete-tool

    cat > $out/share/bash-completion/completions/lazy-complete-tool <<'COMP'
_lazy_complete_tool() {
  local cur="''${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=( $(compgen -W "--verbose --output --help" -- "$cur") )
}
complete -F _lazy_complete_tool lazy-complete-tool
COMP

    cat > $out/share/zsh/site-functions/_lazy-complete-tool <<'ZSH'
#compdef lazy-complete-tool
_arguments \
  '--verbose[Enable verbose output]' \
  '--output[Output file]:filename:_files' \
  '--help[Show help]'
ZSH
  '';

  # Shim packages
  testShim = mkLazyPackage {
    package = testPkg;
    commands = [ "lazy-test-tool" ];
    name = "lazy-test-tool";
  };

  completionShim = mkLazyPackage {
    package = testPkgWithCompletion;
    commands = [ "lazy-complete-tool" ];
    name = "lazy-complete-tool";
  };

  # Manifest for hook-env
  manifest = mkManifest {
    lazy-test-tool = { package = testPkg; commands = [ "lazy-test-tool" ]; };
    lazy-complete-tool = { package = testPkgWithCompletion; commands = [ "lazy-complete-tool" ]; };
  };

  testPkgOutPath = builtins.unsafeDiscardStringContext (toString testPkg);
  completionPkgOutPath = builtins.unsafeDiscardStringContext (toString testPkgWithCompletion);

  # Nix expression for a dynamic derivation — instantiated at runtime in the VM
  # to test the slow path (realization on first use).
  # Uses builtins.storePath to add coreutils as a build input so mkdir/chmod
  # are available in the sandbox.
  dynamicTestNix = pkgs.writeText "dynamic-test.nix" ''
    derivation {
      name = "dynamic-test-tool";
      builder = "/bin/sh";
      args = [
        "-c"
        "mkdir -p $out/bin && printf '#!/bin/sh\necho dynamic-test-success\n' > $out/bin/dynamic-test-tool && chmod +x $out/bin/dynamic-test-tool"
      ];
      system = builtins.currentSystem;
      __noChroot = true;
      PATH = "/run/current-system/sw/bin:/usr/bin:/bin";
    }
  '';

in pkgs.testers.nixosTest {
  name = "nix-stubs-integration";

  nodes.machine = { config, pkgs, ... }: {
    virtualisation.memorySize = 2048;

    environment.systemPackages = [
      nix-stubs
      testShim
      completionShim
      pkgs.bash
      pkgs.zsh
    ];

    nix.settings = {
      experimental-features = [ "nix-command" ];
      # Disable substituters to avoid cache.nixos.org DNS lookups in the VM
      substituters = lib.mkForce [];
      # Allow __noChroot for the dynamic test derivation
      sandbox = "relaxed";
    };

    environment.etc = {
      "nix-stubs-manifest.json".source = manifest;
      "dynamic-test.nix".source = dynamicTestNix;
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # =========================================================
    # Test 1: Shim executes tool correctly (fast path)
    # =========================================================
    with subtest("shim executes tool correctly"):
        # Verify shim exists and is executable
        machine.succeed("test -x $(which lazy-test-tool)")

        # Run the shim — verifies the exec flow works
        result = machine.succeed("lazy-test-tool")
        assert "lazy-test-output-success" in result, f"Expected output not found: {result}"

    # =========================================================
    # Test 1b: THE lazy guarantee — the shim's closure must NOT contain the
    # realised package. (Regression: embedding --out-path as a literal store path
    # in the shim made Nix's reference scanner re-add the full package as a runtime
    # dep, defeating laziness. The shim carries only the .drv now.)
    # =========================================================
    with subtest("shim closure EXCLUDES the realised package"):
        shim = machine.succeed("readlink -f $(which lazy-test-tool)").strip()
        # The shim is a symlink into the lazy-* symlinkJoin; walk to its real store
        # path and query its runtime references.
        refs = machine.succeed(f"nix-store -q --references $(nix-store -q --deriver {shim} >/dev/null 2>&1; echo {shim}) 2>/dev/null || nix-store -q --requisites {shim}")
        # The full test package OUTPUT must not be a runtime dependency of the shim.
        assert "${testPkgOutPath}" not in refs, \
            f"LEAK: the shim's closure contains the realised package ${testPkgOutPath}:\n{refs}"
        # But the .drv (or its inputs) MUST be present so it can be realised offline.
        drv_present = machine.succeed(f"nix-store -q --requisites {shim} | grep -c '\\.drv$' || true").strip()
        assert int(drv_present) >= 1, "expected the package .drv in the shim closure"

    # =========================================================
    # Test 2: Slow path — nix-stubs exec realizes a new derivation
    # =========================================================
    with subtest("slow path realization"):
        # Instantiate the dynamic derivation (creates .drv without building)
        drv_path = machine.succeed("nix-instantiate /etc/dynamic-test.nix").strip()

        # Get the output path
        out_path = machine.succeed(f"nix-store -q --outputs {drv_path}").strip()

        # Verify the output does NOT exist yet
        machine.succeed(f"test ! -e {out_path}")

        # Use nix-stubs exec to realize and run it
        result = machine.succeed(
            f"nix-stubs exec --drv-path {drv_path} dynamic-test-tool"
        )
        assert "dynamic-test-success" in result, f"Expected output not found: {result}"

        # Verify the output now exists
        machine.succeed(f"test -e {out_path}")

    # =========================================================
    # Test 3: exec with --drv-path only (no --out-path)
    # =========================================================
    with subtest("exec with drv-path only"):
        result = machine.succeed(
            "nix-stubs exec --drv-path ${testPkg.drvPath} lazy-test-tool"
        )
        assert "lazy-test-output-success" in result, f"Expected output not found: {result}"

    # =========================================================
    # Test 4: hook-env updates PATH
    # =========================================================
    with subtest("hook-env updates PATH"):
        # Ensure both packages are realized
        machine.succeed("lazy-test-tool >/dev/null")
        machine.succeed("lazy-complete-tool >/dev/null")

        # Call hook-env with a minimal PATH that doesn't include the real binary dirs
        new_path = machine.succeed(
            "PATH=/usr/bin:/run/current-system/sw/bin nix-stubs hook-env --manifest /etc/nix-stubs-manifest.json"
        ).strip()

        # Verify the real binary dirs are in the new PATH
        assert "${testPkgOutPath}/bin" in new_path, \
            f"Expected testPkg bin dir in PATH: {new_path}"
        assert "${completionPkgOutPath}/bin" in new_path, \
            f"Expected completionPkg bin dir in PATH: {new_path}"

        # Verify running with the updated PATH uses the real binary
        result = machine.succeed(
            f"PATH={new_path} lazy-test-tool"
        )
        assert "lazy-test-output-success" in result

        # Verify which finds the real binary (not the shim)
        which_result = machine.succeed(
            f"PATH={new_path} which lazy-test-tool"
        ).strip()
        assert "${testPkgOutPath}/bin/lazy-test-tool" == which_result, \
            f"Expected real binary path, got: {which_result}"

    # =========================================================
    # Test 5: hook-env is idempotent (no output when PATH already has dirs)
    # =========================================================
    with subtest("hook-env idempotent"):
        # Call hook-env with PATH already containing the bin dirs
        result = machine.succeed(
            "PATH=${testPkgOutPath}/bin:${completionPkgOutPath}/bin:/run/current-system/sw/bin "
            "nix-stubs hook-env --manifest /etc/nix-stubs-manifest.json"
        ).strip()
        assert result == "", f"Expected empty output for idempotent call, got: {result}"

    # =========================================================
    # Test 6: Shell activation integration
    # =========================================================
    with subtest("shell activation - bash"):
        activate_output = machine.succeed(
            "nix-stubs activate bash --manifest /etc/nix-stubs-manifest.json --shim-dir /tmp/shims"
        )
        assert "PROMPT_COMMAND" in activate_output, \
            f"Expected PROMPT_COMMAND in bash activation: {activate_output}"
        assert "__nix_stubs_hook" in activate_output

    with subtest("shell activation - zsh"):
        activate_output = machine.succeed(
            "nix-stubs activate zsh --manifest /etc/nix-stubs-manifest.json --shim-dir /tmp/shims"
        )
        assert "precmd_functions" in activate_output, \
            f"Expected precmd_functions in zsh activation: {activate_output}"

    with subtest("shell activation - eval in bash"):
        # Eval the activation in bash and trigger the hook
        result = machine.succeed(
            """bash -c '
              eval "$(nix-stubs activate bash --manifest /etc/nix-stubs-manifest.json --shim-dir /tmp/shims)"
              __nix_stubs_hook
              echo "$PATH"
            '"""
        ).strip()
        assert "${testPkgOutPath}/bin" in result, \
            f"Expected real binary in PATH after hook: {result}"

    # =========================================================
    # Test 7: Completions work after realization
    # =========================================================
    with subtest("completions after realization"):
        # Ensure the completion package is realized
        machine.succeed("lazy-complete-tool >/dev/null")

        # Verify bash completion file exists
        machine.succeed(
            "test -f ${completionPkgOutPath}/share/bash-completion/completions/lazy-complete-tool"
        )

        # Source the completion file and verify compgen works
        result = machine.succeed(
            """bash -c '
              source ${completionPkgOutPath}/share/bash-completion/completions/lazy-complete-tool
              compgen -W "--verbose --output --help" -- "--v"
            '"""
        ).strip()
        assert "--verbose" in result, f"Expected --verbose in completions: {result}"

        # Verify zsh completion function file exists
        machine.succeed(
            "test -f ${completionPkgOutPath}/share/zsh/site-functions/_lazy-complete-tool"
        )

    # =========================================================
    # Benchmark: hook-env latency
    # =========================================================
    with subtest("benchmark hook-env latency"):
        # Warm up
        machine.succeed(
            "nix-stubs hook-env --manifest /etc/nix-stubs-manifest.json >/dev/null 2>&1 || true"
        )

        # Time 100 invocations
        result = machine.succeed(
            """bash -c '
              start=$(date +%s%N)
              for i in $(seq 1 100); do
                nix-stubs hook-env --manifest /etc/nix-stubs-manifest.json >/dev/null 2>&1 || true
              done
              end=$(date +%s%N)
              elapsed_ms=$(( (end - start) / 1000000 ))
              per_call_us=$(( (end - start) / 100000 ))
              echo "hook-env: 100 calls in ''${elapsed_ms}ms (''${per_call_us}us/call)"
            '"""
        ).strip()
        print(f"BENCHMARK: {result}")

    # =========================================================
    # Benchmark: shim overhead (fast path, already realized)
    # =========================================================
    with subtest("benchmark shim overhead"):
        # Ensure package is realized
        machine.succeed("lazy-test-tool >/dev/null")

        # Time shim path (through nix-stubs exec)
        shim_time = machine.succeed(
            """bash -c '
              start=$(date +%s%N)
              for i in $(seq 1 100); do
                lazy-test-tool >/dev/null
              done
              end=$(date +%s%N)
              elapsed_ms=$(( (end - start) / 1000000 ))
              per_call_us=$(( (end - start) / 100000 ))
              echo "shim: 100 calls in ''${elapsed_ms}ms (''${per_call_us}us/call)"
            '"""
        ).strip()

        # Time direct path (no shim)
        direct_time = machine.succeed(
            """bash -c '
              start=$(date +%s%N)
              for i in $(seq 1 100); do
                ${testPkgOutPath}/bin/lazy-test-tool >/dev/null
              done
              end=$(date +%s%N)
              elapsed_ms=$(( (end - start) / 1000000 ))
              per_call_us=$(( (end - start) / 100000 ))
              echo "direct: 100 calls in ''${elapsed_ms}ms (''${per_call_us}us/call)"
            '"""
        ).strip()

        print(f"BENCHMARK: {shim_time}")
        print(f"BENCHMARK: {direct_time}")
  '';
}
