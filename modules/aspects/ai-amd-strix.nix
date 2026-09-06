# deniac.ai.amd.strix — AMD Strix Point (64 GB) / Strix Halo (128 GB) AI stack.
#
# Wraps noamsto/nix-amd-ai's NixOS module (pinned flake input) with the two
# memory profiles its README documents:
#
#   "64gb"  — Strix Point, 64 GB unified memory. The kernel's default GTT
#             pool (~27 GB) already covers 17-22 GB models; upstream calls
#             the gpuMemory options a no-op here, so they stay unset.
#
#   "128gb" — Strix Halo, 128 GB unified memory. Raises the GTT ceiling to
#             96 GiB (ttm pages_limit + page_pool_size) — the pair upstream
#             measured on a Halo host (leaves ~32 GB for CPU/OS).
#
# Both profiles enable NPU + FastFlowLM + Lemonade (OpenAI-compatible API
# server on localhost:13305) + image generation; ROCm/Vulkan/vLLM backends
# stay off (host can opt in). Every leaf is lib.mkDefault, so a host can
# override any of them — at any depth:
#
#   den.aspects.igloo.includes = [ deniac.ai.amd.strix ];
#   den.aspects.igloo.nixos.deniac.ai.amd.strix.profile = "128gb";
#   den.aspects.igloo.nixos.deniac.ai.amd.strix.user = "tux";
#   # host-side overrides (all optional):
#   den.aspects.igloo.nixos.hardware.amd-npu.enableROCm = true;
#   den.aspects.igloo.nixos.hardware.amd-npu.lemonade.models = [ "..." ];

{ inputs, lib, ... }:
let
  # Capture the nix-amd-ai NixOS module now: the `nixos` content below is
  # evaluated later, inside the host's nixosSystem eval, where `inputs` is
  # not a module argument.
  amdNpu = inputs.nix-amd-ai.nixosModules.default;

  # Leaves shared by both profiles (upstream defaults noted where relevant).
  common = {
    enable = true;
    enableNPU = true;
    enableFastFlowLM = true;
    enableLemonade = true;
    enableImageGen = true; # sd-cpp backend, ~150 MB — upstream default
    enableROCm = false; # host opt-in (llamacpp/sd-cpp GPU backends)
    enableVulkan = false; # host opt-in
    enableVllm = false; # requires ROCm + Lemonade
    exclusiveInference = false;
    ds4.enable = false; # DeepSeek V4 server — needs ds4.model, host opt-in
    lemonade = {
      host = "localhost";
      port = 13305;
      autoStart = true;
      flashAttn = "on";
      models = [ ]; # host lists models to keep downloaded
      pruneUnlistedModels = false;
      customModels = { };
      # `user` is set from the aspect's own option (required when enabled).
    };
  };

  profiles = {
    "64gb" = {
      gpuTarget = "gfx1150"; # Strix Point
    };
    "128gb" = {
      gpuTarget = "gfx1151"; # Strix Halo
      gpuMemory = {
        ttmSizeGiB = 96;
        pagePoolSizeGiB = 96;
      };
    };
  };
in
{
  deniac.ai.amd.strix = {
    description = ''
      AMD Strix Point (64 GB) / Strix Halo (128 GB) local AI stack: XDNA NPU
      driver, FastFlowLM, Lemonade OpenAI-compatible API server, and
      image generation. Wraps noamsto/nix-amd-ai (pinned flake input).

      Set `profile` to "64gb" or "128gb" and `user` to the account running
      Lemonade; leave both null to keep the aspect inert.
    '';

    nixos =
    { config, lib, ... }:
    let
      cfg = config.deniac.ai.amd.strix;

      # The full hardware.amd-npu value for the active profile.
      #
      # The `profiles.${cfg.profile}` lookup is guarded: the module system
      # forces the *structure* of the `mkIf` content even when the condition
      # is false (pushDownProperties, via the unmatchedDefns computation), so
      # an unguarded `profiles.null` would throw `expected a string but found
      # null` in the inert case. Guarding it keeps the content inert-safe —
      # nothing in `value`/`leaves` throws when `profile` is null. (The
      # mkIf condition itself already keeps the *definition* from applying;
      # this guard only keeps the content from throwing while it is forced.)
      value =
      (common // (if cfg.profile != null then profiles.${cfg.profile} else { }))
      // {
        lemonade = common.lemonade // { user = cfg.user; };
      };

      # Spread the value to every leaf so each sits at its own option path
      # with its own mkDefault priority. A host can then override any leaf
      # (at any depth) with a plain definition — only that path conflicts,
      # the rest of the subtree survives. A single mkDefault on the whole
      # attrset would not: overriding `lemonade.models` would replace the
      # entire `lemonade` subtree.
      leaves =
        builtins.mapAttrs
        (
          k: v:
          if builtins.isAttrs v then
            builtins.mapAttrs (_kk: vvv: lib.mkDefault vvv) v
          else
            lib.mkDefault v
        )
        value;
    in
    {
      imports = [ amdNpu ];

      options.deniac.ai.amd.strix = {
        profile = lib.mkOption {
          default = null;
          type = lib.types.nullOr (lib.types.enum [ "64gb" "128gb" ]);
          description = ''
            Unified-memory profile for this host:

            - "64gb": Strix Point (64 GB) — gfx1150 target, default GTT pool
              (the kernel default ~27 GB already covers 17-22 GB models).
            - "128gb": Strix Halo (128 GB) — gfx1151 target, GTT ceiling
              raised to 96 GiB via `ttm` `pages_limit`/`page_pool_size`.

            null (default) leaves `hardware.amd-npu` disabled. Requires
            `deniac.ai.amd.strix.user` to be set.
          '';
        };

        user = lib.mkOption {
          default = null;
          type = lib.types.nullOr lib.types.str;
          description = ''
            Local user account to run Lemonade (lemond) as. nix-amd-ai
            requires this option when Lemonade is enabled, so the aspect
            keeps the whole stack inert until it is set. The account must
            also be in the `video` and `render` groups (see docs/ai-amd-strix.md).
          '';
        };
      };

      config = lib.mkIf (cfg.profile != null && cfg.user != null) {
        hardware.amd-npu = leaves;
      };
    };
  };
}
