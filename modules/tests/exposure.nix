# Tests for `deniac.lib.exposure` — the reachability axis.
#
# The load-bearing assertions are the ones that would FAIL against the
# code this replaces. `compartment.nix`'s old line
#
#     headlessFlags = if !gpu then "--no-wayland --no-pipewire" else "";
#
# meant that asking for graphics silently granted the host compositor and
# the host audio daemon. Every test here is written so that a regression
# back to "one flag drives both surfaces" breaks something.
#
# WHY THE DENY FLAGS ARE ASSERTED AS PRESENT, NOT MERELY AS "NOT GRANTED"
#
# Verified 2026-11-09 from the real munix wrapper: munix EXPOSES wayland
# and pipewire unless explicitly told otherwise. So "we did not pass the
# socket" is not a safety property — only the explicit `--no-*` flag is.
# A test that only checked absence of a bind would pass against unsafe
# generated output. These check for the flag itself.

{ denTest, ... }:
{
  flake.tests.exposure = {

    # ── default-deny is EXPLICIT, not silent ─────────────────────────
    test-default-denies-everything = denTest (
      { inputs, den, deniac, ... }:
      let
        e = import ../../lib/exposure.nix { lib = inputs.nixpkgs.lib; };
        f = e.flagsFor { backend = "munix"; exposure = [ ]; };
        has s = builtins.match (".*" + s + ".*") f != null;
      in
      {
        expr = {
          defaultIsEmpty = e.defaultExposure == [ ];
          deniesWayland = has "--no-wayland";
          deniesPipewire = has "--no-pipewire";
          # Both, together — the pair that the old code only emitted when
          # gpu was false.
          deniesBoth = has "--no-wayland" && has "--no-pipewire";
        };
        expected = {
          defaultIsEmpty = true;
          deniesWayland = true;
          deniesPipewire = true;
          deniesBoth = true;
        };
      }
    );

    # ── surfaces are INDEPENDENTLY controllable ───────────────────────
    #
    # This is the property `gpu` could not express. Granting audio must
    # not grant wayland, and vice versa.
    test-surfaces-are-independent = denTest (
      { inputs, den, deniac, ... }:
      let
        e = import ../../lib/exposure.nix { lib = inputs.nixpkgs.lib; };
        has s f = builtins.match (".*" + s + ".*") f != null;

        audioOnly = e.flagsFor { backend = "munix"; exposure = [ "audio" ]; };
        waylandOnly = e.flagsFor { backend = "munix"; exposure = [ "wayland" ]; };
      in
      {
        expr = {
          # audio granted => pipewire NOT denied
          audioGranted = !(has "--no-pipewire" audioOnly);
          # ...but wayland is STILL denied. This is the whole point:
          # granting one surface never leaks into the other.
          waylandStillDenied = has "--no-wayland" audioOnly;

          # and the mirror case
          waylandGranted = !(has "--no-wayland" waylandOnly);
          audioStillDenied = has "--no-pipewire" waylandOnly;
        };
        expected = {
          audioGranted = true;
          waylandStillDenied = true;
          waylandGranted = true;
          audioStillDenied = true;
        };
      }
    );

    # ── THE REGRESSION TEST: graphics must not re-add the sockets ─────
    #
    # The old failure was `gpu = true` silently exposing wayland and
    # pipewire. `flagsFor` takes NO gpu argument at all, so graphics and
    # reachability are structurally separate — there is no code path by
    # which asking for graphics changes the exposure flags.
    #
    # Asserted by showing that with an empty exposure the deny pair is
    # present unconditionally, and that the function's argument set does
    # not include a graphics knob that could override it.
    test-graphics-cannot-reach-the-sockets = denTest (
      { inputs, den, deniac, ... }:
      let
        e = import ../../lib/exposure.nix { lib = inputs.nixpkgs.lib; };
        has s f = builtins.match (".*" + s + ".*") f != null;

        # Same call the old code would have made with gpu = true.
        closed = e.flagsFor { backend = "munix"; exposure = [ ]; };
        # And with everything except the exfiltrating ones granted.
        partial = e.flagsFor { backend = "munix"; exposure = [ "audio" "video" ]; };
      in
      {
        expr = {
          # No exposure declared => both denied, always.
          closedDeniesWayland = has "--no-wayland" closed;
          closedDeniesPipewire = has "--no-pipewire" closed;

          # Granting audio/video (the "I want graphics-ish things" case)
          # still denies wayland.
          partialDeniesWayland = has "--no-wayland" partial;

          # And the function signature itself carries no gpu parameter —
          # calling with one is an error, which is the structural proof.
          rejectsGpuArg =
            builtins.tryEval (e.flagsFor {
              backend = "munix";
              exposure = [ ];
              gpu = true;
            }).success;
        };
        expected = {
          closedDeniesWayland = true;
          closedDeniesPipewire = true;
          partialDeniesWayland = true;
          # Unknown keys are rejected by the destructure, so this must be
          # FALSE. If it ever becomes true, the axis has grown a graphics
          # knob and the separation is gone.
          rejectsGpuArg = false;
        };
      }
    );

    # ── the bwrap path emits nothing ─────────────────────────────────
    test-bwrap-backend-emits-nothing = denTest (
      { inputs, den, deniac, ... }:
      let
        e = import ../../lib/exposure.nix { lib = inputs.nixpkgs.lib; };
      in
      {
        expr = {
          bwrapEmpty = e.flagsFor { backend = "bwrap"; exposure = [ ]; } == "";
          bwrapWithExposureEmpty =
            e.flagsFor { backend = "bwrap"; exposure = [ "audio" "wayland" ]; } == "";
        };
        expected = {
          bwrapEmpty = true;
          bwrapWithExposureEmpty = true;
        };
      }
    );

    # ── the aspirational flag is NOT emitted ──────────────────────────
    #
    # `portals` has no real deny flag upstream yet. The library records
    # that honestly and must NOT emit a flag that does not exist — a
    # launcher full of flags munix would reject is worse than one that
    # admits the gap.
    test-aspirational-flag-not-emitted = denTest (
      { inputs, den, deniac, ... }:
      let
        e = import ../../lib/exposure.nix { lib = inputs.nixpkgs.lib; };
        f = e.flagsFor { backend = "munix"; exposure = [ ]; };
        has s = builtins.match (".*" + s + ".*") f != null;
      in
      {
        expr = {
          noFakeFlag = !(has "--no-doc-portal" f);
          # ...and the gap is still documented, so nobody mistakes the
          # absence for "handled".
          gapIsDocumented =
            builtins.match ".*NOT yet a real flag.*" e.surfaceInfo.portals.risk != null;
        };
        expected = {
          noFakeFlag = true;
          gapIsDocumented = true;
        };
      }
    );

    # ── tier x exposure: the compounding case needs an ack ────────────
    test-global-tier-exfiltration-needs-ack = denTest (
      { inputs, den, deniac, ... }:
      let
        e = import ../../lib/exposure.nix { lib = inputs.nixpkgs.lib; };
      in
      {
        expr = {
          # global + wayland, unacked => throws
          waylandUnacked =
            builtins.tryEval (e.validateExposure {
              tier = "global";
              exposure = [ "wayland" ];
            }).success;

          # global + wayland, acked => fine
          waylandAcked = e.validateExposure {
            tier = "global";
            exposure = [ "wayland" ];
            ack = [ "wayland" ];
            context = "test";
          };

          # global + portals, unacked => throws
          portalsUnacked =
            builtins.tryEval (e.validateExposure {
              tier = "global";
              exposure = [ "portals" ];
            }).success;

          # global + audio only => allowed, audio is not an exfiltration
          # channel in this model
          audioOnlyOk = e.validateExposure {
            tier = "global";
            exposure = [ "audio" ];
            context = "test";
          };

          # lower tiers are unconstrained
          lanWaylandOk = e.validateExposure {
            tier = "lan";
            exposure = [ "wayland" "portals" ];
            context = "test";
          };

          # and the guard is not vacuous — it fires on both surfaces
          exfilList = e.exfiltratingSurfaces;
        };
        expected = {
          waylandUnacked = false;
          waylandAcked = true;
          portalsUnacked = false;
          audioOnlyOk = true;
          lanWaylandOk = true;
          exfilList = [ "wayland" "portals" ];
        };
      }
    );

    # ── the surface enum is closed ────────────────────────────────────
    test-surface-enum-is-closed = denTest (
      { inputs, den, deniac, ... }:
      let
        e = import ../../lib/exposure.nix { lib = inputs.nixpkgs.lib; };
        known = builtins.attrNames e.surfaceInfo;
      in
      {
        expr = {
          # Every known surface is in the enum, and the enum has no
          # surface without an entry. A mismatch means someone added a
          # name without describing its risk.
          allKnownInEnum = builtins.all
            (n: builtins.elem n e.surfaceType.types) known;
          enumFullyDescribed = builtins.all
            (n: builtins.hasAttr n e.surfaceInfo) e.surfaceType.types;
          count = builtins.length known;
        };
        expected = {
          allKnownInEnum = true;
          enumFullyDescribed = true;
          count = 4;
        };
      }
    );

    # ── the audit report is derived, not remembered ───────────────────
    test-describe-reports-both-states = denTest (
      { inputs, den, deniac, ... }:
      let
        e = import ../../lib/exposure.nix { lib = inputs.nixpkgs.lib; };
        d = e.describe { backend = "munix"; exposure = [ "audio" ]; };
        has s = builtins.match ("(?s).*" + s + ".*") d != null;
      in
      {
        expr = {
          showsGranted = has "GRANTED  audio";
          showsDeniedWayland = has "DENIED   wayland";
          showsTheFlag = has "--no-wayland";
        };
        expected = {
          showsGranted = true;
          showsDeniedWayland = true;
          showsTheFlag = true;
        };
      }
    );
  };
}
