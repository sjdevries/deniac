{
  description = "deniac — den aspect library";

  inputs = {
    den.url = "github:denful/den";
    import-tree.url = "github:vic/import-tree";
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
    nix-amd-ai.url = "github:noamsto/nix-amd-ai";
    # dsh (DeepSeek Harness) + hermes-agent package source. Pinned to
    # 0784674 (llm-agents main, 2026-10-26) — dsh 0.2.1-rc.3 + hermes-agent
    # 0.22.5. This bump unblocks the dsh upgrade: 0.1.6+ used to crash at boot
    # with `node-addon-require-builtin unsupported` (llm-agents#9994), fixed
    # upstream by e442eb67 ("dsh: avoid node-addon-require-builtin"). Both
    # packages verified building AND starting on this box at this pin.
    # NOTE: this input is SHARED between dsh and hermes-agent — bumping it moves
    # both. hermes went 0.8.4 -> 0.22.5 here (deliberate, user-approved).
    llm-agents.url = "github:numtide/llm-agents.nix/0784674971b3ee4681aea5b5e9641c75faf7e846";
    # ComfyUI (node-graph image/video gen UI) — pinned to UPSTREAM
    # github:utensils/comfyui-nix as of 2026-11-08. The rocmChannel work
    # that was tested on real gfx1151 hardware through the sjdevries fork
    # has merged upstream (PR #112 = rocmChannel + the rocm72 wheel set,
    # PR #115 = the safer attention default). Verified against upstream
    # main the same day: `rocmChannel` is an enum of exactly
    # "rocm71" | "rocm72" — there is NO `rocmNightly` upstream, so that
    # value was dropped from the aspect's enum in the same commit.
    comfyui-nix.url = "github:utensils/comfyui-nix";
    # Official ACE-Step ComfyUI nodes — a thin API client (torch/numpy/
    # requests only) for the ACE-Step 1.5 music-gen server: text2music,
    # cover/remix, repaint. Plain node repo (no flake.nix), so it is
    # locked with flake = false and consumed as a source-tree path for
    # services.comfyui.customNodes.
    ace-step-comfyui = {
      url = "github:ace-step/ACE-Step-ComfyUI";
      flake = false;
    };
    # SolidCraft — pure-Rust parametric 3D CAD (desktop + wasm + headless
    # CLI + MCP server). Pinned to the EXACT commit reviewed on 2026-10-31
    # (v0.28.0, `main`, 44d7c1fb): a clean-room Rust app on the truck
    # B-rep kernel, MIT OR Apache-2.0, no GPL/LGPL, no telemetry,
    # workspace `unsafe_code = "forbid"`, and its vendored truck patches
    # verified against the upstream crates.io tarball.
    # This project moves at ~140 commits/day across 270+ contributors, so
    # the pin is the review boundary: re-run the safety review before
    # moving it. Consumed by the `cad.solidcraft` aspect.
    solidcraft.url = "github:tangency-labs/solidcraft/44d7c1fb6f45b0c48f05f5730375c3071ff6dfea";
  };

  outputs = inputs: (
    inputs.nixpkgs.lib.evalModules {
      specialArgs = { inherit inputs; };
      modules = [ (inputs.import-tree ./modules) ];
    }
  ).config.flake;
}
