# lib/exposure.nix — what a compartment may REACH, as opposed to where its
# data GOES.
#
# WHY THIS IS A SEPARATE AXIS AND NOT PART OF `tier`
#
# `lib/tiers.nix` answers two questions: where does this state get
# replicated (`tier`), and does the host travel (`mobility`). Both are
# about DATA. Neither answers the question this file answers:
#
#     which host surfaces may the compartment reach?
#
# These are orthogonal. A compartment can have a perfectly tiered disk and
# still be handed the host compositor, the host audio daemon and the
# desktop portal. Storage correctness tells you nothing about
# reachability, and reachability is where the actual leaks are.
#
# THE FACT THAT MOTIVATED THIS (verified 2026-11-09 against the real
# `munix` wrapper in the store, /nix/store/frpgr5v8rmsxvb97525qs9n6icvf23zz-munix/bin/munix):
#
#   **munix EXPOSES by default.** Wayland and PipeWire are bound into the
#   guest unless you explicitly pass `--no-wayland` / `--no-pipewire`:
#
#       if [ "$WAYLAND" -eq 1 ]; then
#         BWRAP_ARGS+=("--bind" "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ...)
#
#   There is no "off unless asked" state upstream. The only way to be
#   closed is to SAY so, per surface, every time.
#
#   And the bind is the RAW HOST SOCKET — not proxied, not filtered. The
#   filtering components (`wl-cross-domain-proxy`, `wl-backdrop`) exist
#   and are reachable via `--wl-proxy-bin-dir` / `--wl-backdrop-bin-dir`,
#   but the default path hands the guest the compositor itself.
#
# CONSEQUENCE FOR THIS LIBRARY
#
#   **Default-deny here means EMITTING THE DENY FLAG, not omitting it.**
#   Omitting is what upstream reads as "expose". So `flagsFor` emits an
#   explicit deny for every surface the caller did not name. That makes
#   the denial visible in the generated launcher — auditable by reading
#   the script — instead of depending on a default that runs the opposite
#   way.
#
# WHAT REPLACED
#
#   This supersedes `compartment.nix`'s `headlessFlags`:
#
#       headlessFlags = if !gpu then "--no-wayland --no-pipewire" else "";
#
#   That line made the exposure of the two most sensitive host surfaces a
#   SIDE EFFECT of a crash workaround (munix dies on a headless host
#   without them), and it failed in the bad direction: asking for
#   graphics silently granted the host compositor and the host audio
#   daemon. Here, `gpu` and `exposure` are orthogonal and `exposure` is
#   authoritative.
#
# THE POLICY SHAPE
#
#   * Default: the empty set. A compartment reaches nothing.
#   * Every surface is NAMED. No flag grants two things. In particular
#     graphics never implies audio.
#   * Un-selected surfaces get an explicit deny flag, not silence.
#   * Exposure is the EXFILTRATION surface, so it is checked against the
#     tier: high-reach state plus an interactive host channel requires an
#     explicit ack, in the same shape as `allowUnsafeBinds`.

{ lib }:
rec {
  # ── the surfaces ───────────────────────────────────────────────────
  #
  # Deliberately a CLOSED enum. A surface that is not named here cannot be
  # granted, which means adding one is a deliberate act with a diff, not
  # a string someone typed.
  #
  # Declared as a list first so the enum and the description set are
  # derived from ONE source. A test asserts they never drift.
  surfaces = [ "audio" "video" "wayland" "portals" ];

  surfaceType = lib.types.enum surfaces;

  # What each surface actually is, what it costs, and how it is denied.
  #
  # `denyFlag` is the verified real munix flag (read from the wrapper
  # source 2026-11-09). `rawBind` records what upstream binds when the
  # surface IS granted by default — kept here because it is the thing a
  # reader needs to understand the risk, and because it is what the
  # runtime probe checks for.
  surfaceInfo = {
    audio = {
      denyFlag = "--no-pipewire";
      rawBind = "$PIPEWIRE_RUNTIME_DIR/pipewire-0";
      risk = ''
        The host PipeWire socket, bound raw. ~360k lines of not-really-
        audited C reachable from the guest, with a demonstrated sandbox
        escape (CVE-2026-5674, Embrace The Red). Audio is not a
        peripheral; it is a host daemon the guest is permitted to talk
        to. Upstream issue #35 asks for virtio-snd instead.
      '';
      exfiltrates = "microphone capture, and playback into the user's session";
    };

    video = {
      denyFlag = "--no-pipewire";   # cameras ride the same socket upstream
      rawBind = "$PIPEWIRE_RUNTIME_DIR/pipewire-0 (media.stream video)";
      risk = ''
        Camera access is carried by the SAME PipeWire socket as audio, so
        it cannot be denied independently today — denying audio denies
        video and vice versa. Upstream issue #19 is about this socket
        hiding cameras inconsistently.
      '';
      exfiltrates = "camera capture";
    };

    wayland = {
      denyFlag = "--no-wayland";
      rawBind = "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY";
      risk = ''
        The RAW HOST COMPOSITOR SOCKET. Wayland exposes every window to
        every connected client by default, so a guest holding this can
        see — and with the screencopy protocol, capture — everything on
        the user's desktop: banking, mail, other compartments.

        The filtering components exist upstream (wl-cross-domain-proxy,
        wl-backdrop) but the default path does not use them. Upstream
        issue #36 is precisely this, and the stated plan is a Qubes-style
        frame that does NOT trust the compositor to filter.
      '';
      exfiltrates = "every window on the host desktop, including other compartments";
    };

    portals = {
      denyFlag = "--no-doc-portal";   # NOT yet a real flag — see note
      rawBind = "$XDG_RUNTIME_DIR/munix.$$ -> /mnt/munix-doc-portal";
      risk = ''
        The xdg-desktop-portal document portal, backed by sidebus. The
        per-run bind is scoped to a fresh $XDG_RUNTIME_DIR/munix.$$
        directory, which looks safe — but the broker REUSES the documents
        database from the host's $XDG_DATA_HOME, so documents registered
        by PREVIOUS runs remain addressable from the new guest.

        Reported upstream as issue #37: a screenshot opened in another
        app a week earlier was still visible at
        /mnt/munix-doc-portal/doc. Root-caused by the author at
        clan/sidebus sidebus-broker/src/main.rs#L148.

        NOTE: there is no `--no-doc-portal` flag upstream yet. This
        denyFlag is ASPIRATIONAL and `flagsFor` will NOT emit it — it is
        recorded so the gap is explicit rather than silently missing.
        Until it exists, `portals` can only be withheld by not starting
        the broker, which is not expressible through the CLI.
      '';
      exfiltrates = "files from OTHER applications, persisted across VM runs";
    };
  };

  # ── the default: nothing ───────────────────────────────────────────
  #
  # An empty set is the safe value and the one every aspect should start
  # from. Anything else is a deliberate grant with a diff attached.
  defaultExposure = [ ];

  # ── render a surface set into backend flags ────────────────────────
  #
  # THE LOAD-BEARING RULE: every surface NOT in `exposure` emits its deny
  # flag. Silence means "expose" upstream, so silence is unsafe here.
  #
  # GRANT PRECEDENCE. Two surfaces can share a deny flag — upstream
  # carries camera access over the SAME PipeWire socket as audio, so
  # `video` and `audio` both deny via `--no-pipewire`. The rule is:
  #
  #     a GRANTED surface suppresses its deny flag, even if another,
  #     ungranted surface shares that flag.
  #
  # That is not a shortcut — it is the honest encoding of a real upstream
  # limitation. **You cannot grant audio while denying video**, because
  # they are one socket. Pretending otherwise would produce a launcher
  # that claims a control it does not have. The coupling is stated in
  # `surfaceInfo.video.risk` and pinned by a test.
  #
  # `backend` is checked because this only applies to the VM path; a
  # bwrap compartment has no wayland/pipewire plumbing of its own and
  # would be handed meaningless flags.
  flagsFor =
    { backend ? "munix"
    , exposure ? [ ]
    }:
    if backend != "munix" then
      ""
    else
      let
        # Flags that granted surfaces turn OFF.
        grantedFlags = map (s: surfaceInfo.${s}.denyFlag)
          (builtins.filter (s: builtins.elem s surfaces) exposure);

        # Flags that ungranted surfaces turn ON.
        deniedFlags = map (s: surfaceInfo.${s}.denyFlag)
          (builtins.filter (s: !(builtins.elem s exposure)) surfaces);

        # Aspirational flags are recorded but never emitted: `portals` has
        # no real munix flag yet (#37's fix lives in clan/sidebus, not
        # the CLI). Emitting a flag munix would reject is worse than
        # admitting the gap.
        realFlags = fs: builtins.filter (f: !lib.strings.hasPrefix "--no-doc-portal" f) fs;

        grantedReal = realFlags grantedFlags;
        # Emit an ungranted surface's deny flag only if no GRANTED
        # surface suppressed that same flag (grant precedence).
        toEmit = builtins.filter (f: !(builtins.elem f grantedReal))
          (realFlags deniedFlags);
      in
      lib.concatStringsSep " " (lib.sort (a: b: a < b) toEmit);

  # ── the tier interaction ───────────────────────────────────────────
  #
  # Exposure is the EXFILTRATION side of the model. Tier is the
  # REPLICATION side. A compartment that holds high-reach state AND has
  # an interactive host channel is the compounding case: the data is
  # valuable because it travels, and there is a live channel out.
  #
  # So: `global`-tier state plus a surface that can carry data OUT of
  # the guest requires an explicit ack, in the same shape as
  # `allowUnsafeBinds` in compartment.nix. Not forbidden — acknowledged,
  # named, and visible in the diff.
  exfiltratingSurfaces = [ "wayland" "portals" ];

  validateExposure =
    { tier ? null
    , exposure ? [ ]
    , ack ? [ ]
    , context ? "compartment"
    }:
    let
      offending =
        if tier != "global" then [ ]
        else builtins.filter (s: builtins.elem s exfiltratingSurfaces) exposure;

      unacked = builtins.filter (s: !(builtins.elem s ack)) offending;
    in
    if unacked == [ ] then true else
      throw ''
        ${context}: a compartment holding `global`-tier state declares
        exfiltrating exposure: ${lib.concatStringsSep ", " unacked}.

        `global` means this state is replicated off-site. Wayland and the
        document portal are channels that carry data OUT of the guest —
        wayland exposes every host window, and the doc portal reuses the
        host's document database across runs (upstream #36 / #37).

        That combination is the compounding case: valuable data, plus a
        live path out. It is allowed, but only if named.

        To proceed deliberately:
            exposureAck = [ ${lib.concatStringsSep " " (map (s: "\"${s}\"") unacked)} ];

        To close it instead, drop the surface:
            exposure = [ ${lib.concatStringsSep " " (builtins.filter (s: !(builtins.elem s exfiltratingSurfaces)) exposure)} ];
      '';

  # ── audit helper ───────────────────────────────────────────────────
  #
  # Renders what a compartment can actually reach, as a human-readable
  # report. The point is that the answer is DERIVED from the config
  # rather than remembered, so a reviewer can check the claim instead of
  # trusting it.
  describe =
    { exposure ? [ ]
    , backend ? "munix"
    }:
    let
      granted = map (s: "  GRANTED  ${s} — ${surfaceInfo.${s}.exfiltrates}") exposure;
      denied = lib.mapAttrsToList (s: info:
        "  DENIED   ${s} — ${if backend == "munix" then "explicit ${info.denyFlag}" else "n/a for ${backend}"}"
      ) (lib.filterAttrs (n: _: !(builtins.elem n exposure)) surfaceInfo);
    in
    lib.concatStringsSep "\n" (granted ++ denied);
}
