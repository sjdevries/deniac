# Ad-hoc verification of lib/tiers.nix assertions.
# Not a denTest — a standalone eval harness for the pure library.
#
#   nix-instantiate --strict --eval -E 'import ./test-tiers.nix'
#
# Each case is a separate file so one throw does not mask the others.

let
  lib = import <nixpkgs/lib>;
  t   = import ./lib/tiers.nix { inherit lib; };

  # The validation is forced by `resolve`, the documented entry point.
  # A shallow `tryEval` on the attrset would not force nested fields, so
  # the deep force here is what makes these cases mean anything.
  evalDecl = d:
    let
      cfg = (lib.evalModules {
        modules = [
          {
            options.d = lib.mkOption { type = t.stateDeclType; };
            config.d  = d;
          }
        ];
      }).config.d;
    in
    t.resolve cfg;

  # NOTE: `builtins.tryEval` only catches errors while forcing the value it
  # is handed. Forcing an attrset does NOT force its fields, so a shallow
  # `tryEval (evalDecl d)` reports success even when a nested option is
  # infinitely recursive. `deepSeq` is what makes these cases actually
  # mean something — without it the harness passes a broken lib.
  case = name: d:
    let
      r = builtins.tryEval (
        builtins.deepSeq (evalDecl d) null
      );
    in
    {
      inherit name;
      ok = r.success;
      msg = if r.success then "accepted" else "threw";
    };

in
{
  # ── should be ACCEPTED ────────────────────────────────────────────
  a_global_portable_rewrap = case "global+portable+rewrap" {
    tier = "global";
    portable = true;
    rewrap = "agenix-rekey";
    recoveryReason = "off-site restore is the whole point of this tier";
  };

  b_machine_not_portable_with_reason = case "machine, not portable, reason given" {
    tier = "machine";
    recoveryReason = "purely rebuildable cache, nothing unique lives here";
  };

  c_lan_not_portable_with_reason = case "lan, not portable, reason given" {
    tier = "lan";
    recoveryReason = "regenerable from the upstream source";
  };

  # ── should THROW ─────────────────────────────────────────────────
  d_portable_no_rewrap = case "portable without rewrap" {
    tier = "global";
    portable = true;
    recoveryReason = "wants portability but named no mechanism";
  };

  e_machine_no_reason = case "machine with no recoveryReason (TOTAL loss)" {
    tier = "machine";
  };

  f_lan_no_reason = case "lan with no recoveryReason (TOTAL loss)" {
    tier = "lan";
  };

  g_bad_tier = case "unknown tier name" {
    tier = "planet";
    recoveryReason = "should not typecheck";
  };
}
