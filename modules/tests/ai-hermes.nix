# Tests for `ai.hermes`.
#
# The shape test (namespace export) matches the other Home Manager aspects.
# The substantive tests exercise the pure jail/config logic in
# ../../lib/hermes-jail.nix directly with a real `pkgs` and a plain
# profile attrset — so the SECURITY-CRITICAL properties are asserted, not
# just "a homeManager function exists":
#
#   * default-deny: the generated bwrap jail does NOT bind the real home
#     read-write (the old `--bind "$HOME" "$HOME"` is gone).
#   * the agent's HOME is its profile `home/` dir, not the real home.
#   * declared bind dirs appear; the per-profile `-p <name>` is baked in.
#   * the munix launcher maps network="none" to `--no-network` and wires
#     the closure + virtiofs binds.
#   * the store slice emits the right munix flags per mode: `closure`
#     (bind-mount the host store's own bytes, zero extra disk) and
#     `erofs` (the block-device copy), and never mixes the two.
#   * the declared config renders mcp_servers + settings.
#
# Full home-manager activation (the merge actually running against a live
# ~/.hermes) is verified downstream at switch time, as with the other
# homeManager aspects.

{ denTest, ... }:
let
  # Pure substring check (no regex): remove the needle; if the string got
  # shorter, it was present. Avoids this nixpkgs's missing
  # lib.strings.isInfixOf and the POSIX-ERE dotall trap.
  has = needle: hay:
    builtins.stringLength (builtins.replaceStrings [ needle ] [ "" ] hay)
    < builtins.stringLength hay;
in
{
  flake.tests.ai-hermes = {

    # ── shape: namespace export ──────────────────────────────────────
    test-namespace-export = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };

        expr = {
          hasDescription = deniac.ai.hermes.description != null;
          hasHomeManagerClass = builtins.isFunction deniac.ai.hermes.homeManager;
          hasNixosClass = deniac.ai.hermes ? nixos;
        };
        expected = {
          hasDescription = true;
          hasHomeManagerClass = true;
          hasNixosClass = false;
        };
      }
    );

    # ── bwrap: DEFAULT-DENY bind ────────────────────────────────
    test-bwrap-default-deny = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        hj = import ../../lib/hermes-jail.nix { inherit (pkgs) lib; };
        profile = {
          enforcement = "bwrap";
          bindReadonly = [ ];
          bindReadwrite = [ "/home/tux/research-out" ];
          mcpServers = { };
          settings = { };
          soul = null;
          network = "full";
          gpu = false;
          munixPackage = null;
          munixClosure = null;
          extraPackages = [ ];
          env = { };
        };
        jail = builtins.readFile
          ((hj.mkBwrapJail pkgs pkgs.hello "researcher" profile) + "/bin/hermes-jailed-researcher");
      in
      {
        expr = {
          # the real home is NOT bound read-write (neither bare nor braced form)
          noRealHomeBind =
            !(has ''--bind "$HOME"'' jail)
            && !(has ''--bind "''${HOME}"'' jail);
          # the profile home IS bound, and HOME points inside it
          bindsProfileHome = has ''--bind "$PH" "$PH"'' jail;
          homeIsProfileHome = has ''--setenv HOME "$PH/home"'' jail;
          # the declared workspace is bound; the per-profile -p is baked in
          bindsDeclared = has "/home/tux/research-out" jail;
          runsDashP = has "hermes -p researcher" jail;
        };
        expected = {
          noRealHomeBind = true;
          bindsProfileHome = true;
          homeIsProfileHome = true;
          bindsDeclared = true;
          runsDashP = true;
        };
      }
    );

    # ── munix: --no-network posture + closure + binds ───────────
    test-munix-no-network = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        hj = import ../../lib/hermes-jail.nix { inherit (pkgs) lib; };
        profile = {
          enforcement = "munix";
          bindReadonly = [ "/home/tux/work/myrepo" ];
          bindReadwrite = [ ];
          mcpServers = { };
          settings = { };
          soul = null;
          network = "none";
          gpu = false;
          munixPackage = pkgs.hello; # stub for the munix binary path
          munixClosure = "/nix/store/fake-reviewer-toplevel";
          storeSlice = null;
          extraPackages = [ ];
          env = { };
        };
        launcher = builtins.readFile
          ((hj.mkMunixLauncher pkgs pkgs.hello "reviewer" profile) + "/bin/hermes-munix-reviewer");
      in
      {
        expr = {
          hasNoNetwork = has "--no-network" launcher;
          hasNoGpu = has "--no-gpu" launcher;
          hasClosure = has "/nix/store/fake-reviewer-toplevel" launcher;
          roBindsRepo = has "--ro-bind /home/tux/work/myrepo" launcher;
          runsDashP = has "hermes -p reviewer" launcher;
          noStoreFlags = !(has "--store-dev" launcher) && !(has "--sandbox-store" launcher);
        };
        expected = {
          hasNoNetwork = true;
          hasNoGpu = true;
          hasClosure = true;
          roBindsRepo = true;
          runsDashP = true;
          noStoreFlags = true;
        };
      }
    );

    # ── munix: DEFAULT-DENY bind (mirror of the bwrap test) ─────
    # The launcher binds ONLY the declared paths — never the real home,
    # never its root. The store slice limits store *visibility*; this
    # locks the SEPARATE property that host secrets (~/.ssh, ~/.aws,
    # browser profiles) are simply ABSENT from the VM because they are
    # never bound. If mkMunixLauncher ever regressed to binding $HOME or
    # the home root, these assertions fail.
    test-munix-default-deny-binds = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        hj = import ../../lib/hermes-jail.nix { inherit (pkgs) lib; };
        profile = {
          enforcement = "munix";
          bindReadonly = [ "/home/tux/work/myrepo" ];
          bindReadwrite = [ "/home/tux/research-out" ];
          mcpServers = { };
          settings = { };
          soul = null;
          network = "none";
          gpu = false;
          munixPackage = pkgs.hello;
          munixClosure = "/nix/store/fake-researcher-toplevel";
          storeSlice = null;
          extraPackages = [ ];
          env = { };
        };
        launcher = builtins.readFile
          ((hj.mkMunixLauncher pkgs pkgs.hello "researcher" profile) + "/bin/hermes-munix-researcher");
      in
      {
        expr = {
          bindsDeclaredRo = has "--ro-bind /home/tux/work/myrepo" launcher;
          bindsDeclaredRw = has "--bind /home/tux/research-out" launcher;
          # the home ROOT is never bound (only the declared subdirs)
          noHomeRootRw = !(has "--bind /home/tux " launcher);
          noHomeRootRo = !(has "--ro-bind /home/tux " launcher);
          # and no literal $HOME bind either (belt-and-suspenders vs bwrap)
          noDollarHome = !(has ''--bind "$HOME"'' launcher)
            && !(has ''--bind "''${HOME}"'' launcher);
        };
        expected = {
          bindsDeclaredRo = true;
          bindsDeclaredRw = true;
          noHomeRootRw = true;
          noHomeRootRo = true;
          noDollarHome = true;
        };
      }
    );

    # ── bind safety: a home root cannot be bound at all ─────────
    # The check that makes DEFAULT-DENY robust to a typo rather than only
    # to a careful author. Binding `/home/<user>` hands a compartment
    # ~/.ssh, ~/.gnupg, every browser profile and every sibling
    # compartment in one line — a total isolation failure that reads like
    # a convenience setting. These tests pin that such a line fails at
    # EVAL time, before any script is written, AND that ordinary
    # subdirectory binds still pass — so the check cannot be quietly
    # loosened into uselessness, nor tightened until it blocks the
    # legitimate pattern.
    #
    # Exact counts are asserted rather than just "all blocked": emptying
    # the input lists would otherwise turn the test vacuously green.
    test-bind-safety = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        cp = import ../../lib/compartment.nix { inherit (pkgs) lib; };
        blocked = [
          "/"
          "/home"
          "/root"
          "/home/tux"
          "/home/sdevries"
          "~"
          "$HOME"
          "/home/tux/.ssh"
          "/home/tux/.gnupg"
          "/home/tux/.config"
          "/home/tux/.aws"
          "/home/tux/.mozilla"
          "/home/tux/.docker"
        ];
        allowed = [
          "/home/tux/code"
          "/home/tux/research-out"
          "/home/tux/.compartments/hermes-researcher"
          "/var/lib/comfyui"
          "/nix/store"
        ];
        # tryEval so the throw is OBSERVED rather than aborting the suite.
        # .drvPath is selected deliberately: it forces the derivation to be
        # CONSTRUCTED, which forces the rendered script text where the
        # assert lives. A bare tryEval of the returned set stops at WHNF
        # and never reaches it — the guard would look inert while passing.
        homeBind = builtins.tryEval (
          (cp.mkBwrapCompartment pkgs {
            name = "evil";
            stateDirExpr = ''"$HOME/.compartments/evil"'';
            command = "true";
            bindReadwrite = [ "/home/tux" ];
          }).drvPath
        );
        credBind = builtins.tryEval (
          (cp.mkMunixCompartment pkgs {
            name = "evil2";
            stateDirExpr = ''"$HOME/.compartments/evil2"'';
            command = "true";
            munixPackage = pkgs.hello;
            closure = "/nix/store/fake-toplevel";
            bindReadonly = [ "/home/tux/.ssh" ];
          }).drvPath
        );
        # the guard itself, called directly — independent of any builder
        guardDirect = builtins.tryEval (cp.assertSafeBinds {
          bindReadonly = [ ];
          bindReadwrite = [ "/home/tux" ];
          context = "test";
        });
        # and that a clean list does NOT throw, so the guard is not a
        # blanket failure that would break every compartment
        guardClean = builtins.tryEval (cp.assertSafeBinds {
          bindReadonly = [ "/home/tux/work/myrepo" ];
          bindReadwrite = [ "/home/tux/research-out" ];
          context = "test";
        });
        # ── the escape hatch ───────────────────────────────────
        # Naming the exact path AND giving a reason sanctions it.
        guardAckPasses = builtins.tryEval (cp.assertSafeBinds {
          bindReadonly = [ ];
          bindReadwrite = [ "/home/tux" ];
          allowUnsafeBinds = [
            { path = "/home/tux"; reason = "test: sanctioned home bind"; }
          ];
          context = "test";
        });
        # The ack must name THIS path. Acking something else must not
        # unlock anything — otherwise one ack becomes a global bypass.
        guardAckMustMatchExact = builtins.tryEval (cp.assertSafeBinds {
          bindReadonly = [ ];
          bindReadwrite = [ "/home/tux" ];
          allowUnsafeBinds = [
            { path = "/home/tux/elsewhere"; reason = "test: wrong path"; }
          ];
          context = "test";
        });
        # Trailing slash is the same bind on both sides.
        guardAckSlashMatches = builtins.tryEval (cp.assertSafeBinds {
          bindReadonly = [ "/home/tux/" ];
          bindReadwrite = [ ];
          allowUnsafeBinds = [
            { path = "/home/tux"; reason = "test: slash normalisation"; }
          ];
          context = "test";
        });
        # The reason is REQUIRED, not decorative. An ack with no reason
        # fails, so the field cannot be silently skipped — which is the
        # whole point of making it mandatory rather than optional.
        guardMissingReasonThrows = builtins.tryEval (cp.assertSafeBinds {
          bindReadonly = [ ];
          bindReadwrite = [ "/home/tux" ];
          allowUnsafeBinds = [ { path = "/home/tux"; } ];
          context = "test";
        });
        # Whitespace-only is not a reason either.
        guardBlankReasonThrows = builtins.tryEval (cp.assertSafeBinds {
          bindReadonly = [ ];
          bindReadwrite = [ "/home/tux" ];
          allowUnsafeBinds = [ { path = "/home/tux"; reason = "   "; } ];
          context = "test";
        });
        # End-to-end: a compartment builds once the bind is acknowledged.
        bwrapAckBuilds = builtins.tryEval (
          (cp.mkBwrapCompartment pkgs {
            name = "acknowledged";
            stateDirExpr = ''"$HOME/.compartments/ack"'';
            command = "true";
            bindReadwrite = [ "/home/tux" ];
            allowUnsafeBinds = [
              { path = "/home/tux"; reason = "test: end-to-end ack"; }
            ];
          }).drvPath
        );
      in
      {
        expr = {
          blockedCount = builtins.length
            (builtins.filter (p: cp.whyBindUnsafe p != null) blocked);
          allowedCount = builtins.length
            (builtins.filter (p: cp.whyBindUnsafe p == null) allowed);
          # the classifier must not be vacuously true in either direction
          nothingWronglyBlocked = builtins.length
            (builtins.filter (p: cp.whyBindUnsafe p != null) allowed) == 0;
          bwrapHomeBindThrows = !homeBind.success;
          munixCredBindThrows = !credBind.success;
          guardThrowsOnHome = !guardDirect.success;
          guardAllowsOrdinary = guardClean.success && guardClean.value == true;
          # escape hatch: works when named, inert when not
          ackSanctionsExactPath = guardAckPasses.success && guardAckPasses.value == true;
          ackDoesNotUnlockOthers = !guardAckMustMatchExact.success;
          ackNormalisesTrailingSlash = guardAckSlashMatches.success;
          compartmentBuildsWithAck = bwrapAckBuilds.success;
          # the reason is mandatory, not decorative
          missingReasonThrows = !guardMissingReasonThrows.success;
          blankReasonThrows = !guardBlankReasonThrows.success;
        };
        expected = {
          blockedCount = 13;
          allowedCount = 5;
          nothingWronglyBlocked = true;
          bwrapHomeBindThrows = true;
          munixCredBindThrows = true;
          guardThrowsOnHome = true;
          guardAllowsOrdinary = true;
          ackSanctionsExactPath = true;
          ackDoesNotUnlockOthers = true;
          ackNormalisesTrailingSlash = true;
          compartmentBuildsWithAck = true;
          missingReasonThrows = true;
          blankReasonThrows = true;
        };
      }
    );

    # ── munix: store slice, CLOSURE mode (the default) ─────────
    # Closure mode binds each closure path as its own virtiofs submount
    # read straight off the host store: no image is built, so N guests
    # cost zero extra disk. The launcher must emit
    # `--store-mode closure --store-paths <file>` and NOTHING from the
    # erofs path — a stray `--store-dev` flips munix into block-device
    # mode (munix infers it, .munix-wrapped:128-132) and silently puts a
    # multi-gigabyte copy of the closure back on the host per guest.
    # Tested with the mode given explicitly AND omitted, so the lib's own
    # default is pinned too.
    test-munix-store-slice-closure = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        hj = import ../../lib/hermes-jail.nix { inherit (pkgs) lib; };
        base = {
          enforcement = "munix";
          bindReadonly = [ ];
          bindReadwrite = [ ];
          mcpServers = { };
          settings = { };
          soul = null;
          network = "full";
          gpu = false;
          munixPackage = pkgs.hello; # stub for the munix binary path
          munixClosure = "/nix/store/fake-researcher-toplevel";
          extraPackages = [ ];
          env = { };
        };
        explicit = builtins.readFile
          ((hj.mkMunixLauncher pkgs pkgs.hello "researcher" (base // {
            storeSlice = {
              mode = "closure";
              storePaths = "/nix/store/fake-closure-info/store-paths";
            };
          })) + "/bin/hermes-munix-researcher");
        implicit = builtins.readFile
          ((hj.mkMunixLauncher pkgs pkgs.hello "researcher" (base // {
            storeSlice = {
              storePaths = "/nix/store/fake-closure-info/store-paths";
            };
          })) + "/bin/hermes-munix-researcher");
      in
      {
        expr = {
          hasStoreModeClosure = has "--store-mode closure" explicit;
          hasStorePaths =
            has "--store-paths /nix/store/fake-closure-info/store-paths" explicit;
          noStoreDev = !(has "--store-dev" explicit);
          noSandboxStore = !(has "--sandbox-store" explicit);
          # the default (mode omitted) is closure too
          defaultIsClosure =
            has "--store-mode closure" implicit
            && !(has "--store-dev" implicit);
          # the guest closure and the profile selector survive the change
          stillHasClosure = has "/nix/store/fake-researcher-toplevel" explicit;
          runsDashP = has "hermes -p researcher" explicit;
        };
        expected = {
          hasStoreModeClosure = true;
          hasStorePaths = true;
          noStoreDev = true;
          noSandboxStore = true;
          defaultIsClosure = true;
          stillHasClosure = true;
          runsDashP = true;
        };
      }
    );

    # ── munix: store slice, EROFS mode (opt-in) ────────────────
    # The block-device path stays supported as the boot-latency opt-in.
    # It must emit all three flags: munix hard-errors on `--store-mode
    # erofs` without `--store-dev`, and erofs needs `--sandbox-store` for
    # the paths muvm reads pre-activation.
    test-munix-store-slice-erofs = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        hj = import ../../lib/hermes-jail.nix { inherit (pkgs) lib; };
        profile = {
          enforcement = "munix";
          bindReadonly = [ ];
          bindReadwrite = [ ];
          mcpServers = { };
          settings = { };
          soul = null;
          network = "full";
          gpu = false;
          munixPackage = pkgs.hello; # stub for the munix binary path
          munixClosure = "/nix/store/fake-researcher-toplevel";
          storeSlice = {
            mode = "erofs";
            image = "/nix/store/fake-researcher-store-erofs";
            storePaths = "/nix/store/fake-closure-info/store-paths";
          };
          extraPackages = [ ];
          env = { };
        };
        launcher = builtins.readFile
          ((hj.mkMunixLauncher pkgs pkgs.hello "researcher" profile)
            + "/bin/hermes-munix-researcher");
      in
      {
        expr = {
          hasStoreModeErofs = has "--store-mode erofs" launcher;
          hasStoreDev = has "--store-dev /nix/store/fake-researcher-store-erofs" launcher;
          hasSandboxStore =
            has "--sandbox-store /nix/store/fake-closure-info/store-paths" launcher;
          # closure's own flag must NOT leak into the erofs invocation
          noStorePathsFlag = !(has "--store-paths" launcher);
          runsDashP = has "hermes -p researcher" launcher;
        };
        expected = {
          hasStoreModeErofs = true;
          hasStoreDev = true;
          hasSandboxStore = true;
          noStorePathsFlag = true;
          runsDashP = true;
        };
      }
    );

    # ── declared config renders tools + settings ─────────────────────
    test-declared-config = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        hj = import ../../lib/hermes-jail.nix { inherit (pkgs) lib; };
        profile = {
          enforcement = "bwrap";
          bindReadonly = [ ];
          bindReadwrite = [ ];
          mcpServers = {
            donsetch = { command = "donsetch"; args = [ "serve" ]; env = { FOO = "bar"; }; };
          };
          settings = { model = { default = "test-model"; }; };
          soul = null;
          network = "full";
          gpu = false;
          munixPackage = null;
          munixClosure = null;
          extraPackages = [ ];
          env = { };
        };
        cfgJson = hj.declaredConfig "researcher" profile;
      in
      {
        expr = {
          hasMcp = has "donsetch" cfgJson;
          hasArgs = has "serve" cfgJson;
          hasEnv = has "FOO" cfgJson;
          hasSetting = has "test-model" cfgJson;
        };
        expected = {
          hasMcp = true;
          hasArgs = true;
          hasEnv = true;
          hasSetting = true;
        };
      }
    );

    # ── munix: `--` terminator before the guest command ─────────
    # munix parses its OWN options anywhere on the command line, so without
    # a `--` terminator it swallows the hermes flags: `-z` dies with
    # "munix: unknown option: -z", and worse, hermes' `-p <profile>` is
    # consumed by munix's `-p|--publish` — silently turning the profile
    # selector into a port publish. Verified live 2026-10-30.
    test-munix-command-terminator = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        hj = import ../../lib/hermes-jail.nix { inherit (pkgs) lib; };
        profile = {
          enforcement = "munix";
          bindReadonly = [ ];
          bindReadwrite = [ ];
          mcpServers = { };
          settings = { };
          soul = null;
          network = "full";
          gpu = false;
          munixPackage = pkgs.hello;
          munixClosure = "/nix/store/fake-researcher-toplevel";
          storeSlice = null;
          extraPackages = [ ];
          env = { };
        };
        launcher = builtins.readFile
          ((hj.mkMunixLauncher pkgs pkgs.hello "researcher" profile) + "/bin/hermes-munix-researcher");
      in
      {
        expr = {
          # the terminator sits immediately after the closure
          terminatorAfterClosure = has "\"$CLOSURE\" --" launcher;
          # the OLD broken form was `"$CLOSURE" \` — closure followed by a bare
          # line continuation with no terminator. In the fixed form the char
          # right after `"$CLOSURE" ` is `-`, never `\`, so this is false now
          # and was true before. Catches a regression to the unguarded form.
          noBareClosureContinuation = !(has "\"$CLOSURE\" \\" launcher);
          # the guest command is still intact and carries the profile
          guestCommandIntact = has "hermes -p researcher" launcher;
          # and the terminator precedes it (terminator appears, and the only
          # `hermes` occurrence is on the env line after it)
          hermesCount =
            let
              stripped = builtins.replaceStrings [ "hermes -p researcher" ] [ "" ] launcher;
            in
            !(has "hermes -p " stripped);
        };
        expected = {
          terminatorAfterClosure = true;
          noBareClosureContinuation = true;
          guestCommandIntact = true;
          hermesCount = true;
        };
      }
    );

    # ── munix: a headless profile denies wayland + pipewire ───────
    # `--no-gpu` alone still leaves munix binding the host Wayland socket,
    # so a headless host fails pre-boot with
    #   bwrap: Can't find source path $XDG_RUNTIME_DIR/wayland-1
    # This test covers the HEADLESS direction only. The gpu/exposure
    # separation is its own test below, because they are different claims.
    test-munix-headless-flags = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        hj = import ../../lib/hermes-jail.nix { inherit (pkgs) lib; };
        base = {
          enforcement = "munix";
          bindReadonly = [ ];
          bindReadwrite = [ ];
          mcpServers = { };
          settings = { };
          soul = null;
          network = "full";
          munixPackage = pkgs.hello;
          munixClosure = "/nix/store/fake-toplevel";
          storeSlice = null;
          extraPackages = [ ];
          env = { };
        };
        headless = builtins.readFile
          ((hj.mkMunixLauncher pkgs pkgs.hello "r1" (base // { gpu = false; }))
            + "/bin/hermes-munix-r1");
      in
      {
        expr = {
          headlessNoWayland = has "--no-wayland" headless;
          headlessNoPipewire = has "--no-pipewire" headless;
          headlessNoGpu = has "--no-gpu" headless;
        };
        expected = {
          headlessNoWayland = true;
          headlessNoPipewire = true;
          headlessNoGpu = true;
        };
      }
    );

    # ── munix: gpu grants GRAPHICS, never a host surface ──────────
    # This is the regression test for the coupling that `lib/exposure.nix`
    # was written to break.
    #
    # The OLD behaviour — and the previous version of this very test
    # asserted it — was that `gpu = true` OMITTED `--no-wayland` and
    # `--no-pipewire`. In other words: asking for graphics silently
    # granted the host compositor (every window, the clipboard, the
    # keyboard) and the host audio daemon (microphone). A test that
    # pinned that as expected behaviour is itself part of the bug, which
    # is worth saying plainly: a green checkmark on the wrong assertion is
    # worse than no check at all.
    #
    # Now `gpu` controls only `--no-gpu`. Surfaces come from `exposure`,
    # default-empty, and the empty set EMITS the deny flags rather than
    # staying silent — because upstream reads silence as "expose".
    test-munix-gpu-does-not-grant-surfaces = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        hj = import ../../lib/hermes-jail.nix { inherit (pkgs) lib; };
        base = {
          enforcement = "munix";
          bindReadonly = [ ];
          bindReadwrite = [ ];
          mcpServers = { };
          settings = { };
          soul = null;
          network = "full";
          munixPackage = pkgs.hello;
          munixClosure = "/nix/store/fake-toplevel";
          storeSlice = null;
          extraPackages = [ ];
          env = { };
        };
        read = name: attrs: builtins.readFile
          ((hj.mkMunixLauncher pkgs pkgs.hello name attrs) + "/bin/hermes-munix-${name}");
        gpuOnly = read "g1" (base // { gpu = true; });
        gpuWithSurfaces = read "g2"
          (base // { gpu = true; exposure = [ "wayland" "audio" ]; });
        gpuWithWaylandOnly = read "g3" (base // { gpu = true; exposure = [ "wayland" ]; });
      in
      {
        expr = {
          # Graphics granted, surfaces still denied. THE separation.
          gpuAloneStillDeniesWayland = has "--no-wayland" gpuOnly;
          gpuAloneStillDeniesPipewire = has "--no-pipewire" gpuOnly;
          gpuAloneOmitsNoGpu = !(has "--no-gpu" gpuOnly);

          # An explicit grant turns the deny flags off — and only those.
          explicitGrantOmitsWaylandFlag = !(has "--no-wayland" gpuWithSurfaces);
          explicitGrantOmitsPipewireFlag = !(has "--no-pipewire" gpuWithSurfaces);

          # Granting one surface does not leak into the other. Wayland
          # granted, audio still denied: the two are independently named.
          waylandGrantLeavesAudioDenied = has "--no-pipewire" gpuWithWaylandOnly
            && !(has "--no-wayland" gpuWithWaylandOnly);
        };
        expected = {
          gpuAloneStillDeniesWayland = true;
          gpuAloneStillDeniesPipewire = true;
          gpuAloneOmitsNoGpu = true;
          explicitGrantOmitsWaylandFlag = true;
          explicitGrantOmitsPipewireFlag = true;
          waylandGrantLeavesAudioDenied = true;
        };
      }
    );

    # ── the exposure OPTION enforces the closed surface enum ─────────
    # Everything above tests the LIBRARY. This tests that the aspect's
    # DECLARED option actually carries that type. Without it,
    # `exposure = [ "screencopy" ]` in a user's config would be accepted
    # silently and the closed-enum guarantee -- "a surface not named here
    # cannot be granted" -- would be fiction.
    #
    # Two Nix behaviours make this test non-obvious. Both are recorded
    # because they will bite whoever edits it next:
    #
    #   1. `(types.listOf t).check [ bad ]` returns TRUE. `listOf.check`
    #      does NOT delegate to the element type. A test built on `.check`
    #      would pass against `listOf str` and prove nothing at all.
    #
    #   2. `builtins.tryEval` stops at WHNF. Forcing `config.x` yields a
    #      list whose SPINE is fine while its elements are still unevaluated
    #      errors, so tryEval reports SUCCESS on a definition the module
    #      system has actually rejected. The forcing below uses
    #      `concatStringsSep`, which touches every element, so the
    #      rejection is genuinely observed rather than assumed.
    #
    # Verified against this nixpkgs: a real evalModules of a bad element
    # throws "A definition for option ... is not of type `one of "a", "b"`",
    # while `.check` on the same value returns true.
    test-exposure-option-enums-the-surface-set = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        lib = pkgs.lib;
        aspect = import ../../modules/aspects/ai-hermes.nix { inherit inputs lib; };
        hm = aspect.deniac.ai.hermes.homeManager;
        emptyCfg = { deniac.ai.hermes = { }; };
        mod = hm { inherit lib emptyCfg; config = emptyCfg; pkgs = null; };
        profilesType = mod.options.deniac.ai.hermes.profiles.type;

        evalWith = exposureVal: lib.evalModules {
          modules = [
            ({ ... }: {
              options.p = lib.mkOption {
                type = profilesType;
                default = { };
              };
            })
            { p = { probe = { exposure = exposureVal; }; }; }
          ];
        };

        # concatStringsSep forces EVERY element, not just the list spine.
        forceExposure = ev: builtins.tryEval (
          lib.concatStringsSep "," ev.config.p.probe.exposure
        );

        goodSingle = forceExposure (evalWith [ "wayland" ]);
        goodPair = forceExposure (evalWith [ "wayland" "audio" ]);
        goodEmpty = forceExposure (evalWith [ ]);
        badUnknown = forceExposure (evalWith [ "screencopy" ]);
        badOneInList = forceExposure (evalWith [ "wayland" "telepathy" ]);
      in
      {
        expr = {
          acceptsSingleSurface = goodSingle.success;
          acceptsTwoSurfaces = goodPair.success;
          acceptsEmptySet = goodEmpty.success;
          rejectsUnknownSurface = !badUnknown.success;
          rejectsUnknownAmongValid = !badOneInList.success;
        };
        expected = {
          acceptsSingleSurface = true;
          acceptsTwoSurfaces = true;
          acceptsEmptySet = true;
          rejectsUnknownSurface = true;
          rejectsUnknownAmongValid = true;
        };
      }
    );

    # ── declared config: provider inference for a custom base_url ────
    # hermes needs an explicit model.provider; a declared base_url alone
    # fails with ProviderNotConfiguredError. The inference must fill it in
    # WITHOUT ever overriding an explicitly declared provider, and must not
    # invent a model section for profiles that declare none.
    test-declared-config-provider-inference = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        hj = import ../../lib/hermes-jail.nix { inherit (pkgs) lib; };
        base = {
          enforcement = "bwrap";
          bindReadonly = [ ];
          bindReadwrite = [ ];
          mcpServers = { };
          soul = null;
          network = "full";
          gpu = false;
          munixPackage = null;
          munixClosure = null;
          extraPackages = [ ];
          env = { };
        };
        # base_url declared, provider omitted
        inferred = hj.declaredConfig "p1" (base // {
          settings = {
            model = {
              base_url = "https://example.invalid/v1";
              default = "halogen-qwen3.8-flash-next";
            };
          };
        });
        # base_url AND provider declared -> explicit provider wins
        explicit = hj.declaredConfig "p2" (base // {
          settings = {
            model = {
              provider = "openrouter";
              base_url = "https://example.invalid/v1";
              default = "some-model";
            };
          };
        });
        # no model section at all -> untouched
        noModel = hj.declaredConfig "p3" (base // { settings = { }; });
      in
      {
        expr = {
          inferredHasProvider = has "provider" inferred;
          inferredIsCustom = has "custom" inferred;
          explicitKeepsProvider = has "openrouter" explicit;
          explicitNotOverridden = !(has "custom" explicit);
          noModelUntouched = !(has "provider" noModel) && !(has "custom" noModel);
        };
        expected = {
          inferredHasProvider = true;
          inferredIsCustom = true;
          explicitKeepsProvider = true;
          explicitNotOverridden = true;
          noModelUntouched = true;
        };
      }
    );
  };
}
