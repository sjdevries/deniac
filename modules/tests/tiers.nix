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
          machine = (t.unlockFor "machine" "fixed").method;
          lan     = (t.unlockFor "lan" "fixed").method;
          global  = (t.unlockFor "global" "fixed").method;
          # The point of the whole table: an off-site copy of global-tier
          # state cannot be opened off-LAN without break-glass.
          globalOffsiteOpenable = (t.unlockFor "global" "fixed").offsiteOpenable;
          globalNeedsTang = builtins.elem "a reachable Tang server"
            (t.unlockFor "global" "fixed").requires;
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

    # ── the backend is FORCED by the network need, not chosen ────────
    #
    # Verified 2026-11-09 against the live `systemd-cryptenroll --help`
    # in nixpkgs 26.11. It offers TPM2 (with PCR policy), FIDO2,
    # PKCS#11, recovery key and password — and ZERO network-oracle
    # support (0 matches for tang/oracle/network/remote/server). Tang is
    # a clevis-only capability.
    #
    # So the systemd-native path does NOT replace clevis; it narrows it
    # to the single cell of the table that needs a network oracle.
    # `fixed` + `global` is the only clevis consumer.
    #
    # Pinned so a future refactor cannot silently move the global tier
    # onto a backend that cannot express it — which would fail at the
    # worst possible moment: in the initrd, away from home.
    test-backend-is-forced-by-the-network-need = denTest (
      { inputs, den, deniac, ... }:
      let
        t = import ../../lib/tiers.nix { lib = inputs.nixpkgs.lib; };
        tiers = [ "machine" "lan" "global" ];
      in
      {
        expr = {
          # Everything that needs no network oracle is native systemd.
          machineBackend = (t.unlockFor "machine" "fixed").backend;
          lanBackend     = (t.unlockFor "lan" "fixed").backend;

          # Mobile is tier-independent and never reaches clevis: mobility
          # removes the oracle from the path entirely.
          mobileBackends = map (x: (t.unlockFor x "mobile").backend) tiers;

          # The single clevis cell in the whole table.
          globalBackend = (t.unlockFor "global" "fixed").backend;
          clevisCells   = builtins.filter
            (x: (t.unlockFor x "fixed").backend == "clevis") tiers;

          # The enroll hints name the tool that actually accepts them.
          mobileEnrollIsFido2 =
            builtins.match ".*--fido2-device=auto.*"
              (t.unlockFor "global" "mobile").enroll != null;
          globalEnrollIsClevis =
            builtins.match "clevis luks bind.*"
              (t.unlockFor "global" "fixed").enroll != null;
        };
        expected = {
          machineBackend = "systemd-cryptenroll";
          lanBackend     = "systemd-cryptenroll";
          mobileBackends = [
            "systemd-cryptenroll"
            "systemd-cryptenroll"
            "systemd-cryptenroll"
          ];
          globalBackend = "clevis";
          clevisCells   = [ "global" ];
          mobileEnrollIsFido2 = true;
          globalEnrollIsClevis = true;
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

    # ── mobility removes Tang from a travelling host's unlock path ────
    #
    # THE RULE: for a host that moves, the second factor must be carried
    # or typed, never a place. Tang's whole security is that the oracle is
    # somewhere the attacker is not — a host that leaves cannot rely on
    # that, and every workaround that bridges the initrd gap (overlay in
    # initrd) makes the machine carry its own path to the oracle, which
    # is not a factor at all.
    #
    # Note the mobile branch is TIER-INDEPENDENT: on a mobile host the
    # exposure is not scoped by tier. Once the disk unlocks, everything
    # on it is readable, not just the tier-tagged data.
    test-mobile-excludes-tang = denTest (
      { inputs, den, deniac, ... }:
      let
        t = import ../../lib/tiers.nix { lib = inputs.nixpkgs.lib; };
        mobileGlobal = t.unlockFor "global" "mobile";
        fixedGlobal = t.unlockFor "global" "fixed";
      in
      {
        expr = {
          mobileTangAllowed = mobileGlobal.tangAllowed;
          mobileMethod = mobileGlobal.method;
          mobileFactorClass = mobileGlobal.factorClass;
          mobileNeedsHuman = builtins.elem "a FIDO2 key or passphrase"
            mobileGlobal.requires;
          # The contrast that makes the point: the SAME tier on a host
          # that does not move does get a place-based factor.
          fixedTangAllowed = fixedGlobal.tangAllowed;
          fixedFactorClass = fixedGlobal.factorClass;
          # Mobility overrides rather than combines: every tier goes
          # human-factor on a mobile host.
          mobileMachineMethod = (t.unlockFor "machine" "mobile").method;
          mobileLanMethod = (t.unlockFor "lan" "mobile").method;
        };
        expected = {
          mobileTangAllowed = false;
          mobileMethod = "tpm2+human";
          mobileFactorClass = "carried-or-typed";
          mobileNeedsHuman = true;
          fixedTangAllowed = true;
          fixedFactorClass = "place";
          mobileMachineMethod = "tpm2+human";
          mobileLanMethod = "tpm2+human";
        };
      }
    );

    # ── the default is the SAFE one ───────────────────────────────────
    #
    # mobility defaults to "mobile" deliberately. The two ways to get
    # this wrong fail very differently:
    #
    #   stationary host wrongly left `mobile`  -> cannot use Tang, demands
    #     a human at boot. Fails LOUDLY and IMMEDIATELY.
    #   travelling host wrongly set `fixed`    -> Tang-derived unlock that
    #     BRICKS the first time it boots out of reach. Fails LATENTLY,
    #     FAR FROM THE MISTAKE — at a hotel, at 2 a.m.
    #
    # So the default is chosen so the likely error is the one you find
    # out about right away.
    test-mobility-default-is-the-safe-one = denTest (
      { inputs, den, deniac, ... }:
      let
        lib = inputs.nixpkgs.lib;
        t = import ../../lib/tiers.nix { inherit lib; };
        # A declaration that says nothing about mobility.
        d = (lib.evalModules {
          modules = [
            {
              options.d = lib.mkOption { type = t.stateDeclType; };
              config.d = { tier = "lan"; recoveryReason = "x"; };
            }
          ];
        }).config.d;
      in
      {
        expr = {
          defaultMobility = d.mobility;
          defaultTangAllowed = (t.resolve d).unlock.tangAllowed;
        };
        expected = {
          defaultMobility = "mobile";
          defaultTangAllowed = false;
        };
      }
    );

    # ── a fixed global host must name its Tang plan ───────────────────
    #
    # Tang is deliberately NOT a backup: it holds no client data, but
    # its own long-term keys are the only thing that can reconstitute
    # every binding made against them. A single Tang server is therefore
    # a single point of failure for every off-site restore, and upstream
    # warns that deleting old keys is irreversible. So the combination
    # that silently depends on a Tang — fixed + global — has to say what
    # the deployment actually is.
    test-fixed-global-requires-tang-plan = denTest (
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
        noPlan = builtins.tryEval (evalResolve {
          tier = "global";
          mobility = "fixed";
          recoveryReason = "off-site copy exists";
        });
        withPlan = builtins.tryEval (evalResolve {
          tier = "global";
          mobility = "fixed";
          recoveryReason = "off-site copy exists";
          tangPlan = "2 servers (home + VPS), separate failure domains, SSS 1-of-2";
        });
        # A MOBILE global host needs no plan: mobility excludes Tang from
        # the unlock path entirely, so there is no oracle to plan for.
        mobileNoPlan = builtins.tryEval (evalResolve {
          tier = "global";
          mobility = "mobile";
          recoveryReason = "off-site copy exists";
        });
      in
      {
        expr = {
          missingPlanRejected = !noPlan.success;
          withPlanAccepted = withPlan.success;
          mobileNeedsNoPlan = mobileNoPlan.success;
        };
        expected = {
          missingPlanRejected = true;
          withPlanAccepted = true;
          mobileNeedsNoPlan = true;
        };
      }
    );
  };
}
