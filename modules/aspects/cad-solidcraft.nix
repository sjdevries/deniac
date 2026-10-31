# deniac.cad.solidcraft — SolidCraft, the pure-Rust parametric 3D CAD app,
# installed from its own pinned upstream flake.
#
# SolidCraft (github.com/tangency-labs/solidcraft) is a clean-room Rust
# parametric CAD: sketch + constraint solver, feature timeline, a B-rep
# kernel built on truck, and four front-ends over one engine — desktop,
# browser (wasm), headless CLI, and an MCP server for agents.
#
# Why this aspect exists: upstream ships a good flake of its own
# (`flake.nix`: `rustPlatform.buildRustPackage` + a `wrapProgram` that
# supplies the dlopen'd Wayland/EGL/dbus libraries). This aspect pins that
# flake, installs the result, and — the part that matters on a managed
# system — sets the environment that makes a Nix install behave like one:
#
#   SOLIDCRAFT_MANAGED_BY=nix   the app stops offering to replace its own
#                               files and points at the package manager
#                               instead (update.rs:286-299).
#   SOLIDCRAFT_UPDATE_CHECK=0   no update GETs at all (update.rs:656,710).
#                               Nix owns updates; the in-app updater is
#                               unsigned today anyway (PUBLIC_KEY = None).
#
# Both default ON for a Nix install, which is the safe direction: a
# package manager that does not own its own updates is not a package
# manager. Flip `checkForUpdates = true` only if you want the nag back.
#
# What this aspect CANNOT do (verified 2026-10-31 against upstream 0.28.0):
#
#   * Force the MCP control channel off. `agent_control` defaults to true,
#     so a stock install listens on 127.0.0.1:27878 at start-up. It is
#     loopback-only, per-launch-token-authenticated (0600 file in a 0700
#     dir) and file-access-scoped, but there is NO environment override —
#     only Preferences > AI. `controlPort` here only relocates it.
#   * Stop `connect_ai_apps` (default true) from adding a `solidcraft` MCP
#     entry to other installed AI clients' config files. Same story: a
#     per-user preference with no environment override.
#   * Suppress either of them in safe mode. Safe mode skips preference loading
#     entirely, so both fall back to their `true` defaults — a user who
#     turned them off gets them back on a `--safe-mode` run. Reported
#     upstream as https://github.com/tangency-labs/solidcraft/issues/10217.
#
# Both are per-user preferences in `app.ron`, which stays user-owned: a
# declarative read-only settings file would break the app's ability to save
# its own preferences. Turn them off in the app, or wait on the upstream
# issue above — if a `SOLIDCRAFT_AGENT_CONTROL` env override lands there,
# it drops straight into `extraWrapperEnv` below with no code change.
#
# Usage (a desktop host that gets SolidCraft):
#
#   den.aspects.desktop.includes = [ deniac.cad.solidcraft ];
#   den.aspects.desktop.nixos.deniac.cad.solidcraft.enable = true;
#
# That is the whole thing — the upstream package already carries the
# .desktop entry, the MIME types and the hicolor icons, so installing it
# into `environment.systemPackages` gives full desktop integration.

{ inputs, lib, ... }:
let
  # Capture the upstream flake now: the `nixos` content below is evaluated
  # later inside the host's nixosSystem eval, where `inputs` is not a
  # module argument.
  solidcraftFlake = inputs.solidcraft;
in
{
  deniac.cad.solidcraft = {
    description = ''
      SolidCraft — the pure-Rust parametric 3D CAD application
      (github.com/tangency-labs/solidcraft) — installed from its own
      pinned upstream flake, with the environment that makes a Nix-managed
      copy behave like one.

      `managedBy` (default "nix") and `checkForUpdates` (default false)
      keep the app from self-updating; `windowSystem` pins Wayland vs
      X11/XWayland; `controlPort` relocates the agent control channel
      (it cannot be disabled from here — see the module comment).
    '';

    nixos =
    { config, lib, pkgs, ... }:
    let
      cfg = config.deniac.cad.solidcraft;

      # The upstream package for this host's system. SolidCraft's flake
      # builds x86_64-linux, aarch64-linux and aarch64-darwin; anything
      # else gets a message that says so instead of "attribute missing".
      upstreamPackage = solidcraftFlake.packages.${pkgs.system} or (builtins.throw ''
        deniac.cad.solidcraft: upstream solidcraft has no package for system
        "${pkgs.system}". Its flake builds x86_64-linux, aarch64-linux and
        aarch64-darwin only.
      '');

      wrapBins = [ "solidcraft" "solidcraft-cli" ];

      # What the knobs above add up to. `wrapperEnv` (below) is this, plus
      # whatever the caller puts in `extraWrapperEnv`.
      derivedEnv =
        (lib.optionalAttrs (cfg.managedBy != null) { SOLIDCRAFT_MANAGED_BY = cfg.managedBy; })
        // (lib.optionalAttrs (!cfg.checkForUpdates) { SOLIDCRAFT_UPDATE_CHECK = "0"; })
        // (lib.optionalAttrs (cfg.windowSystem != null) {
             SOLIDCRAFT_WAYLAND = if cfg.windowSystem == "wayland" then "1" else "0";
           })
        // (lib.optionalAttrs (cfg.controlPort != null) {
             SOLIDCRAFT_CONTROL_PORT = toString cfg.controlPort;
           });

      wrapArgs = lib.concatStringsSep " " (
        lib.mapAttrsToList (k: v: lib.escapeShellArgs [ "--set" k v ]) cfg.wrapperEnv
      );

      # Nothing to inject: use the package as built. Otherwise join it and
      # wrap the two entry points, so the env travels with the program
      # rather than with the whole session.
      finalPackage =
        if cfg.wrapperEnv == { } then
          cfg.package
        else
          pkgs.symlinkJoin {
            name = "solidcraft-wrapped";
            paths = [ cfg.package ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              ${lib.concatMapStrings (bin: ''
                wrapProgram $out/bin/${bin} ${wrapArgs}
              '') wrapBins}
            '';
          };
    in
    {
      options.deniac.cad.solidcraft = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Install SolidCraft on this host.";
        };

        package = lib.mkOption {
          type = lib.types.package;
          default = upstreamPackage;
          defaultText = "inputs.solidcraft.packages.\${system}.solidcraft";
          description = ''
            The SolidCraft package to install. Defaults to the pinned
            upstream flake's package for this host's system. The package
            provides both `bin/solidcraft` (the desktop app) and
            `bin/solidcraft-cli` (headless CLI + MCP server).
          '';
        };

        managedBy = lib.mkOption {
          type = with lib.types; nullOr str;
          default = "nix";
          description = ''
            Value of `SOLIDCRAFT_MANAGED_BY`. When set, the app treats
            this copy as owned by that launcher: the update window points
            at it instead of replacing files in place. `null` leaves the
            variable unset, so the app will offer to self-update.

            Keep this set on a NixOS host — an in-place self-update would
            replace a store-backed binary with something the store does
            not know about.
          '';
        };

        checkForUpdates = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Allow the app's own update check (a GET to GitHub's
            `releases/latest` at start-up and once a day; no identifiers
            or usage data are sent).

            `false` (the default here) sets `SOLIDCRAFT_UPDATE_CHECK=0`,
            which stops the checks entirely — the right setting when Nix
            owns the package. `true` leaves the variable unset so the
            default behaviour applies.
          '';
        };

        windowSystem = lib.mkOption {
          type = with lib.types; nullOr (enum [ "wayland" "x11" ]);
          default = null;
          description = ''
            Pin the window system: `"wayland"` sets `SOLIDCRAFT_WAYLAND=1`,
            `"x11"` sets `SOLIDCRAFT_WAYLAND=0`, `null` (default) leaves
            it unset and lets the app auto-detect.

            The environment variable wins over the app's own
            Preferences > Graphics > Window system. Note that winit has
            no file drag-and-drop on native Wayland, so `"x11"` (through
            XWayland) is what you want if you drop files in from a file
            manager.
          '';
        };

        controlPort = lib.mkOption {
          type = with lib.types; nullOr port;
          default = null;
          description = ''
            Relocate the localhost MCP/agent control channel by setting
            `SOLIDCRAFT_CONTROL_PORT`. `null` (default) leaves it unset,
            so the app uses its own default, 27878.

            This moves the channel; it does NOT close it. Closing it is
            the `agent_control` preference (default on), which has no
            environment override upstream.
          '';
        };

        extraWrapperEnv = lib.mkOption {
          type = with lib.types; attrsOf str;
          default = { };
          description = ''
            Extra environment for the wrapped `solidcraft` and
            `solidcraft-cli` binaries, for variables this aspect does not
            model. Merged over the derived set, so a key here wins.
          '';
        };

        wrapperEnv = lib.mkOption {
          type = with lib.types; attrsOf str;
          default = derivedEnv // cfg.extraWrapperEnv;
          defaultText = "Derived from managedBy / checkForUpdates / windowSystem / controlPort, plus extraWrapperEnv.";
          description = ''
            The environment actually injected into the wrapper: the values
            derived from the options above, merged with `extraWrapperEnv`.
            Read this to see what the wrapper will carry; set
            `extraWrapperEnv` instead of this, so the derived values are
            not replaced wholesale. An empty set means no wrapper is built.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        environment.systemPackages = [ finalPackage ];
      };
    };
  };
}
