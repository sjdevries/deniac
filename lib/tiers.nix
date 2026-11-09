# lib/tiers.nix — the data-tier contract, as a shared type.
#
# WHY THIS FILE EXISTS
#
# The tier vocabulary (`machine` / `lan` / `global`) has existed as prose
# since the framework draft of 2026-08-30, but nothing in this library
# *typed* it. `lib/compartment.nix` has no tier field at all; its current
# substitute is a comment saying a tmpfs state dir "IS the backup-tier
# declaration". That is a demonstration, not a declaration — it works
# only because tmpfs is the trivial ephemeral case, and it teaches the
# wrong lesson if copied to anything that persists.
#
# This file makes the tier a real type with real consequences, so that a
# tier is something you CHECK rather than something you remember.
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
# If a consumer could set `tier = "global"` and `unlock = tpm2-only`, the
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
# `portable` and `recovery` below, and the assertion in `checkStateDecl`.
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

  # ── derived: how a tier's state is unlocked at boot ────────────────
  #
  # NOT independently settable. See the causal rule in the header: the
  # tier's exposure determines the key depth.
  #
  # Returns a descriptor. `requires` names what must be reachable or
  # present at unlock time — that list is the whole reason this table is
  # worth reading before choosing a tier.
  unlockFor = tier: {
    machine = {
      method     = "tpm2";
      requires   = [ "this host's TPM2" ];
      unattended = true;
      offsiteOpenable = false;   # no off-site copy exists
    };
    lan = {
      method     = "tpm2";
      requires   = [ "this host's TPM2" ];
      unattended = true;
      offsiteOpenable = false;   # no off-site copy exists
    };
    global = {
      method     = "tpm2+tang";
      requires   = [ "this host's TPM2" "a reachable Tang server" ];
      unattended = true;
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
  #
  # `db` / vault-tier (TPM2 + passphrase) is not in `tierType` because
  # it is not a replication tier — it is an unlock tier. Where it appears
  # below it is named explicitly so the two vocabularies do not blur.
  recoveryFor = tier: {
    machine = {
      method   = "escrowed recovery key, or none";
      lossMode = "TOTAL — a dead TPM2 loses the state unless a recovery key was escrowed out-of-band.";
      note     = "Cheapest tier to run, worst recovery. Fine for rebuildable state; catastrophic for anything unique.";
    };
    lan = {
      method   = "escrowed recovery key, or the NAS copy";
      lossMode = "TOTAL for this host. The NAS copy is encrypted under the NAS's OWN TPM2, not yours — it is not your recovery path unless it was re-wrapped for you.";
      note     = "The most commonly misunderstood cell in this table. A lan-tier NAS copy is a copy of ciphertext you may not be able to open.";
    };
    global = {
      method   = "passphrase break-glass, or re-wrap onto a new host";
      lossMode = "RECOVERABLE only if a break-glass path was declared. If the Tang server's key is the only path, the Tang box is a single point of failure for EVERY off-site restore.";
      note     = "Where the Tang server lives is unresolved and load-bearing: on the LAN it is unreachable exactly when off-site restore is wanted; off-site it is a network-exposed oracle.";
    };
  }.${tier};

  # ── the declaration ───────────────────────────────────────────────
  #
  # Only `tier` is a free choice. `portable` defaults to false, and
  # setting it true forces the author to name a re-wrap mechanism —
  # because the tier travels with the declaration while the unlock
  # mechanism is HOST-BOUND (TPM2 is per-machine).
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
  stateDeclType = types.submodule ({ name, config, ... }: {
    options = {
      tier = mkOption {
        type = tierType;
        description = ''
          Replication reach. The one free choice in this declaration.
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

          Required (non-empty) whenever {option}`portable` is true or the
          tier's default recovery is `TOTAL`. Same rule as
          `allowUnsafeBinds` in the compartment bind guard: an optional
          reason is a reason nobody writes, and if you cannot articulate
          why the loss is acceptable, that is the guard working.
        '';
      };
    };

    config = {
      # portable without a rewrap mechanism is a thing that cannot
      # actually be restored elsewhere. Fail at eval, not at 3 a.m.
      rewrap = lib.mkIf (config.portable && config.rewrap == null) (
        builtins.throw ''
          deniac tier declaration '${name}': portable = true requires `rewrap` to name the
          mechanism that re-encrypts this state's key for a new host.

          The tier travels with the declaration; the unlock mechanism does
          not, because TPM2 sealing is per-machine. Without a rewrap path,
          a portable ${config.tier}-tier declaration describes a VM that
          cannot be opened on any host but the one that made it.

          Either name the mechanism (e.g. rewrap = "agenix-rekey"), or
          set portable = false and accept that this state is host-bound.
        ''
      );

      # A TOTAL loss mode must be acknowledged in writing.
      recoveryReason = lib.mkIf (
        (config.portable || (recoveryFor config.tier).lossMode == "TOTAL")
        && config.recoveryReason == ""
      ) (
        builtins.throw ''
          deniac tier declaration '${name}': tier = "${config.tier}" has recovery
          loss mode TOTAL (${(recoveryFor config.tier).method}).

          Set recoveryReason to one line saying why losing this state is
          acceptable, or move it to a tier with a real recovery path.
          An empty reason is not an answer.
        ''
      );
    };
  });

  # ── the composed view a consumer actually wants ────────────────────
  #
  # Pure function: declaration in, full descriptor out. Lets a
  # replication or persistence resolver see all three legs at once
  # without re-deriving them and drifting from this table.
  resolve = decl: {
    inherit (decl) tier portable rewrap recoveryReason;
    unlock   = unlockFor decl.tier;
    recovery = recoveryFor decl.tier;
  };
}
