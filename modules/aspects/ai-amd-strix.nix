# deniac.ai.amd.strix — AMD Strix Point / Strix Halo local AI stack.
#
# Wraps noamsto/nix-amd-ai's NixOS module (pinned flake input) with two
# explicit knobs plus the account Lemonade runs as:
#
#   chipset — which Strix family the host is (drives `gpuTarget`):
#             "strix-point" → gfx1150 (Ryzen AI 300, e.g. Ryzen AI 9 HX 370)
#             "strix-halo"  → gfx1151 (Ryzen AI Max 300, e.g. AI MAX+ 395)
#
#             RAM size does NOT determine the chip family: Strix Halo ships in
#             32 / 64 / 128 GB and Strix Point in up to 64 GB — a 64 GB board
#             can be either.
#
#   vram — the GPU-memory (GTT) ceiling sensible for AI workloads, applied as
#          `gpuMemory.ttmSizeGiB` + `gpuMemory.pagePoolSizeGiB`:
#             "32gb"  → 24 GiB
#             "64gb"  → 56 GiB
#             "128gb" → 104 GiB
#          null (default) leaves the kernel default (~27 GB addressable,
#          covers 17-22 GB models) untouched.
#
#   The two are independent axes: a 64 GB Strix Halo host sets
#   chipset = "strix-halo" and may leave vram null (kernel default is enough
#   for 17-22 GB models) or raise it.
#
# The aspect is inert (contributes nothing to `hardware.amd-npu`) until both
# `chipset` and `user` are set.
#
# Every leaf it sets is `lib.mkDefault`, so a host can override any of them —
# at any depth — including `gpuMemory.ttmSizeGiB` directly to target a
# specific model size:
#
#   den.aspects.igloo.includes = [ deniac.ai.amd.strix ];
#   den.aspects.igloo.nixos.deniac.ai.amd.strix.chipset = "strix-halo";
#   den.aspects.igloo.nixos.deniac.ai.amd.strix.vram    = "128gb";
#   den.aspects.igloo.nixos.deniac.ai.amd.strix.user    = "tux";
#   # host-side overrides (all optional):
#   den.aspects.igloo.nixos.hardware.amd-npu.enableROCm = false; # drop the ROCm backends
#   den.aspects.igloo.nixos.hardware.amd-npu.lemonade.models = [ "..." ];
#   den.aspects.igloo.nixos.hardware.amd-npu.gpuMemory.ttmSizeGiB = 80;

{ inputs, lib, ... }:
let
  # Capture the nix-amd-ai NixOS module now: the `nixos` content below is
  # evaluated later, inside the host's nixosSystem eval, where `inputs` is
  # not a module argument.
  amdNpu = inputs.nix-amd-ai.nixosModules.default;

  # Chipset axis: drives `gpuTarget` (upstream option, "The host's actual
  # iGPU: gfx1150 (Strix Point) or gfx1151 (Strix Halo)").
  chipsets = {
    "strix-point" = { gpuTarget = "gfx1150"; };
    "strix-halo" = { gpuTarget = "gfx1151"; };
  };

  # VRAM axis: the "sensible maximum for AI workloads" GTT ceiling per
  # unified-memory size, applied as a pair (upstream requires
  # pagePoolSizeGiB <= ttmSizeGiB; the nix-amd-ai README's measured Halo
  # configuration sets them equal). null (option unset) leaves both at the
  # kernel default (~27 GB addressable).
  #
  #   32 GB board → 24 GiB (≈ kernel default; ~8 GB left for CPU/OS)
  #   64 GB board → 56 GiB (covers ~50 GB models; ~8 GB left for CPU/OS)
  #   128 GB board→ 104 GiB — the known-stable ceiling: Framework Desktop
  #                  users report stutters/segfaults past ~108 GiB, and the
  #                  nix-amd-ai README's own Halo measurements ran at
  #                  ttmSizeGiB = 104 ("Running ds4 beside lemond"). ~24 GB
  #                  left for CPU/OS.
  vrams = {
    "32gb" = { gpuMemory = { ttmSizeGiB = 24; pagePoolSizeGiB = 24; }; };
    "64gb" = { gpuMemory = { ttmSizeGiB = 56; pagePoolSizeGiB = 56; }; };
    "128gb" = { gpuMemory = { ttmSizeGiB = 104; pagePoolSizeGiB = 104; }; };
  };

  # Leaves shared by all configurations (upstream defaults noted where
  # relevant).
  common = {
    enable = true;
    enableNPU = true;
    enableFastFlowLM = true;
    enableLemonade = true;
    enableImageGen = true; # sd-cpp backend, ~150 MB — upstream default
    enableROCm = true; # llamacpp/sd-cpp GPU backends — a host can opt out
    enableVulkan = true; # llamacpp/whispercpp GPU backends — a host can opt out
    enableVllm = false; # requires ROCm + Lemonade — a host opts in
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
      # cacheDir (null), settings ({}), desktopApp.enable (true), and
      # allowedOrigins ([]) are left at their upstream defaults — the host
      # overrides them directly if it wants.
    };
  };
in
{
  deniac.ai.amd.strix = {
    description = ''
      AMD Strix Point / Strix Halo local AI stack: XDNA NPU driver,
      FastFlowLM, Lemonade OpenAI-compatible API server, and image
      generation. Wraps noamsto/nix-amd-ai (pinned flake input).

      Set `chipset` to "strix-point" or "strix-halo" and `user` to the
      account running Lemonade to activate; optionally set `vram` ("32gb" /
      "64gb" / "128gb") to raise the GPU-memory (GTT) ceiling to the sensible
      maximum for that memory size. Leave `chipset` null to keep the aspect
      inert.
    '';

    nixos =
    { config, lib, ... }:
    let
      cfg = config.deniac.ai.amd.strix;

      # The full hardware.amd-npu value for the active configuration.
      #
      # The `chipsets.*` / `vrams.*` lookups are guarded: the module system
      # forces the *structure* of the `mkIf` content even when the condition
      # is false (pushDownProperties, via the unmatchedDefns computation), so
      # an unguarded `chipsets.null` would throw in the inert case. Guarding
      # keeps the content inert-safe — nothing in `value`/`leaves` throws
      # when `chipset` or `vram` is null. (The mkIf condition itself already
      # keeps the *definition* from applying; the guards only keep the
      # content from throwing while it is forced.)
      value =
      common
      // (if cfg.chipset != null then chipsets.${cfg.chipset} else { })
      // (if cfg.vram != null then vrams.${cfg.vram} else { })
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
        chipset = lib.mkOption {
          default = null;
          type = lib.types.nullOr (lib.types.enum [ "strix-point" "strix-halo" ]);
          description = ''
            Which Strix family this host is (drives the upstream
            `gpuTarget`):

            - "strix-point": Ryzen AI 300 (e.g. Ryzen AI 9 HX 370), iGPU
              target `gfx1150`.
            - "strix-halo": Ryzen AI Max 300 (e.g. AI MAX+ 395), iGPU
              target `gfx1151`.

            RAM size does not determine the family — Strix Halo ships in 32 /
            64 / 128 GB and Strix Point in up to 64 GB. null (default)
            leaves the aspect **inert** (`hardware.amd-npu` disabled); it
            also requires `deniac.ai.amd.strix.user` to be set.
          '';
        };

        vram = lib.mkOption {
          default = null;
          type = lib.types.nullOr (lib.types.enum [ "32gb" "64gb" "128gb" ]);
          description = ''
            GPU-memory (GTT) ceiling, sized to "the maximum that is sensible
            for AI workloads" on a board of that unified-memory size. Sets
            `gpuMemory.ttmSizeGiB` and `gpuMemory.pagePoolSizeGiB`
            (upstream requires the pair to be equal-or-less):

            - "32gb": 24 GiB (≈ the kernel default; ~8 GB left for CPU/OS).
            - "64gb": 56 GiB (comfortable for ~50 GB models; ~8 GB for
              CPU/OS).
            - "128gb": 104 GiB — the known-stable ceiling: Framework
              Desktop users report stutters/segfaults past ~108 GiB, and the
              nix-amd-ai README's own Halo measurements ran at this value.
              ~24 GiB left for CPU/OS.

            null (default) leaves the kernel default untouched (~27 GB
            addressable, covers 17-22 GB models). To target a specific model
            size, override `hardware.amd-npu.gpuMemory.ttmSizeGiB` /
            `.pagePoolSizeGiB` directly on the host.
          '';
        };

        user = lib.mkOption {
          default = null;
          type = lib.types.nullOr lib.types.str;
          description = ''
            Local user account to run Lemonade (lemond) as. nix-amd-ai
            requires this option when Lemonade is enabled, so the aspect
            keeps the whole stack inert until it is set. The account must
            also be in the `video` and `render` groups (see
            docs/ai-amd-strix.md).
          '';
        };
      };

      config =
      {
        # A host that sets `vram` (or `user`) without `chipset` gets a hint
        # that the aspect is still inert — the options are accepted, just not
        # applied. (Inside `config`: this den aspect shape does not accept a
        # top-level `warnings` alongside `options`/`config`.)
        warnings = lib.optional (cfg.chipset == null && (cfg.vram != null || cfg.user != null)) ''
          deniac.ai.amd.strix.chipset is null, so the ai.amd.strix aspect is
          inert: vram/user are set but not applied. Set chipset to
          "strix-point" or "strix-halo" to activate.
        '';
      }
      // lib.mkIf (cfg.chipset != null && cfg.user != null) {
        hardware.amd-npu = leaves;
      };
    };
  };
}
