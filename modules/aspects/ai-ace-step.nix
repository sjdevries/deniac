# deniac.ai.ace-step — ACE-Step music generation nodes for ComfyUI.
#
# Wires the OFFICIAL ace-step/ACE-Step-ComfyUI custom-node pack into the
# ComfyUI service (via comfyui-nix's `customNodes` mechanism: each entry
# is symlinked into custom_nodes/ at service start, fully pinned).
#
# Architecture note — the node is a THIN API CLIENT, not the model. Its
# only deps are torch/numpy/requests (all already in ComfyUI's env), and
# it talks to an ACE-Step 1.5 server in one of two modes:
#
#   - cloud:  api.acemusic.ai (needs an API key — not this aspect's story)
#   - local:  an ACE-Step 1.5 server on the same host, default
#             http://127.0.0.1:8002 (`acestep-openrouter` from the
#             ACE-Step 1.5 repo). The node's `server_url` is a per-
#             workflow input; the local-mode default matches a colocated
#             server, so no wiring is needed beyond installing the node.
#
# The ACE-Step 1.5 SERVER itself is not (yet) managed by this aspect:
# there is no official prebuilt container image, and pinning a community
# image into a public framework is a trust decision left to the operator.
# See docs/ai-ace-step.md for running the server locally.
#
# Usage (ComfyUI already running via deniac.ai.comfyui):
#
#   den.aspects.igloo.includes = [ deniac.ai.comfyui deniac.ai.ace-step ];
#   den.aspects.igloo.nixos.deniac.ai.comfyui = {
#     enable = true;
#     gpuSupport = "rocm";
#     rocmChannel = "rocm72";
#   };
#   den.aspects.igloo.nixos.deniac.ai.ace-step.enable = true;
#
# Then in ComfyUI: load the ACE-Step workflow templates, pick `local`
# mode, and point the server_url at your ACE-Step 1.5 server.

{ inputs, lib, ... }:
let
  # The official node repo as a pinned source tree (plain repo, no flake
  # — locked flake=false, used as a path, never evaluated as a flake).
  aceStepNode = inputs.ace-step-comfyui;
in
{
  deniac.ai.ace-step = {
    description = ''
      ACE-Step — open-source (MIT) music generation — inside ComfyUI,
      via the official ace-step/ACE-Step-ComfyUI node pack: text-to-
      music, cover/remix (re-style an existing song, keeping its
      structure), repaint (re-render a segment), and LLM-assisted
      sample generation.

      The nodes are a thin API client; they talk to an ACE-Step 1.5
      server (local `acestep-openrouter` on 127.0.0.1:8002 by default,
      or the acemusic.ai cloud). This aspect installs the nodes into the
      ComfyUI service declaratively; the server is run separately
      (see docs/ai-ace-step.md).
    '';

    nixos =
    { config, lib, ... }:
    let
      cfg = config.deniac.ai.ace-step;
    in
    {
      # NOTE: this aspect deliberately does NOT import the comfyui-nix
      # NixOS module. Importing it here *and* via ai.comfyui double-applies
      # it (the module system does not dedup the two function closures),
      # and comfyui-nix's `services.comfyui.packageSet.default` is a
      # unique-priority option that errors on the duplicate definition.
      # Include `deniac.ai.comfyui` (or the comfyui-nix module directly)
      # alongside this one — it provides the `services.comfyui.*` option
      # tree this aspect writes into.

      options.deniac.ai.ace-step = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Install the ACE-Step ComfyUI nodes.";
        };

        package = lib.mkOption {
          type = lib.types.package;
          default = aceStepNode;
          description = ''
            The ACE-Step ComfyUI node source (defaults to the pinned
            official ace-step/ACE-Step-ComfyUI input). Installed under
            custom_nodes/ as "ACE-Step-ComfyUI".
          '';
        };
      };

      config = lib.mkMerge [
        (lib.mkIf cfg.enable {
          services.comfyui.customNodes."ACE-Step-ComfyUI" = cfg.package;
        })

        # The nodes are useless without a running ComfyUI service — warn
        # (don't fail) when they're installed but the service is off.
        (lib.mkIf (cfg.enable && !config.services.comfyui.enable) {
          warnings = [
    ''
      deniac.ai.ace-step is enabled but the ComfyUI service is not
      (services.comfyui.enable = false). The ACE-Step nodes install into
      ComfyUI's custom_nodes/ — enable ComfyUI (e.g. deniac.ai.comfyui)
      or the nodes have nothing to attach to.
    ''
          ];
        })
      ];
    };
  };
}
