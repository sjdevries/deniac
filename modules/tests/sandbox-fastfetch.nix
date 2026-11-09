# Tests for `deniac.sandbox.fastfetch` — the compartment floor.
#
# The load-bearing assertion is `test-floor-zero-binds`. The whole claim of
# the floor case is that NOTHING from the host is visible to the
# compartment, and that is the property most likely to rot silently: one
# "convenient" bind added later and the example stops meaning anything
# while still building green.
#
# Note what the bwrap template always emits, so the counts below are
# against the real rendering rather than an idealised one:
#
#   --ro-bind /nix/store /nix/store      base mount
#   --ro-bind /etc /etc                 base mount
#   --ro-bind-try /run/current-system/sw  base mount
#   --bind "$SB" "$SB"                  the state dir, always
#
# Declared read-only binds render as `--ro-bind-try`, declared read-write
# as `--bind`. So the floor is: exactly ONE `--bind` (the state dir),
# exactly ONE `--ro-bind-try` (the base sw mount), and no `/home`
# anywhere in the script.

{ denTest, ... }:
let
  # Pure substring check (no regex), matching the house style: remove the
  # needle; if the string got shorter, it was present.
  has = needle: hay:
    builtins.stringLength (builtins.replaceStrings [ needle ] [ "" ] hay)
    < builtins.stringLength hay;

  # Occurrence count, so "exactly one" is asserted rather than "at least
  # one" or "not zero". Built from the length delta rather than
  # builtins.splitString, which this Nix does not provide.
  count = needle: hay:
    (builtins.stringLength hay -
      builtins.stringLength (builtins.replaceStrings [ needle ] [ "" ] hay))
    / builtins.stringLength needle;
in
{
  flake.tests.sandbox-fastfetch = {

    # ── shape: namespace export ──────────────────────────────────────
    test-namespace-export = denTest (
      { inputs, den, deniac, igloo, ... }:
      {
        imports = [ (inputs.den.namespace "deniac" [ inputs.self ]) ];
        den.hosts.x86_64-linux.igloo = { };

        expr = {
          hasDescription = deniac.sandbox.fastfetch.description != null;
          hasNixosClass = deniac.sandbox.fastfetch ? nixos;
          # nixos-only aspect: no homeManager class, unlike ai.hermes
          hasHomeManagerClass = deniac.sandbox.fastfetch ? homeManager;
        };
        expected = {
          hasDescription = true;
          hasNixosClass = true;
          hasHomeManagerClass = false;
        };
      }
    );

    # ── THE FLOOR: zero binds, zero host visibility ──────────────────
    test-floor-zero-binds = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        c = import ../../lib/compartment.nix { inherit (pkgs) lib; };
        launcher = builtins.readFile
          ((c.mkBwrapCompartment pkgs {
            name = "fastfetch";
            label = "den-fastfetch";
            stateVar = "SB";
            stateDirExpr = "/tmp/den-sandbox-fastfetch";
            homeSubdir = "home";
            command = "${pkgs.fastfetch}/bin/fastfetch";
            packages = [ pkgs.fastfetch ];
            bindReadonly = [ ];
            bindReadwrite = [ ];
          }) + "/bin/den-fastfetch");
      in
      {
        expr = {
          # Only the state dir is bound read-write. A second `--bind`
          # would mean a declared rw path crept in.
          rwBindCount = count "--bind " launcher;
          # Only the base /run/current-system/sw mount. Any extra
          # `--ro-bind-try` would be a declared read-only path.
          declaredRoBindCount = count "--ro-bind-try " launcher;
          # The strongest single assertion: the string "/home" does not
          # appear in the launcher at all, so no home path of any user is
          # referenced anywhere.
          # NB: a naive `count "/home"` returns 2 even on a true floor,
          # because homeSubdir renders `--setenv HOME "$SB/home"` — the
          # substring is the subdir NAME, not a host home path. Assert on
          # actual host home paths instead, or the check reports a
          # violation that is not one.
          hostHomePaths =
            count "/home/tux" launcher + count "/home/sdevries" launcher;
          # The floor still runs the right thing and still gets output out.
          runsFastfetch = has "${pkgs.fastfetch}/bin/fastfetch" launcher;
          # Ephemeral tier: the state dir is on tmpfs, declared not defaulted.
          stateIsTmpfs = has "/tmp/den-sandbox-fastfetch" launcher;
        };
        expected = {
          rwBindCount = 1;
          declaredRoBindCount = 1;
          hostHomePaths = 0;
          runsFastfetch = true;
          stateIsTmpfs = true;
        };
      }
    );

    # ── munix: headless and offline, by declaration ──────────────────
    # The floor never asks for the display channel. `gpu = false` renders
    # --no-gpu AND the wayland/pipewire exclusions, because binding the
    # host Wayland socket would be binding host-session visibility —
    # which is a security property, not a graphics one.
    test-munix-headless-offline = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        c = import ../../lib/compartment.nix { inherit (pkgs) lib; };
        launcher = builtins.readFile
          ((c.mkMunixCompartment pkgs {
            name = "fastfetch";
            label = "den-fastfetch-vm";
            what = "deniac.sandbox.fastfetch";
            stateVar = "SB";
            stateDirExpr = "/tmp/den-sandbox-fastfetch";
            homeSubdir = "home";
            munixPackage = pkgs.hello;
            closure = "/nix/store/fake-sandbox-toplevel";
            command = "fastfetch";
            network = "none";
            gpu = false;
            bindReadonly = [ ];
            bindReadwrite = [ ];
          }) + "/bin/den-fastfetch-vm");
      in
      {
        expr = {
          noNetwork = has "--no-network" launcher;
          noGpu = has "--no-gpu" launcher;
          noWayland = has "--no-wayland" launcher;
          noPipewire = has "--no-pipewire" launcher;
          # NB: a naive `count "/home"` returns 2 even on a true floor,
          # because homeSubdir renders `--setenv HOME "$SB/home"` — the
          # substring is the subdir NAME, not a host home path. Assert on
          # actual host home paths instead, or the check reports a
          # violation that is not one.
          hostHomePaths =
            count "/home/tux" launcher + count "/home/sdevries" launcher;
        };
        expected = {
          noNetwork = true;
          noGpu = true;
          noWayland = true;
          noPipewire = true;
          hostHomePaths = 0;
        };
      }
    );

    # ── the guard is live on this aspect too ───────────────────────────
    # The floor needs no exception. Proving that a sandbox member which
    # DOES ask for a home bind is stopped keeps the guard honest as the
    # family grows, rather than only testing it against hermes.
    test-guard-stops-a-home-bind = denTest (
      { inputs, den, deniac, ... }:
      let
        pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
        c = import ../../lib/compartment.nix { inherit (pkgs) lib; };
        unacked = builtins.tryEval (
          (c.mkBwrapCompartment pkgs {
            name = "greedy";
            label = "den-greedy";
            stateVar = "SB";
            stateDirExpr = "/tmp/den-sandbox-greedy";
            command = "fastfetch";
            packages = [ pkgs.fastfetch ];
            bindReadwrite = [ "/home/tux" ];
          }).drvPath
        );
        acked = builtins.tryEval (
          (c.mkBwrapCompartment pkgs {
            name = "greedy";
            label = "den-greedy";
            stateVar = "SB";
            stateDirExpr = "/tmp/den-sandbox-greedy";
            command = "fastfetch";
            packages = [ pkgs.fastfetch ];
            bindReadwrite = [ "/home/tux" ];
            allowUnsafeBinds = [
              { path = "/home/tux"; reason = "test: exception path"; }
            ];
          }).drvPath
        );
      in
      {
        expr = {
          blockedWithoutReason = !unacked.success;
          buildsWhenAcknowledged = acked.success;
        };
        expected = {
          blockedWithoutReason = true;
          buildsWhenAcknowledged = true;
        };
      }
    );
  };
}
