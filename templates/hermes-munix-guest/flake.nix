# munix-guest — a PARAMETRIC microVM guest builder.
#
# THE CLOSURE IS THE SYSTEM (per app).
# A munix guest boots its OWN NixOS closure (boot.isContainer = true, erofs
# root): its /run/current-system, PATH, and default package set are all this
# closure. NOTE (verified 2026-10-08): the closure is a set of *symlinks* to
# store paths — it does NOT contain /nix/store. The munix runner mounts the
# HOST's whole /nix/store read-only (runner line 302, unconditional), so the
# guest can see every host package. The closure scopes the guest's SYSTEM,
# NOT its store visibility. (True store isolation — the guest seeing only its
# own closure's paths — is the d2b "hardlink farm" model, which munix lacks.)
# The real blast-radius limit is the separate kernel + the un-bound host
# /home, /etc, /run (no user data, no secrets).
#
# This is the reusable foundation for sandboxing MANY desktop apps the same
# way — not just Hermes. Each app gets its own closure via `mkGuest`:
#
#   researcher  = mkGuest { app = hermes; graphics = false; ... }   # headless
#   steam-guest = mkGuest { app = steam;  graphics = true;  ... }   # full GPU
#
# `graphics = false` drops mesa entirely (headless agents). `graphics = true`
# pulls the full GPU stack (games / GUI apps). The mesa build is a SHARED
# cached closure: built once, reused by every graphics=true guest on the same
# pin — so slimming the researcher is a pure win, and the GPU guests still
# get everything they need.
#
# Trust note: keep DIFFERENT-trust apps in DIFFERENT closures/VMs. Never let
# an untrusted app's closure share a hermes kanban board with a trusted one —
# the shared board is the confused-deputy surface. Cross-trust handoff is a
# human gate, not kanban/peer automation.
{
  description = "Parametric munix microVM guest builder (closure = per-app system definition; store is shared ro by munix)";

  # munix's binary cache — without it the guest closure builds from source.
  nixConfig = {
    extra-substituters = [ "https://cache.clan.lol" ];
    extra-trusted-public-keys = [
      "cache.clan.lol-1:3KztgSAB5R1M+Dz7vzkBGzXdodizbgLXGXKXlcQLA28="
    ];
  };

  inputs = {
    # Fork pin (2026-10-10): sjdevries/munix feat/closure-only-store
    # carries --store-dev/--sandbox-store (erofs block-device store
    # slice), not yet in upstream main. Superseding PR: clan/munix #38.
    # Re-point to clan/munix once that merges.
    munix.url = "git+https://git.clan.lol/sjdevries/munix?shallow=1&ref=feat/closure-only-store";
    nixpkgs.follows = "munix/nixpkgs";
    # Same hermes pin deniac uses, so the guest agent == the host agent.
    llm-agents.url = "github:numtide/llm-agents.nix/32f95b57bd11604871fb663c6724da15112860ee";
  };

  outputs =
    { munix, nixpkgs, llm-agents, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      hermes = llm-agents.packages.${system}.hermes-agent;

      # ── The parametric builder ───────────────────────────────────────
      # mkGuest { app, graphics, packages, defaultCommand, extraModules }
      #   app            the one application this VM exists to run
      #   graphics       false → no mesa (headless); true → full GPU stack
      #   packages       extra packages the app needs (added to the allowlist)
      #   defaultCommand what runs on boot with no args (the launcher overrides)
      #   extraModules   any additional NixOS modules for this guest
      #
      # Returns the nixosSystem; take .config.system.build.munix for the
      # wrapped launcher, or .config.system.build.toplevel for the raw
      # closure the deniac launcher's munixClosure points at.
      mkGuest =
        {
          app,
          graphics ? false,
          packages ? [ ],
          defaultCommand ? "bash",
          extraModules ? [ ],
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            munix.nixosModules.default
            (
              { pkgs, lib, ... }:
              {
                system.stateVersion = "26.05";
                nixpkgs.hostPlatform = system;

                # The munix module hard-sets graphics=true; mkForce lets the
                # caller turn it OFF for headless agents (dropping mesa).
                hardware.graphics.enable = lib.mkForce graphics;

                # The allowlist: the app + whatever it genuinely needs.
                environment.systemPackages = [ app ] ++ packages;

                virtualisation.munix.defaultCommand = defaultCommand;
              }
            )
          ]
          ++ extraModules;
        };

      # ── Reusable store-slice builder ─────────────────────────────────
      # Turns any mkGuest system into the (paths, erofs) pair the
      # --store-dev launcher consumes. Extracted so researcher / coder /
      # auditor share ONE recipe (was inline per-guest). The munix RUNNER
      # is a rootPath because its binaries are read pre-activation too.
      # Method: research §6 / clan/munix PR #38 (fork pin).
      mkStoreSlice = name: guest:
        let
          closure = pkgs.closureInfo {
            rootPaths = [
              guest.config.system.build.toplevel
              munix.packages.${system}.munix
            ];
          };
        in
        {
          paths = closure;
          erofs = pkgs.runCommand "${name}-store-erofs" {
            nativeBuildInputs = [ pkgs.erofs-utils pkgs.bubblewrap ];
          } ''
            mkdir store
            args="--dev-bind / / --chdir $(pwd)"
            for d in $(cat ${closure}/store-paths); do
              args="$args --ro-bind $d $(pwd)/store/$(basename "$d")"
            done
            # bwrap avoids copying the closure; the cp -a fallback covers
            # build sandboxes that forbid nested bwrap (same fallback
            # microvm.nix carries).
            bwrap $args -- mkfs.erofs -T 0 --all-root -L nix-store \
                --mount-point=/nix/store $out store \
              || {
                echo "bwrap path failed; copying closure" >&2
                cp -a $(cat ${closure}/store-paths) store/
                mkfs.erofs -T 0 --all-root -L nix-store \
                  --mount-point=/nix/store $out store
              }
          '';
        };

      # ── request-tool MCP server (the coder's tool-request interface) ──
      # Minimal MCP-over-stdio server exposing request_tool(name, reason).
      # Runs INSIDE the coder VM; appends "<name>\t<reason>" to the
      # request file passed as $1 (a host path bound rw into the VM),
      # where the gate reads it. Needs jq (already in the coder closure).
      #
      # FLAG: the MCP handshake (protocolVersion / framing) is best-effort
      # and must be validated against the real hermes MCP client on first
      # boot. The request FILE is the source of truth regardless — the
      # agent can also just write to it directly with its shell tools.
      requestToolMcp = pkgs.writeShellApplication {
        name = "request-tool-mcp";
        runtimeInputs = [ pkgs.jq ];
        text = ''
          REQ="''${1:?usage: request-tool-mcp <request-file>}"
          send() { printf '%s\n' "$1"; }
          while IFS= read -r line; do
            [ -z "$line" ] && continue
            id=$(printf '%s' "$line" | jq -r 'if has("id") then .id else "null" end' 2>/dev/null) || continue
            method=$(printf '%s' "$line" | jq -r '.method // empty' 2>/dev/null)
            case "$method" in
              initialize)
                send "$(jq -n --argjson id "$id" '{jsonrpc:"2.0",id:$id,result:{protocolVersion:"2024-11-05",capabilities:{tools:{}},serverInfo:{name:"request-tool",version:"0.1.0"}}}')"
                ;;
              tools/list)
                send "$(jq -n --argjson id "$id" '{jsonrpc:"2.0",id:$id,result:{tools:[{name:"request_tool",description:"Request that a nix package be added to this VM closure (pending human approval + rebuild).",inputSchema:{type:"object",properties:{name:{type:"string"},reason:{type:"string"}},required:["name"]}}]}}')"
                ;;
              tools/call)
                name=$(printf '%s' "$line" | jq -r '.params.arguments.name // empty')
                reason=$(printf '%s' "$line" | jq -r '.params.arguments.reason // ""')
                if [ -n "$name" ]; then
                  printf '%s\t%s\n' "$name" "$reason" >> "$REQ"
                  send "$(jq -n --argjson id "$id" --arg m "Recorded request for '$name' (pending approval + closure rebuild)." '{jsonrpc:"2.0",id:$id,result:{content:[{type:"text",text:$m}]}}')"
                else
                  send "$(jq -n --argjson id "$id" '{jsonrpc:"2.0",id:$id,error:{code:-32602,message:"request_tool requires a name"}}')"
                fi
                ;;
              notifications/*) : ;;
              *)
                if [ "$id" != "null" ]; then
                  send "$(jq -n --argjson id "$id" --arg m "unknown method: $method" '{jsonrpc:"2.0",id:$id,error:{code:-32601,message:$m}}')"
                fi
                ;;
            esac
          done
        '';
      };
    in
    {
      # The reusable builder — other flakes: inputs.<this-flake>.lib.mkGuest { … }
      lib.mkGuest = mkGuest;

      packages.${system} =
        let
          # ── The three agents (all headless hermes, no graphics) ──────
          # Each is a SEPARATE closure + store slice: different tools,
          # different blast radius. The ROLE (binds, soul, authority) is
          # set in the CONSUMER flake (the fleet's ai.hermes profile);
          # this template only supplies the per-role GUEST (app + tools).

          # Researcher — web-facing gatherer. Read-only reach: git clones
          # public repos (no creds → can't push), jq parses JSON, rg
          # searches. Writes to research-out (bound in the fleet), into
          # a per-consumer subdir so its output fans out isolated.
          researcherGuest = mkGuest {
            app = hermes;
            graphics = false;
            packages = [ pkgs.git pkgs.jq pkgs.ripgrep ];
            defaultCommand = "hermes -p researcher";
          };
          researcherSlice = mkStoreSlice "researcher" researcherGuest;

          # Coder — writes code + opens PRs. Light toolset for now.
          # NOTE: in-VM `nix build` of NEW packages needs a WRITABLE
          # store (ext4 image + nix-daemon); the read-only erofs slice
          # here runs PRE-BUILT tools only. The writable-store dev-mode
          # is the next munix feature — see the fleet coder profile TODO.
          coderGuest = mkGuest {
            app = hermes;
            graphics = false;
            packages =
              [ pkgs.git pkgs.jq pkgs.ripgrep requestToolMcp ]
              ++ import ./coder-tools.nix pkgs;
            defaultCommand = "hermes -p coder";
          };
          coderSlice = mkStoreSlice "coder" coderGuest;

          # Auditor — security review. Deterministic floor tools (NOT
          # prompt-injectable, unlike the LLM):
          #   semgrep      SAST — pattern + custom rules
          #   osv-scanner  multi-ecosystem CVE lookup (OSV database)
          #   cargo-audit  RustSec advisory check against Cargo.lock
          # + the read/search tools. All pre-built → read-only slice fits.
          auditorGuest = mkGuest {
            app = hermes;
            graphics = false;
            packages = [
              pkgs.git
              pkgs.jq
              pkgs.ripgrep
              pkgs.semgrep
              pkgs.osv-scanner
              pkgs.cargo-audit
            ];
            defaultCommand = "hermes -p auditor";
          };
          auditorSlice = mkStoreSlice "auditor" auditorGuest;
        in
        {
          # ── researcher ──
          researcher = researcherGuest.config.system.build.munix;
          researcher-toplevel = researcherGuest.config.system.build.toplevel;
          researcher-store-erofs = researcherSlice.erofs;
          researcher-store-paths = researcherSlice.paths;

          # ── coder ──
          coder = coderGuest.config.system.build.munix;
          coder-toplevel = coderGuest.config.system.build.toplevel;
          coder-store-erofs = coderSlice.erofs;
          coder-store-paths = coderSlice.paths;

          # ── auditor ──
          auditor = auditorGuest.config.system.build.munix;
          auditor-toplevel = auditorGuest.config.system.build.toplevel;
          auditor-store-erofs = auditorSlice.erofs;
          auditor-store-paths = auditorSlice.paths;

          # Re-expose the munix runner so a consumer needs only THIS one
          # input for both the closures and the launcher binary (the
          # runner is pinned to the same munix the guests were built
          # against — they must match).
          munix = munix.packages.${system}.munix;
        };

      # Instance #2 — the GPU pattern (Steam). Unfree, so left as the
      # shape to copy rather than a built output:
      #
      # steam = (mkGuest {
      #   app = nixpkgs.legacyPackages.${system}.steam;
      #   graphics = true;
      #   packages = [ ];   # + any game-specific libs
      # }).config.system.build.munix;
    };
}
