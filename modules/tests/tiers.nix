# Tests for `deniac.lib.tiers` — the data-tier contract.
#
# The load-bearing assertions are the two GUARD tests. The whole value of
# this lib is that a tier cannot quietly lie about its exposure, and that
# is exactly the property most likely to rot silently: a wiring mistake
# makes the guard inert while everything still evaluates green.
#
# Three wiring attempts failed before the one that works, and every one of
# those failures was SILENT (see the header of lib/tiers.nix):
#
#   1. `rewrap = mkIf (config.portable && config.rewrap == null) (throw …)`
#      inside the submodule → infinite recursion.
#   2. `config.asserts = [ … ]` inside a submodule → "option does not
#      exist"; `asserts` comes from a NixOS module, not `lib.evalModules`.
#   3. `types.addCheck (types.submodule …) f` → **never fires.** Proved
#      with an always-false check: a plain `types.attrs` type rejects it,
#      the submodule hands the value straight back.
#
# What works is an internal `_validated` option in the FUNCTOR form of the
# submodule, forced by `resolve`. So every case here goes through
# `resolve`, and `tryEval` wraps a value forced through it — a bare
# `tryEval` of the returned attrset stops at WHNF, never reaches
# `_validated`, and the guard would look inert while passing.
#
# Counts are asserted rather than "some threw": emptying the case lists
# would otherwise turn the suite vacuously green.

{ denTest, ... }:
{
  flake.tests.tiers = {

    # ── the derived unlock ladder ────────────────────────────────────
    #
    # The causal rule: exposure sets key depth. If `unlock` ever becomes
    # independently settable again, this is what catches it.
    test-derived-unlock = denTest (
      { inputs, den, deniac, ... }:
      let
        t = import ../../lib/tiers.nix { lib = inputs.nixpkgs.lib; };
      in
      {
        expr = {
          machine = (t.unlockFor "machine").method;
          lan     = (t.unlockFor "lan").method;
          global  = (t.unlockFor "global").method;
          # The point of the whole table: an off-site copy of global-tier
          # state cannot be opened off-LAN without break-glass.
          globalOffsiteOpenable = (t.unlockFor "global").offsiteOpenable;
          globalNeedsTang = builtins.elem "a reachable Tang server"
            (t.unlockFor "global").requires;
        };
        expected = {
          machine = "tpm2";
          lan = "tpm2";
          global = "tpm2+tang";
          globalOffsiteOpenable = false;
          globalNeedsTang = true;
        };
      }
    );

    # ── the recovery table is stated, not guessed ─────────────────────
    #
    # `lan` is TOTAL because the NAS copy is encrypted under the NAS's
    # own TPM2. That is the single most misunderstood cell in the model,
    # so it is pinned here rather than left to prose.
    test-recovery-loss-modes = denTest (
      { inputs, den, deniac, ... }:
      let
        t = import ../../lib/tiers.nix { lib = inputs.nixpkgs.lib; };
      in
      {
        expr = {
          machine = (t.recoveryFor "machine").lossMode;
          lan     = (t.recoveryFor "lan").lossMode;
          global  = (t.recoveryFor "global").lossMode;
        };
        expected = {
          machine = "TOTAL";
          lan = "TOTAL";
          global = "PARTIAL";
        };
      }
    );

    # ── guard 1: portable without a rewrap mechanism must not build ──
    #
    # A portable thing with no re-wrap path is a VM that cannot be opened
    # on any host but the one that made it.
    test-portable-requires-rewrap = denTest (
      { inputs, den, deniac, ... }:
      let
        lib = inputs.nixpkgs.lib;
        t = import ../../lib/tiers.nix { inherit lib; };
        evalResolve = d:
          t.resolve
            (lib.evalModules {
              modules = [
                {
                  options.d = lib.mkOption { type = t.stateDeclType; };
                  config.d = d;
                }
              ];
            }).config.d;
        # portable=true with no rewrap, on a tier whose loss mode is not
        # TOTAL, so ONLY the rewrap guard can fire here.
        bad = builtins.tryEval (evalResolve {
          tier = "global";
          portable = true;
          recoveryReason = "off-site restore is the point";
        });
        good = builtins.tryEval (evalResolve {
          tier = "global";
          portable = true;
          rewrap = "agenix-rekey";
          recoveryReason = "off-site restore is the point";
        });
      in
      {
        expr = {
          blockedWithoutRewrap = !bad.success;
          buildsWithRewrap = good.success;
        };
        expected = {
          blockedWithoutRewrap = true;
          buildsWithRewrap = true;
        };
      }
    );

    # ── guard 2: a TOTAL loss mode needs a written reason ─────────────
    #
    # Same rule as allowUnsafeBinds in the compartment bind guard: an
    # optional reason is a reason nobody writes.
    test-total-loss-requires-reason = denTest (
      { inputs, den, deniac, ... }:
      let
        lib = inputs.nixpkgs.lib;
        t = import ../../lib/tiers.nix { inherit lib; };
        evalResolve = d:
          t.resolve
            (lib.evalModules {
              modules = [
                {
                  options.d = lib.mkOption { type = t.stateDeclType; };
                  config.d = d;
                }
              ];
            }).config.d;
        machineNoReason = builtins.tryEval (evalResolve { tier = "machine"; });
        lanNoReason   = builtins.tryEval (evalResolve { tier = "lan"; });
        machineAcked  = builtins.tryEval (evalResolve {
          tier = "machine";
          recoveryReason = "purely rebuildable cache, nothing unique lives here";
        });
      in
      {
        expr = {
          machineBlocked = !machineNoReason.success;
          lanBlocked     = !lanNoReason.success;
          machineAckedBuilds = machineAcked.success;
        };
        expected = {
          machineBlocked = true;
          lanBlocked = true;
          machineAckedBuilds = true;
        };
      }
    );

    # ── the enum is closed ───────────────────────────────────────────
    test-tier-enum-is-closed = denTest (
      { inputs, den, deniac, ... }:
      let
        lib = inputs.nixpkgs.lib;
        t = import ../../lib/tiers.nix { inherit lib; };
        evalResolve = d:
          t.resolve
            (lib.evalModules {
              modules = [
                {
                  options.d = lib.mkOption { type = t.stateDeclType; };
                  config.d = d;
                }
              ];
            }).config.d;
        bogus = builtins.tryEval (evalResolve {
          tier = "planet";
          recoveryReason = "should not typecheck";
        });
      in
      {
        expr = { unknownTierRejected = !bogus.success; };
        expected = { unknownTierRejected = true; };
      }
    );
  };
}
