{
  description = "deniac — den aspect library";

  inputs = {
    # Pinned to the v0.20.0 tag (released 2026-11-10, commit 9bdfbc21).
    # The previous value was the bare branch URL, which resolved to
    # 0f7675b0 (2026-10-21, "test: prefix suites by their categorization",
    # den #737) — an UNRELEASED intermediate commit between v0.19.0
    # (2026-09-24) and v0.20.0. A bare URL pin is worse than an old tag:
    # it cannot be pointed at a release, and it silently means "whatever
    # main was that day". Pinning the tag makes this reproducible and
    # reviewable.
    # Bumped alone, and re-verified per §3.1 (see the commit message for the
    # suite results).
    den.url = "github:denful/den/v0.20.0";
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
    # github:utensils/comfyui-nix **tag v0.44.0** (aa7f2937, 2026-11-12).
    # The rocmChannel work that was tested on real gfx1151 hardware through
    # the sjdevries fork has merged upstream (PR #112 = rocmChannel + the
    # rocm72 wheel set, PR #115 = the safer attention default). Verified
    # against upstream main the same day: `rocmChannel` is an enum of
    # exactly "rocm71" | "rocm72" — there is NO `rocmNightly` upstream, so
    # that value was dropped from the aspect's enum in the same commit.
    # Bumped 2026-11-14 from the 2026-11-08 main pin to the v0.44.0 tag
    # (#119: ComfyUI v0.44.0 + flake-input bumps). Pinned to the tag, not
    # the branch, because upstream `main` (b4d4ed4) has already moved past
    # the release — following the branch would silently overshoot the
    # tested tag.
    comfyui-nix.url = "github:utensils/comfyui-nix/v0.44.0";
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
    # CLI + MCP server). Pinned to tag v0.41.0 (3c8efdb5, re-reviewed
    # 2026-11-14): MIT OR Apache-2.0, no GPL/LGPL (0 hits across the
    # lock), no telemetry, workspace `unsafe_code = "forbid"`.
    #
    # THE KERNEL CHANGED since our v0.28.0 pin. `truck` is gone (10 crates
    # -> 0), replaced by `solidcore`: a safe-Rust B-rep kernel ported from
    # NVIDIA's SMLib (NVIDIA-Omniverse/usd-brep v1.0.1 @ 3fd5b95,
    # Apache-2.0, NVIDIA copyright carried, NOTICE + ATTRIBUTION.md
    # present), vendored in-tree as a git subtree mirrored out to
    # tangency-labs/solidcore. 1,840 .rs files with ZERO actual unsafe
    # blocks and zero `unsafe fn`; the STEP Part21 parser carries
    # `#![forbid(unsafe_code)]`, so the untrusted-input path cannot contain
    # unsafe by construction. solidcore makes no network calls and its
    # 56-package lock contains no network crates.
    #
    # NEW SURFACE: a WASM plugin runtime (wasmtime 48.0.8 + cranelift +
    # cap-std). Sandbox verified IN CODE, not from its docs — no WASI
    # linked; `fetch`/`wasi:sockets/`/`wasi:http/` refused by name; fuel +
    # epoch interruption + resource limiter; `wasm_memory64(false)` and
    # `wasm_multi_memory(false)`; execution hash-bound to the reviewed
    # bytes; commands run on a scratch session under an empty file scope;
    # and refused calls poison the transaction even if guest code catches
    # the error and returns success. Not auto-loading: install needs an
    # explicit .zip + consent after a dry-run review.
    #
    # wasmtime 48.0.8 is the EXACT patched version for RUSTSEC-2026-0422 /
    # 0423 / 0424 (each requires >= 48.0.8). An earlier 48.0.x would have
    # been exposed to all three, so this tag is the safe landing spot.
    #
    # Known-rough edges travel with the pin: upstream's own kernel regression
    # rig reports ~321 of 372 cases passing on solidcore, 51 not passing
    # (1 crash, 7 hangs), concentrated in booleans and sweeps. Complex
    # boolean/sweep geometry may misbehave; ordinary modelling is fine.
    #
    # This project moves at ~140 commits/day across 270+ contributors, so
    # the pin is the review boundary: re-run the safety review before
    # moving it. Consumed by the `cad.solidcraft` aspect.
    solidcraft.url = "github:tangency-labs/solidcraft/v0.42.0";
  };

  outputs = inputs: (
    inputs.nixpkgs.lib.evalModules {
      specialArgs = { inherit inputs; };
      modules = [ (inputs.import-tree ./modules) ];
    }
  ).config.flake;
}
