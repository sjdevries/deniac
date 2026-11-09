# lib/tiers.nix — the data-tier contract, as a shared type.
#
# WHY THIS FILE EXISTS
#
# The tier vocabulary (`machine` / `lan` / `global`) has existed as prose
# since the framework draft of 2026-08-30 but nothing typed it.
# `lib/compartment.nix` has no tier field at all; its substitute is a
# comment saying a tmpfs state dir "IS the backup-tier declaration". That
# is a demonstration, not a declaration — it works only because tmpfs is
# the trivial ephemeral case, and it teaches the wrong lesson if copied to
# anything that persists.
#
# This file makes the tier a real type with real consequences, so a tier
# is something you CHECK rather than something you remember.
#
# ONE TAG, THREE RESOLVERS
#
# The tier is not a backup setting with one consumer. It is a single
# declaration read by three independent resolvers:
#
#     tier ──┬──→ persistence resolver  →  local path            (survives reboot)
#            ├──→ replication resolver  →  destination host set  (travels to N)
#            └──→ secret resolver       →  unlock depth           (who can open it)
#
# Only the FIRST choice is free. The other two are DERIVED, because the
# tier describes the copy's EXPOSURE and exposure sets the protection the
# keys need:
#
#   * a `machine` copy never leaves the box  → TPM2 auto-unseal is
#     correct, not lazy. There is no added exposure to defend against.
#   * a `global` copy sits on a disk someone else controls → its keys
#     must not be openable by the machine alone, or the off-site copy is
#     plaintext to whoever holds it.
#
# If a consumer could set `tier = "global"` with a `tpm2`-only unlock, the
# tier would be LYING about its exposure. Deriving instead of offering is
# what keeps the tag meaning what it says.
#
# THE TENSION THIS ENCODES (read this before using `global`)
#
#   `global` replication reach:  "this copy travels off-site."
#   `global` unlock:             "this opens only when the LAN's Tang
#                                server is reachable."
#
# The tier says it travels. The unlock says it only opens at home. A
# `global`-tier disk backed up off-site WILL NOT unseal there. That is
# the intended theft protection — but it means the tier describes where
# copies GO, not whether you can OPEN them there. A `global` tier you
# cannot restore off-LAN is not a backup, it is a hostage. Hence
# `portable` and the assertions below.
#
# WHAT IS DELIBERATELY NOT HERE
#
# No replication mechanism and no secret manager. Per the producer/
# consumer split that makes the backend swappable, a producer emits a
# tier and never learns who consumes it. The functions below return
# DESCRIPTORS, not effects. Wiring them to ZFS send, borg, agenix or
# anything else happens in the consumer, not here.

{ lib }:

let
  inherit (lib) mkOption types;
in
rec {
  # ── the tier itself ────────────────────────────────────────────────
  tierType = types.enum [ "machine" "lan" "global" ];

  tierDescriptions = {
    machine = "Local snapshots only. Never leaves this host.";
    lan     = "Replicated to all LAN NAS hosts. No off-site copy.";
    global  = "Replicated on-site AND off-site. Highest exposure.";
  };

  # ── host mobility ─────────────────────────────────────────────────
  #
  # BEHAVIOURAL, NOT CHASSIS-BASED. A desktop you unplug and carry is
  # `mobile`. A laptop bolted to a desk that never leaves it is
  # `fixed`. Do not derive this from what the machine looks like — derive
  # it from whether it changes networks.
  #
  # NOT THE SAME AXIS AS `portable`, and the two must not be blurred:
  #
  #   mobility  = does the HOST physically travel?      (network presence)
  #   portable  = may the STATE be restored on another HOST?  (key re-wrap)
  #
  # They are orthogonal. A VM image can be `portable` while running on a
  # NAS that never moves; a laptop that is never backed up anywhere is
  # `mobile` but not `portable`.
  mobilityType = types.enum [ "fixed" "mobile" ];

  # ── derived: how a tier's state is unlocked at boot ────────────────
  #
  # NOT independently settable. See the causal rule in the header: the
  # tier's exposure determines the key depth — and mobility determines
  # whether that depth is even *reachable*, because a factor that lives
  # somewhere is useless to a host that has left that somewhere.
  #
  # THE RULE THIS ENCODES:
  #
  #   For a host that moves, the second factor must be something you
  #   CARRY or something you TYPE — never somewhere you ARE.
  #
  # Tang's entire security is that the oracle is somewhere the attacker
  # is not. A mobile host cannot rely on that, because the thing it must
  # prove (network presence) is evaluated in the initrd, before the OS
  # can classify or choose its network — and every workaround that
  # bridges that gap (overlay-in-initrd) makes the machine carry its own
  # path to the oracle, which is not a factor at all.
  #
  # Note that the mobile branch is TIER-INDEPENDENT. On a mobile host the
  # exposure is not scoped by tier: once the disk unlocks, everything on
  # it is readable, not just the tier-tagged data. So mobility overrides
  # the tier here rather than combining with it.
  #
  # `backend` names WHICH TOOL implements the unlock, because the two
  # available tools are not interchangeable (verified 2026-11-09 against
  # the live `systemd-cryptenroll --help` in nixpkgs 26.11):
  #
  #   systemd-cryptenroll  TPM2 (with PCR policy), FIDO2, PKCS#11,
  #                        recovery key, password. NO network oracle of
  #                        any kind — zero matches for tang/oracle/
  #                        network/remote/server in its help output.
  #
  #   clevis               tpm2 pin, tang pin, sss (threshold) pin.
  #                        The ONLY way to get a network oracle.
  #
  # So clevis is NOT replaced by the systemd-native path — it is
  # NARROWED to exactly the one case that needs a network oracle. Every
  # non-`global` unlock is native systemd; `fixed` + `global` is the sole
  # clevis consumer. That keeps the third-party dependency scoped to the
  # single thing upstream cannot do.
  unlockFor = tier: mobility:
    if mobility == "mobile" then {
      method          = "tpm2+human";
      backend         = "systemd-cryptenroll";
      enroll          = "systemd-cryptenroll --tpm2-device=auto --fido2-device=auto $DEV";
      factorClass     = "carried-or-typed";
      tangAllowed     = false;
      requires        = [ "this host's TPM2" "a FIDO2 key or passphrase" ];
      unattended      = false;
      offsiteOpenable = false;
      note            = "Mobile host: Tang is excluded from the unlock path. A place cannot be a factor for a machine that leaves it.";
    } else {
      machine = {
        method          = "tpm2";
        backend         = "systemd-cryptenroll";
        enroll          = "systemd-cryptenroll --tpm2-device=auto $DEV";
        factorClass     = "device";
        tangAllowed     = false;
        requires        = [ "this host's TPM2" ];
        unattended      = true;
        offsiteOpenable = false;   # no off-site copy exists
      };
      lan = {
        method          = "tpm2";
        backend         = "systemd-cryptenroll";
        enroll          = "systemd-cryptenroll --tpm2-device=auto $DEV";
        factorClass     = "device";
        tangAllowed     = false;
        requires        = [ "this host's TPM2" ];
        unattended      = true;
        offsiteOpenable = false;   # no off-site copy exists
      };
      global = {
        method          = "tpm2+tang";
        # The ONLY backend that can express a network oracle. If this
        # ever moves to systemd it means upstream grew a Tang equivalent,
        # which as of 2026-11-09 they have not.
        backend         = "clevis";
        enroll          = "clevis luks bind -d $DEV tpm2 '{}' tang '{\"tgp\":\"http://tang.lan:7654\"}'";
        factorClass     = "place";
        tangAllowed     = true;
        requires        = [ "this host's TPM2" "a reachable Tang server" ];
        unattended      = true;
        # The point of the whole table: an off-site copy of global-tier
        # state cannot be opened off-LAN without the break-glass path.
        offsiteOpenable = false;
      };
    }.${tier};

  # ── stated: what happens when the normal unlock path is gone ───────
  #
  # The uncomfortable conclusion of this file, recorded rather than
  # discovered during an incident: **the tiers that are most convenient to
  # operate are the hardest to recover, and the tier that is easiest to
  # recover is the one you cannot automate.**
  recoveryFor = tier: {
    machine = {
      method   = "escrowed recovery key, or none";
      lossMode = "TOTAL";
      detail   = "A dead TPM2 loses the state unless a recovery key was escrowed out-of-band. Cheapest tier to run, worst recovery: fine for rebuildable state, catastrophic for anything unique.";
    };
    lan = {
      method   = "escrowed recovery key, or the NAS copy";
      lossMode = "TOTAL";
      detail   = "The most commonly misunderstood cell in this table. The NAS copy is encrypted under the NAS's OWN TPM2, not yours — it is NOT your recovery path unless it was re-wrapped for you.";
    };
    global = {
      method   = "passphrase break-glass, or re-wrap onto a new host";
      lossMode = "PARTIAL";
      detail   = "Recoverable only if a break-glass path was declared. If the Tang server's key is the only path, the Tang box is a single point of failure for EVERY off-site restore. Where Tang lives is unresolved and load-bearing: on the LAN it is unreachable exactly when off-site restore is wanted; off-site it is a network-exposed oracle.";
    };
  }.${tier};

  # ── the validation ────────────────────────────────────────────────
  #
  # HOW THIS IS WIRED, AND THE THREE WAYS THAT FAILED FIRST
  #
  # Every one of these failures was SILENT, which is the actual lesson:
  #
  #   1. `rewrap = lib.mkIf (config.portable && config.rewrap == null)
  #        (builtins.throw …)` inside the submodule's `config` is
  #        INFINITE RECURSION — resolving `config.rewrap` forces the
  #        condition, which reads `config.rewrap`.
  #
  #   2. `config.asserts = [ … ]` inside a submodule fails outright:
  #        "The option `d.asserts' does not exist." `asserts` is declared
  #        by a NixOS module, not by `lib.evalModules`, so it is not in
  #        scope inside a bare submodule.
  #
  #   3. `types.addCheck (types.submodule …) f` **does not fire at all.**
  #        Verified with an always-false check: a plain `types.attrs` type
  #        rejects it, the submodule returns the value untouched. The
  #        submodule merge path bypasses the added `check`.
  #
  # What DOES work: an internal option whose default calls the validator,
  # in the FUNCTOR form of the submodule (`{ config, ... }: …`) so
  # `config` is actually in scope — inside a non-functor `options` block
  # it is not, which is why attempt 1 also had a scoping problem hiding
  # behind the recursion.
  #
  # It still has to be FORCED. `resolve` below forces it, so any consumer
  # that goes through the documented entry point is validated. A consumer
  # that reads raw fields without forcing `_validated` is NOT validated —
  # which is why `resolve` is the documented entry point rather than a
  # convenience.
  validateDecl = cfg:
    if cfg.portable && cfg.rewrap == null then
      throw ''
        portable = true requires `rewrap` to name the mechanism that
        re-encrypts this state's key for a new host.

        The tier travels with the declaration; the unlock mechanism does
        not, because TPM2 sealing is per-machine. Without a rewrap path a
        portable ${cfg.tier}-tier declaration describes a VM that cannot
        be opened on any host but the one that made it.

        Either name the mechanism (e.g. rewrap = "agenix-rekey"), or set
        portable = false and accept that this state is host-bound.
      ''
    else if (recoveryFor cfg.tier).lossMode == "TOTAL" && cfg.recoveryReason == "" then
      throw ''
        tier = "${cfg.tier}" has recovery loss mode TOTAL
        (${(recoveryFor cfg.tier).method}).

        Set recoveryReason to one line saying why losing this state is
        acceptable, or move it to a tier with a real recovery path.
        An empty reason is not an answer.

        ${(recoveryFor cfg.tier).detail}
      ''
    else if cfg.mobility == "fixed" && cfg.tier == "global" && cfg.tangPlan == "" then
      throw ''
        mobility = "fixed" with tier = "global" requires `tangPlan` to name
        the Tang deployment, because a single Tang server is a single point
        of failure for EVERY off-site restore.

        Tang is deliberately not a backup: it holds no client data, but
        its own long-term keys are the only thing that can reconstitute
        every binding made against them. Upstream's rotation procedure ends
        with "only delete the old keys when you are sure that no client
        require them anymore. You have been warned." Deleting them
        destroys every still-bound disk, from anywhere, with no recovery
        path.

        Name the plan: how many Tang servers, in which failure domains,
        and the SSS threshold. The minimum defensible answer is two
        servers in separate failure domains, never on the same physical
        medium as the data they protect, under a 1-of-2 threshold.
      ''
    else
      true;

  # ── the declaration ───────────────────────────────────────────────
  #
  # Only `tier` is a free choice. `portable` defaults to false, and
  # setting it true forces the rewrap option to be named — because the
  # tier travels with the declaration while the unlock mechanism is
  # HOST-BOUND (TPM2 is per-machine).
  #
  # Recreating a VM from backup on a different host moves the tier and
  # the replication leg fine and BREAKS the unlock leg. Three ways out:
  #
  #   1. host-agnostic sealing  — kills the theft protection that made
  #      `global` worth its cost.
  #   2. per-host re-wrap       — re-encrypt the key for the new host's
  #      recipients. This is what agenix-rekey does.
  #   3. passphrase tier        — accept human-in-the-loop for anything
  #      that must move.
  #
  # Option 2 is the only one preserving both the tier's exposure
  # semantics and the ability to move.
  stateDeclType = types.submodule ({ config, ... }: {
    options = {
      tier = mkOption {
        type = tierType;
        description = ''
          Replication reach. The one free choice in this declaration.
        '';
      };

      mobility = mkOption {
        type = mobilityType;
        default = "mobile";
        description = ''
          Whether the HOST physically changes networks. Behavioural, not
          chassis-based: a desktop you unplug and carry is `mobile`; a
          laptop bolted to a desk is `fixed`.

          **Defaults to `mobile` — the safe default.** The two ways to
          get this wrong fail very differently:

          * A stationary host wrongly left `mobile` cannot use Tang, so
            it demands a human factor at boot. That fails **loudly and
            immediately** — you notice on the first boot.
          * A travelling host wrongly set `fixed` gets a Tang-derived
            unlock and **bricks the first time it boots somewhere the
            oracle cannot be reached.** That fails **latently and far
            from the mistake** — at a hotel, at 2 a.m.

          So the default is chosen so that the likely error is the one
          you find out about right away. Set `fixed` explicitly for NAS
          boxes and servers that never move.

          Orthogonal to {option}`portable`: that asks whether the STATE
          may be restored on another host (a key re-wrap question); this
          asks whether the HOST travels (a network-presence question).
        '';
      };

      portable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether this state may be restored on a host other than the one
          that created it.

          Defaults to false because that is the conservative answer.
          Setting it true forces the rewrap option to be named: the tier
          travels with the declaration, but the unlock mechanism does
          not, because TPM2 sealing is per-machine.
        '';
      };

      rewrap = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "agenix-rekey";
        description = ''
          The mechanism that re-encrypts this state's key for a new
          host's recipients. Required when {option}`portable` is true.

          Named as a string rather than typed as a submodule on purpose:
          the producer must not couple to a secret manager. This is a
          label the consumer resolves, not a dependency.
        '';
      };

      recoveryReason = mkOption {
        type = types.str;
        default = "";
        description = ''
          Why the declared recovery path is acceptable for this data.

          Required (non-empty) whenever the tier's recovery loss mode is
          TOTAL — which today means `machine` and `lan`. Same rule as
          `allowUnsafeBinds` in the compartment bind guard: an optional
          reason is a reason nobody writes, and if you cannot articulate
          why the loss is acceptable, that is the guard working.
        '';
      };

      tangPlan = mkOption {
        type = types.str;
        default = "";
        example = "2 servers (home + VPS), separate failure domains, SSS 1-of-2, never on the protected medium";
        description = ''
          The Tang deployment backing a `global` tier on a host that never
          moves.

          Required (non-empty) when {option}`mobility` is `fixed` and
          {option}`tier` is `global` — that combination silently depends
          on a Tang server, and a single one is a single point of failure
          for every off-site restore.

          Not required for `mobile` hosts: mobility excludes Tang from
          the unlock path entirely, so there is no oracle to plan.
        '';
      };

      # The guard itself. Internal, and forced by `resolve`.
      #
      # NOTE: this is only evaluated if something forces it. That is a
      # real limitation of a lazy language and it is why `resolve` is the
      # documented entry point: going through it is what makes the check
      # run. Reading raw fields off a declaration bypasses validation.
      _validated = mkOption {
        type = types.raw;
        internal = true;
        default = validateDecl config;
      };
    };

    config = { };
  });

  # ── the composed view a consumer actually wants ────────────────────
  #
  # Pure function: declaration in, full descriptor out. Lets a
  # replication or persistence resolver see all three legs at once
  # without re-deriving them and drifting from this table.
  #
  # This is the DOCUMENTED ENTRY POINT on purpose: the `builtins.seq` on
  # `_validated` is what makes the guard run. A consumer that reads raw
  # fields instead never triggers it.
  resolve = decl:
    builtins.seq decl._validated {
      inherit (decl) tier mobility portable rewrap recoveryReason tangPlan;
      unlock   = unlockFor decl.tier decl.mobility;
      recovery = recoveryFor decl.tier;
    };
}
