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

    # ── bwrap tier: DEFAULT-DENY bind ────────────────────────────────
    test-bwrap-default-deny = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        hj = import ../../lib/hermes-jail.nix { inherit (pkgs) lib; };
        profile = {
          tier = "bwrap";
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

    # ── munix tier: --no-network posture + closure + binds ───────────
    test-munix-no-network = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        hj = import ../../lib/hermes-jail.nix { inherit (pkgs) lib; };
        profile = {
          tier = "munix";
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

    # ── munix tier: DEFAULT-DENY bind (mirror of the bwrap test) ─────
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
          tier = "munix";
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

    # ── munix tier: opt-in store-slice (--store-dev/--sandbox-store) ─
    test-munix-store-slice = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        hj = import ../../lib/hermes-jail.nix { inherit (pkgs) lib; };
        profile = {
          tier = "munix";
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
            image = "/nix/store/fake-researcher-store-erofs";
            sandboxPaths = "/nix/store/fake-closure-info/store-paths";
          };
          extraPackages = [ ];
          env = { };
        };
        launcher = builtins.readFile
          ((hj.mkMunixLauncher pkgs pkgs.hello "researcher" profile) + "/bin/hermes-munix-researcher");
      in
      {
        expr = {
          hasStoreDev = has "--store-dev /nix/store/fake-researcher-store-erofs" launcher;
          hasSandboxStore = has "--sandbox-store /nix/store/fake-closure-info/store-paths" launcher;
          stillHasClosure = has "/nix/store/fake-researcher-toplevel" launcher;
          runsDashP = has "hermes -p researcher" launcher;
        };
        expected = {
          hasStoreDev = true;
          hasSandboxStore = true;
          stillHasClosure = true;
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
          tier = "bwrap";
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
  };
}
