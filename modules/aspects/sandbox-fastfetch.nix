# deniac.sandbox.fastfetch — the compartment floor.
#
# This is the SECOND consumer of `lib/compartment.nix`. That is its whole
# reason for existing. Until now the generic compartment shape had exactly
# one consumer (`ai.hermes` via `lib/hermes-jail.nix`), which means the
# shape was untested against anything other than the app it was extracted
# from — a shape with n=1 is indistinguishable from that app's internals.
#
# Every property here is chosen to be as small as possible, so that a
# failure points at the SHAPE rather than at the application:
#
#   * zero binds   — nothing from the host filesystem is visible
#   * zero state   — the state dir is tmpfs; nothing persists across runs
#   * zero network — it prints to stdout and exits
#   * zero config  — no config file, no secrets, no display, no TTY
#
# If a compartment cannot run a program whose entire behaviour is "write
# to stdout", nothing larger in the sandbox family can be trusted. That is
# what makes this the floor rather than an easy first example.
#
# ── the state dir IS the tier declaration ────────────────────────────
# The compartment always creates a state directory, so "no state" is not
# the absence of that directory — it is the directory living somewhere
# that does not survive. Pointing it at tmpfs is the ephemeral tier, and
# it is declared here rather than assumed: an aspect that never says where
# its state goes cannot later be backed up correctly, because a backup
# layer can only read a tier the aspect declared.
#
# ── what changes under munix ─────────────────────────────────────────
# Under bwrap, `fastfetch` reads the HOST's `/etc/os-release` and
# `/proc`, so it reports the real machine. Under munix it runs in a
# microVM and reports the GUEST. Same command, same aspect, different
# answer — which is the boundary made visible: enforcement changes what
# the program can observe, not just what it can write.
#
# Usage:
#   den.aspects.onyxia.includes = [ deniac.sandbox.fastfetch ];
#   den.aspects.onyxia.nixos.deniac.sandbox.fastfetch.enable = true;
#
#   $ den-fastfetch            # compartmentalised, zero host visibility
#
# Inert by default: `enable = false`, so including the aspect changes
# nothing until a host asks for it.

{ lib, ... }:
{
  deniac.sandbox.fastfetch = {
    description = ''
      A compartmentalised `fastfetch`, and the **floor case** for the
      sandbox family: zero binds, zero persistent state, zero network,
      zero configuration. Nothing from the host is visible to it and
      nothing it does survives the run.

      Its purpose is to prove the generic compartment shape in
      `lib/compartment.nix` works for something other than the aspect it
      was extracted from. Every property is minimised on purpose: if the
      jail cannot run a program that only writes to stdout, a failure
      anywhere larger in the family is ambiguous.

      `enforcement` selects the mechanism — `bwrap` (mount namespace, the
      default) or `munix` (KVM microVM). Note the observable difference:
      under bwrap `fastfetch` reports the host, because `/etc` and `/proc`
      are the host's; under munix it reports the guest VM. Enforcement
      changes what a program can *observe*, not only what it can write.

      Inert unless `enable = true`.
    '';

    nixos =
    { config, lib, pkgs, ... }:
    let
      cfg = config.deniac.sandbox.fastfetch;
      c = import ../../lib/compartment.nix { inherit lib; };

      # Ephemeral by declaration, not by accident. See the header note:
      # the location of the state dir IS the backup tier, so it is stated
      # here rather than left to a default. tmpfs means nothing persists,
      # which for a zero-state app is exactly right — and is the same
      # declaration a stateful sandbox member would make differently.
      stateDirExpr = "/tmp/den-sandbox-${cfg.name}";

      launcher =
        if cfg.enforcement == "bwrap" then
          c.mkBwrapCompartment pkgs {
            name = cfg.name;
            label = "den-${cfg.name}";
            stateVar = "SB";
            inherit stateDirExpr;
            homeSubdir = "home";
            command = "${cfg.package}/bin/fastfetch";
            packages = [ cfg.package ];
            # The floor: no binds at all. Not "few" — none. This is the
            # property the test pins, because a stray bind is the one way
            # this example could stop meaning anything.
            bindReadonly = [ ];
            bindReadwrite = [ ];
          }
        else
          c.mkMunixCompartment pkgs {
            name = cfg.name;
            label = "den-${cfg.name}";
            what = "deniac.sandbox.fastfetch";
            stateVar = "SB";
            inherit stateDirExpr;
            homeSubdir = "home";
            munixPackage = cfg.munixPackage;
            closure = cfg.munixClosure;
            command = "fastfetch";
            # Headless and offline: the floor does not need the display
            # channel, so it never asks for the Wayland socket. See the
            # note on `virtFlags` — gpu = true is a security-relevant
            # flip, not a graphics one, and this aspect never takes it.
            network = "none";
            gpu = false;
            # Stated explicitly rather than left to the default, so the
            # floor's reachability is readable at the call site instead of
            # inferred. Empty here means the launcher emits
            # `--no-wayland --no-pipewire` — a deny that shows up in the
            # generated script, not an absence.
            exposure = [ ];
            storeSlice = cfg.storeSlice;
            bindReadonly = [ ];
            bindReadwrite = [ ];
          };
    in
    {
      options.deniac.sandbox.fastfetch = {
        enable = lib.mkOption {
          default = false;
          type = lib.types.bool;
          description = ''
            Install the compartmentalised `fastfetch` launcher as
            `den-fastfetch`. Default false: including the aspect changes
            nothing until a host asks for it.
          '';
        };

        name = lib.mkOption {
          default = "fastfetch";
          type = lib.types.str;
          description = ''
            Compartment identity, used in the launcher name and the state
            dir. Override to run several instances side by side.
          '';
        };

        enforcement = lib.mkOption {
          default = "bwrap";
          type = lib.types.enum [ "bwrap" "munix" ];
          description = ''
            How the compartment is contained. This is `enforcement`, not
            `tier` — the two are unrelated axes: enforcement is HOW a
            sandbox is contained (`bwrap` mount namespace, or `munix` KVM
            microVM), while `tier` is WHERE its data is backed up.

            `bwrap` (default) shares the host kernel and the host's
            `/etc` and `/proc`, so `fastfetch` reports the real machine.

            `munix` boots a microVM from `munixClosure`, so `fastfetch`
            reports the guest instead. Requires `munixClosure` to be set.
          '';
        };

        package = lib.mkOption {
          default = pkgs.fastfetch;
          type = lib.types.package;
          description = ''
            The `fastfetch` package to run inside the compartment.
          '';
        };

        munixPackage = lib.mkOption {
          default = pkgs.munix;
          defaultText = lib.literalExpression "pkgs.munix";
          type = lib.types.package;
          description = ''
            The munix launcher package, used only when
            `enforcement = "munix"`.
          '';
        };

        munixClosure = lib.mkOption {
          default = null;
          type = lib.types.nullOr lib.types.str;
          example = "/nix/store/…-nixos-system-sandbox-toplevel";
          description = ''
            Store path of the NixOS toplevel booted as the guest.
            Required when `enforcement = "munix"`; unused under bwrap.

            This is the store-visibility allowlist: the guest can only
            see what the closure contains, which is why secrets cannot go
            in it — anything baked in is visible to everything that can
            see the closure.
          '';
        };

        storeSlice = lib.mkOption {
          default = null;
          type = lib.types.nullOr (lib.types.enum [ "closure" "erofs" ]);
          description = ''
            Store-slice mode for the munix guest, passed straight to
            `compartment.virtFlags`. `null` uses the compartment
            default. Unused under bwrap.
          '';
        };
      };

      config = lib.mkMerge [
        (lib.mkIf cfg.enable {
          environment.systemPackages = [ launcher ];
        })

        # Fail at eval rather than at run time: a munix enforcement with
        # no closure would produce a launcher that cannot boot, and the
        # failure would surface as a confusing munix error instead of a
        # missing option.
        (lib.mkIf (cfg.enable && cfg.enforcement == "munix" && cfg.munixClosure == null)
          {
            assertions = [{
              assertion = false;
              message = ''
                deniac.sandbox.fastfetch: enforcement is "munix" but munixClosure
                is null. Set `munixClosure` to the store path of the NixOS
                toplevel to boot as the guest, or use enforcement = "bwrap".
              '';
            }];
          })
      ];
    };
  };
}
