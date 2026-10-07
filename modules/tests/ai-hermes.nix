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
  # This nixpkgs has no lib.strings.isInfixOf — use builtins.match with the
  # needle's regex metacharacters escaped and [\s\S]* to span newlines.
  escapeRegex = builtins.replaceStrings
    [ "\\" "." "*" "+" "?" "[" "]" "(" ")" "{" "}" "^" "$" "|" ]
    [ "\\\\" "\\." "\\*" "\\+" "\\?" "\\[" "\\]" "\\(" "\\)" "\\{" "\\}" "\\^" "\\$" "\\|" ];
  has = needle: hay:
    builtins.match ("[\\s\\S]*" + escapeRegex needle + "[\\s\\S]*") hay != null;
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
          (hj.mkBwrapJail pkgs pkgs.hello "researcher" profile) + "/bin/hermes-jailed-researcher";
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
          extraPackages = [ ];
          env = { };
        };
        launcher = builtins.readFile
          (hj.mkMunixLauncher pkgs pkgs.hello "reviewer" profile) + "/bin/hermes-munix-reviewer";
      in
      {
        expr = {
          hasNoNetwork = has "--no-network" launcher;
          hasNoGpu = has "--no-gpu" launcher;
          hasClosure = has "/nix/store/fake-reviewer-toplevel" launcher;
          roBindsRepo = has "--ro-bind /home/tux/work/myrepo" launcher;
          runsDashP = has "hermes -p reviewer" launcher;
        };
        expected = {
          hasNoNetwork = true;
          hasNoGpu = true;
          hasClosure = true;
          roBindsRepo = true;
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
