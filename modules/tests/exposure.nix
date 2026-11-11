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
        has = s: builtins.match (".*" + s + ".*") f != null;
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
        has = s: f: builtins.match (".*" + s + ".*") f != null;

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
        has = s: f: builtins.match (".*" + s + ".*") f != null;

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

          # The structural proof: `flagsFor` takes exactly backend and
          # exposure. There is NO gpu key in its parameter set, so there
          # is no code path by which asking for graphics can reach the
          # socket flags. Asserted on the signature rather than by
          # catching a call error — `builtins.tryEval` does NOT catch
          # "called with unexpected argument" (verified 2026-11-09), so
          # the earlier version of this test could never have worked.
          paramSet = builtins.functionArgs e.flagsFor;
        };
        expected = {
          closedDeniesWayland = true;
          closedDeniesPipewire = true;
          partialDeniesWayland = true;
          # If a `gpu` key ever appears here, the axis has grown a
          # graphics knob and the separation this test exists to protect
          # is gone.
          paramSet = { backend = true; exposure = true; };
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
        has = s: hay: inputs.nixpkgs.lib.strings.hasInfix s hay;
      in
      {
        expr = {
          noFakeFlag = !(has "--no-doc-portal" f);
          # ...and the gap is still documented, so nobody mistakes the
          # absence for "handled".
          gapIsDocumented =
            inputs.nixpkgs.lib.strings.hasInfix "ASPIRATIONAL"
              e.surfaceInfo.portals.risk;
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
            (builtins.tryEval (e.validateExposure {
              tier = "global";
              exposure = [ "wayland" ];
            })).success;

          # global + wayland, acked => fine
          waylandAcked = e.validateExposure {
            tier = "global";
            exposure = [ "wayland" ];
            ack = [ "wayland" ];
            context = "test";
          };

          # global + portals, unacked => throws
          portalsUnacked =
            (builtins.tryEval (e.validateExposure {
              tier = "global";
              exposure = [ "portals" ];
            })).success;

          # global + audio, unacked => NOW throws.
          #
          # CORRECTION 2026-11-10. This assertion previously read
          # `audioOnlyOk = true` under the comment "audio is not an
          # exfiltration channel in this model". That belief was wrong,
          # and worse than wrong: it was written down and then enforced,
          # so the wrong model was load-bearing and cheap to defend.
          # `surfaceInfo.audio.exfiltrates` says "microphone capture,
          # and playback into the user's session". A microphone on a
          # host holding off-site-replicated state is the compounding
          # case the surrounding comment describes, not an exception to
          # it. The list omission and this assertion were the same error
          # in two places.
          audioUnacked =
            (builtins.tryEval (e.validateExposure {
              tier = "global";
              exposure = [ "audio" ];
            })).success;

          # ...and acking it is the way through, same as every surface.
          audioAcked = e.validateExposure {
            tier = "global";
            exposure = [ "audio" ];
            ack = [ "audio" ];
            context = "test";
          };

          # lower tiers are unconstrained
          lanWaylandOk = e.validateExposure {
            tier = "lan";
            exposure = [ "wayland" "portals" ];
            context = "test";
          };

          # and the guard is not vacuous — it fires on every surface
          # that declares itself exfiltrating. This used to assert the
          # literal [ "wayland" "portals" ], which is precisely how the
          # drift hid: a test pinned the stale list, so widening the
          # real one had to change the test too, and the test looked
          # like it was describing the model rather than lagging it.
          exfilList = e.exfiltratingSurfaces;
        };
        expected = {
          waylandUnacked = false;
          waylandAcked = true;
          portalsUnacked = false;
          audioUnacked = false;
          audioAcked = true;
          lanWaylandOk = true;
          exfilList = [ "audio" "portals" "video" "wayland" ];
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
          # Every described surface is in the declared list, and every
          # declared surface has a description. A mismatch means someone
          # added a name without describing its risk, or described a
          # surface the enum will not accept.
          allKnownDeclared = builtins.all (n: builtins.elem n e.surfaces) known;
          allDeclaredDescribed = builtins.all
            (n: builtins.hasAttr n e.surfaceInfo) e.surfaces;
          count = builtins.length known;
          # The enum is behavioural, not just a list that happens to
          # match: it ACCEPTS every declared surface and REJECTS one that
          # is not declared. That is what makes the set closed.
          enumAcceptsAll = builtins.all (s: e.surfaceType.check s) e.surfaces;
          enumRejectsUnknown = !(e.surfaceType.check "screencopy");
        };
        expected = {
          allKnownDeclared = true;
          allDeclaredDescribed = true;
          count = 4;
          enumAcceptsAll = true;
          enumRejectsUnknown = true;
        };
      }
    );

    # ── the audio/video coupling is REAL, not a modelling slip ────────
    #
    # Upstream carries camera access over the SAME PipeWire socket as
    # audio. There is no separate flag. So granting audio necessarily
    # grants video, and this library must say so rather than pretend it
    # can deny one while allowing the other.
    #
    # This test exists so that if someone "fixes" the coupling in the
    # model without upstream actually separating the sockets, the test
    # tells them the launcher would be lying.
    test-audio-video-cannot-be-separated = denTest (
      { inputs, den, deniac, ... }:
      let
        e = import ../../lib/exposure.nix { lib = inputs.nixpkgs.lib; };
        has = s: f: builtins.match (".*" + s + ".*") f != null;

        audioOnly = e.flagsFor { backend = "munix"; exposure = [ "audio" ]; };
        videoOnly = e.flagsFor { backend = "munix"; exposure = [ "video" ]; };
      in
      {
        expr = {
          # Granting audio clears --no-pipewire, which means video is
          # reachable too. There is no flag that would stop it.
          audioClearsPipewireDeny = !(has "--no-pipewire" audioOnly);
          videoClearsPipewireDeny = !(has "--no-pipewire" videoOnly);

          # Both share the identical deny flag — the coupling, stated.
          sameFlag = e.surfaceInfo.audio.denyFlag == e.surfaceInfo.video.denyFlag;

          # And the coupling is documented, not just implied by the
          # shared flag, so a reader cannot miss it.
          couplingDocumented =
            inputs.nixpkgs.lib.strings.hasInfix "cannot be denied independently"
              e.surfaceInfo.video.risk;
        };
        expected = {
          audioClearsPipewireDeny = true;
          videoClearsPipewireDeny = true;
          sameFlag = true;
          couplingDocumented = true;
        };
      }
    );

    # ── the audit report is derived, not remembered ───────────────────
    test-describe-reports-both-states = denTest (
      { inputs, den, deniac, ... }:
      let
        e = import ../../lib/exposure.nix { lib = inputs.nixpkgs.lib; };
        d = e.describe { backend = "munix"; exposure = [ "audio" ]; };
        has = s: inputs.nixpkgs.lib.strings.hasInfix s d;
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

    # ── the exfiltration list cannot drift from the metadata ──────────
    #
    # REGRESSION TEST. `exfiltratingSurfaces` was hardcoded as
    # [ "wayland" "portals" ] while `surfaceInfo` declared `audio`
    # ("microphone capture") and `video` ("camera capture") as
    # exfiltrating too. Both could be granted on global-tier state with
    # no acknowledgement. The list is now DERIVED from the `exfiltrates`
    # field, so the two cannot disagree.
    #
    # These assertions would all FAIL against the code this replaces,
    # which is what makes them worth having.
    test-exfiltrating-surfaces-are-derived-not-listed = denTest (
      { inputs, den, deniac, ... }:
      let
        l = inputs.nixpkgs.lib;
        e = import ../../lib/exposure.nix { lib = l; };
        declared = l.attrNames (l.filterAttrs (_: v: v ? exfiltrates) e.surfaceInfo);
      in
      {
        expr = {
          # The list IS the set of surfaces that say they exfiltrate.
          matchesMetadata =
            declared == l.sort (a: b: a < b) e.exfiltratingSurfaces;

          # The two that were silently missing.
          audioIncluded = builtins.elem "audio" e.exfiltratingSurfaces;
          videoIncluded = builtins.elem "video" e.exfiltratingSurfaces;

          # Behaviour actually changed, not just the list. global + audio
          # with no ack must now THROW. tryEval is safe here because
          # validateExposure's throw IS the returned expression itself,
          # not a lazily nested value -- forcing the bool forces the throw.
          audioNowNeedsAck = ! (builtins.tryEval (e.validateExposure {
            tier = "global";
            exposure = [ "audio" ];
            ack = [ ];
            context = "drift-test";
          })).success;

          videoNowNeedsAck = ! (builtins.tryEval (e.validateExposure {
            tier = "global";
            exposure = [ "video" ];
            ack = [ ];
            context = "drift-test";
          })).success;

          # Acking satisfies it -- the gate is acknowledgement, not a ban.
          audioAckedPasses = (builtins.tryEval (e.validateExposure {
            tier = "global";
            exposure = [ "audio" ];
            ack = [ "audio" ];
            context = "drift-test";
          })).success;

          # Non-global tiers are untouched by this rule.
          lanTierStillQuiet = (builtins.tryEval (e.validateExposure {
            tier = "lan";
            exposure = [ "audio" "video" ];
            ack = [ ];
            context = "drift-test";
          })).success;
        };
        expected = {
          matchesMetadata = true;
          audioIncluded = true;
          videoIncluded = true;
          audioNowNeedsAck = true;
          videoNowNeedsAck = true;
          audioAckedPasses = true;
          lanTierStillQuiet = true;
        };
      }
    );
  };
}
