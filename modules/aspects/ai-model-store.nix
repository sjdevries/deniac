# deniac.ai.model-store — shared AI model store (substrate).
#
# Provisions ONE shared model directory tree that the inference aspects
# (ai.gufo, ai.comfyui, and future engines) all mount, so weights are
# stored once, downloaded once, and backed up once — the deniac take on
# the Stability Matrix "shared model root" pattern.
#
# This is a SUBSTRATE aspect: it owns the filesystem substrate (shared
# group + directory tree + permissions + the shared HuggingFace cache
# location). It runs NO service. Consumers point their model paths into
# it and bind-mount read-only.
#
# TIER — "precious bulk" (archive), NOT cache.
# Model weights are treated as precious: re-download is NOT guaranteed
# (platform concentration — the NVIDIA→HuggingFace close pending H1 2027;
# model takedowns / re-licensing / link-rot). So the store contents are
# BACKUP-tier: checksummed, off-site, ideally mirrored off-platform.
# But they are large, so the store lives off the hot impermanent /persist
# root. Provision the `root` on a backed-up mount; this aspect creates the
# directory structure but cannot enforce the mount or the backup — that
# is host-level.
#
# Usage:
#   den.aspects.igloo.includes = [ deniac.ai.model-store ];
#   den.aspects.igloo.nixos.deniac.ai.model-store.enable = true;
#   # consumers:
#   den.aspects.igloo.nixos.deniac.ai.gufo.modelsDir =
#     den.aspects.igloo.nixos.deniac.ai.model-store.paths.llm;

{ lib, ... }:
{
  deniac.ai.model-store = {
    description = ''
      Shared AI model store — a filesystem substrate that all local AI
      aspects mount, so weights are stored once, downloaded once, and
      backed up once (the Stability Matrix "shared model root" pattern,
      in deniac). Provisions a shared group, a directory tree under
      `root` following a fixed subdir convention, and the shared
      HuggingFace cache location (`hfCache`, for content-addressed
      download dedup). Runs no service.

      TIER: "precious bulk" / archive. Weights are treated as precious —
      re-download is not guaranteed (platform concentration, model
      takedowns / re-licensing / link-rot) — so the store is BACKUP-tier:
      checksummed, off-site, ideally mirrored off-platform. It stays off
      the hot impermanent /persist root for size. Provision `root` on a
      backed-up mount; this aspect creates the structure but cannot
      enforce the mount or the backup (host-level).

      Consumers (ai.gufo, ai.comfyui, …) read the derived `paths` and
      bind-mount the relevant subdir read-only. The content-addressed
      HF cache gives integrity + dedup for free; capture a per-file
      SHA256 manifest at download time while the upstream is still
      cross-checkable.
    '';

    nixos =
    { config, lib, pkgs, ... }:
    let
      cfg = config.deniac.ai.model-store;
      # A declared model is a fixed-output derivation: fetched once by
      # hash, content-addressed, and — because the store-tree symlink
      # points at its outPath — part of the system closure (so Nix keeps
      # it alive). `nixos-rebuild` is the download; a peer substituter
      # can serve the bytes instead of the origin.
      fetchModel = m:
        pkgs.fetchurl {
          inherit (m) url sha256;
          name = m.name;
        };
    in
    {
      options.deniac.ai.model-store = {
        enable = lib.mkOption {
          default = false;
          type = lib.types.bool;
          description = ''
            Provision the shared store (group + directory tree + HF cache
            dir). Inert by default.
          '';
        };

        root = lib.mkOption {
          default = "/var/lib/ai-models";
          type = lib.types.str;
          description = ''
            The shared store root. Provision this on a BACKED-UP mount
            (archive tier) — not the hot impermanent /persist root, and
            not tmpfs. All subdirs and the HF cache live under it.
          '';
        };

        group = lib.mkOption {
          default = "aimodels";
          type = lib.types.str;
          description = ''
            Shared group that owns the store. Inference service users
            (gufo, comfyui, …) join this group for read access; a
            download helper in the group can populate it. The store dirs
            are group-writable on the host; consumers bind-mount them
            read-only into containers.
          '';
        };

        hfCache = lib.mkOption {
          default = cfg.root + "/.hf-cache";
          type = lib.types.str;
          description = ''
            The shared HuggingFace cache (`HF_HOME`) — content-addressed
            blobs, so the same weights are fetched once across every tool
            that uses `hf download`. Defaults to a hidden dir under
            `root` (follows a `root` override). Tools that read files by
            path (gufo) are populated from here via hardlinks.
          '';
        };

        subdirs = lib.mkOption {
          default = [ "llm" "image" "video" "audio" "loras" "vae" "text_encoders" "gguf" ];
          type = lib.types.listOf lib.types.str;
          description = ''
            The fixed layout convention — a superset that satisfies both
            ComfyUI's opinionated subdir names and plain path-based
            engines. Exposed to consumers via the derived `paths`
            attrset.
          '';
        };

        paths = lib.mkOption {
          readOnly = true;
          default = lib.listToAttrs (map
            (s: { name = s; value = cfg.root + "/" + s; })
            cfg.subdirs);
          description = ''
            Derived read-only map of subdir name → absolute path, for
            consumers to reference instead of hardcoding (e.g.
            `paths.llm`, `paths.image`). Resolves regardless of
            `enable` (it is just a path computation); consumers must
            include this aspect for the option to exist.
          '';
        };

        models = lib.mkOption {
          type = lib.types.listOf (lib.types.submodule {
            options = {
              name = lib.mkOption {
                type = lib.types.str;
                description = "Filename to link into the store subdir.";
              };
              subdir = lib.mkOption {
                type = lib.types.enum cfg.subdirs;
                description = "Which store subdir to link into.";
              };
              url = lib.mkOption {
                type = lib.types.str;
                description = "Download URL (the source's resolve URL).";
              };
              sha256 = lib.mkOption {
                type = lib.types.str;
                description = "Fixed-output checksum (nix-prefetch-url / source API).";
              };
            };
          });
          default = [ ];
          description = ''
            Declarative model inventory — the "StabilityMatr[n]ix"
            registry. Each entry is fetched as a fixed-output derivation
            and symlinked into <root>/<subdir>/<name>. Because the
            symlink target is the derivation outPath, the model is part
            of the system closure: nixos-rebuild IS the download, Nix
            keeps it alive, and content-addressing dedups the same bytes
            across every host/aspect that references them. Gated
            (authenticated) sources are fetched via the add-time helper
            so the secret never enters the store (see research §8.4).
          '';
        };
      };

      config =
        lib.mkMerge [
          (lib.mkIf cfg.enable {
            # The shared group (mkDefault: a host that defines it itself
            # wins).
            users.groups.${cfg.group} = lib.mkDefault { };

            # Provision root + every subdir + the HF cache as PERSISTENT
            # directories (tmpfiles `d`, not tmpfs), group-owned and
            # group-writable so a download helper in the group can
            # populate them. Consumers bind-mount read-only.
            #
            # The store is archive-tier: these dirs must sit on a
            # backed-up mount (see `root`). tmpfiles only creates the
            # structure; it does not back it up.
            systemd.tmpfiles.rules =
              [ "d ${cfg.root} 0775 root ${cfg.group} - -" ]
              ++ map (s: "d ${cfg.root}/${s} 0775 root ${cfg.group} - -") cfg.subdirs
              ++ [ "d ${cfg.hfCache} 0775 root ${cfg.group} - -" ]
              # Declarative models: symlink each fetched model into the
              # store tree. The target is the fetchurl outPath, so the
              # model is in the system closure (kept alive, deduped,
              # cached). rebuild = download; a peer substituter can serve
              # the bytes instead of the origin.
              ++ map (m: "L+ ${cfg.root}/${m.subdir}/${m.name} - - - ${fetchModel m}")
                cfg.models;
          })
        ];
    };
  };
}
