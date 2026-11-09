# deniac.ai.hermes — Hermes Agent (Nous Research) in role-compartment jails.
#
# Security model: the agent is split into least-privilege role
# compartments (researcher / coder / reviewer /
# creator), each a Hermes *profile* (NousResearch/hermes-agent's native
# `~/.hermes/profiles/<name>/` isolation — per-profile config.yaml, .env,
# SOUL.md, memories, sessions, skills). Prompt injection is a
# confused-deputy attack: you can't detect it, but you can remove or bound
# the capability, so a compartment can't be tricked into touching what it
# was never given.
#
# TWO ENFORCEMENT BACKENDS (match the backend to the threat — they compose):
#
#   enforcement = "bwrap"  — a bubblewrap mount-namespace jail. Default-DENY:
#       the real home is NOT bound; the agent's HOME is its own profile
#       `home/` dir, so it literally cannot read ~/.ssh, ~/.aws, browser
#       profiles, or sibling profiles. Protects the system AND bounds the
#       blast radius. Sufficient for the confused-deputy threat.
#
#   enforcement = "munix"  — a KVM microVM (munix / libkrun). Separate guest
#       kernel → jail-escape resistance against a compromised tool/MCP
#       server, plus per-VM network: `network = "none"` maps to munix
#       `--no-network` (the reviewer's clean no-net boundary). The guest
#       closure is a declared input (built by the host / a separate
#       aspect); this aspect provides the launcher.
#
# Why bubblewrap, not the upstream podman container: the upstream NixOS
# module's container mode runs as root ("Podman's rootful containers
# require sudo"); rootless contradicts it and failed on this fleet. bwrap
# delivers the jail with no daemon, no root, no sudo.
#
# Reproducibility: everything the stack IS lives in Nix (hash-pinned); the
# only mutable part is what the agent LEARNED (~/.hermes: sessions, skills,
# memories) — backed up like precious-bulk weights, never rebuilt.
#
# The pure jail/config logic lives in ../../lib/hermes-jail.nix (outside
# modules/ so import-tree won't load it as an aspect) and is unit-tested
# there. This file is the option surface + wiring.
#
# Usage (per-user, Home Manager class):
#
#   den.aspects.tux.includes = [ deniac.ai.hermes ];
#   den.aspects.tux.homeManager.deniac.ai.hermes = {
#     enable = true;
#     profiles = {
#       researcher = {
#         bindReadwrite = [ "/home/tux/research-out" ];   # its only write target
#         mcpServers.donsetch.command = "donsetch";
#         soul = "You are a research assistant. No secrets, no push.";
#       };
#       coder = {
#         bindReadwrite = [ "/home/tux/work/myrepo" ];
#         env.GIT_SSH_COMMAND = "ssh -i /home/tux/.ssh/deploy_key";
#       };
#       reviewer = {
#         enforcement = "munix";
#         network = "none";                              # munix --no-network
#         bindReadonly = [ "/home/tux/work/myrepo" ];
#         munixPackage = inputs.munix.packages.x86_64-linux.munix;
#         munixClosure = "/nix/store/...-reviewer-toplevel";
#       };
#     };
#   };
#
#   # then: hermes-jailed-researcher … / hermes-munix-reviewer …

{ inputs, lib, ... }:
{
  deniac.ai.hermes = {
    description = ''
      Hermes Agent (Nous Research, MIT) in role-compartment jails —
      per-profile least-privilege isolation (researcher / coder / reviewer
      / creator) enforced by bubblewrap (default-deny bind) or munix KVM
      microVMs (jail-escape resistance + per-VM network). The daemonless,
      rootless alternative to the upstream rootful podman container.
    '';

    homeManager =
    { config, lib, pkgs, ... }:
    let
      hj = import ../../lib/hermes-jail.nix { inherit lib; };
      cfg = config.deniac.ai.hermes;

      # ── profile submodule ──────────────────────────────────────────
      profileOpts = { name, ... }: {
        options = {
          enforcement = lib.mkOption {
            type = lib.types.enum [ "bwrap" "munix" ];
            default = "munix";
            description = ''
              How this compartment is contained. The TARGET is a munix KVM
              microVM (Nix³OS Tier 1): a separate guest kernel for
              jail-escape containment plus a per-VM routable network.
              "bwrap" is the FALLBACK — a default-deny bubblewrap jail for
              hosts without KVM / nested virt, or a deliberately lighter
              compartment. munix needs `munixPackage` + `munixClosure`.

              Named `enforcement`, not `tier`, on purpose. "tier" is already
              claimed in this project by the backup data-tier contract
              (`global` / `lan` / `machine`, see the README), and by MoE
              expert tiering in `ai.strata`. Three unrelated axes sharing one
              name is how someone configures the wrong one and sees no error,
              so the axes get distinct names: `enforcement` = how it is
              contained, `tier` = where its data is backed up.
            '';
          };

          bindReadonly = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "/home/tux/work/myrepo" ];
            description = "Host directories bound READ-ONLY into this compartment.";
          };

          bindReadwrite = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "/home/tux/research-out" ];
            description = ''
              Host directories bound READ-WRITE into this compartment.
              The real home is NEVER bound (default-deny) — every path the
              agent may touch is declared here.
            '';
          };

          mcpServers = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule ({ ... }: {
              options = {
                command = lib.mkOption { type = lib.types.str; };
                args = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
                env = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
              };
            }));
            default = { };
            example = lib.literalExpression ''{ donsetch.command = "donsetch"; }'';
            description = ''
              This compartment's MCP servers (its TOOLS), rendered into
              the profile's config.yaml as `mcp_servers`. Different
              profiles get different tools.
            '';
          };

          settings = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            example = { model.default = "anthropic/claude-sonnet-4"; };
            description = ''
              Additional behavioral settings merged into the profile's
              config.yaml (declared keys win over the agent's learned keys).
            '';
          };

          soul = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "The compartment's persona, rendered to SOUL.md (null = leave the agent's own).";
          };

          network = lib.mkOption {
            type = lib.types.enum [ "full" "none" ];
            default = "full";
            description = ''
              Coarse egress posture (munix). "none" → munix
              `--no-network`: a TOTAL boundary — the guest has no outbound
              at all, including no model. Use it only when the model is
              bundled in-VM. "full" → the guest has network; the
              FINE-GRAINED boundary (model-host yes / internet no /
              git-remote only) is enforced by the host-level tap firewall
              over the per-VM virtio-net, not by this flag. A reviewer
              that reaches a VPN model host uses "full" + a tap rule that
              allows the model host and drops the internet.
            '';
          };

          gpu = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "munix: pass GPU through (omit `--no-gpu`). Off by default.";
          };

          munixPackage = lib.mkOption {
            type = lib.types.nullOr lib.types.package;
            default = null;
            example = lib.literalExpression "inputs.munix.packages.\${system}.munix";
            description = ''
              munix: the munix runner package. Provided by the
              consumer's flake (deniac deliberately does not pin
              libkrun/KVM for an optional backend). Required when
              enforcement = "munix".
            '';
          };

          munixClosure = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "/nix/store/abcd-reviewer-toplevel";
            description = ''
              munix: the NixOS toplevel closure the microVM boots
              (built by the host / a separate aspect; munix's input is
              `system.build.toplevel`). Required when enforcement = "munix".
            '';
          };

          storeSlice = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                mode = lib.mkOption {
                  type = lib.types.enum [ "closure" "erofs" ];
                  default = "closure";
                  description = ''
                    How the guest's /nix/store is restricted.

                    `"closure"` (default) — munix `--store-mode closure`:
                    every path in `storePaths` becomes its own virtiofs
                    submount. The guest reads the host store's own bytes,
                    so the restriction costs ZERO extra disk — N guests
                    share the store they already occupy. This is what a
                    fleet of sandboxed VMs should run.

                    `"erofs"` — the closure is materialised as one erofs
                    block-device image (`image`) mounted at /nix/store by
                    micro-activate. Cheaper at boot (one mount instead of
                    ~1.2k submounts) but it is a full COPY of the closure:
                    2.65 GiB compressed per guest, and every additional
                    sandboxed app adds another one. Use only where boot
                    latency genuinely matters.

                    Both modes need a munix that has `--store-mode`
                    (our fork branch `feat/store-mode`; upstream
                    clan/munix PR #40).
                  '';
                };

                storePaths = lib.mkOption {
                  type = lib.types.addCheck lib.types.str (v:
                    lib.strings.hasSuffix "/store-paths" v
                    || throw ''
                      deniac.ai.hermes: storeSlice.storePaths must be the closureInfo
                      store-paths FILE, not the closureInfo directory. Got:

                        ${v}

                      munix consumes it as a shell redirect (closure mode
                      .munix-wrapped fd 16, erofs mode --sandbox-store):

                        while read -r p; do ... "--ro-bind" "$p" "$p" ... done < "$STORE_PATHS"

                      Pointed at the directory that read fails immediately with
                      "read: 0: read error: Is a directory", munix then dies on
                      "bwrap: execvp muvm: No such file or directory" and the
                      guest never boots. Nothing catches this at eval otherwise,
                      so the type refuses it here. Write it as:

                        storePaths = "''${toString closureInfo}/store-paths";
                    '');
                  example = "/nix/store/efgh-closure-info/store-paths";
                  description = ''
                    Path to the closureInfo `store-paths` FILE — the
                    newline-delimited list of host store paths this guest's
                    closure needs. In `"closure"` mode it is passed as munix's
                    `--store-paths` (one virtiofs bind per line); in `"erofs"`
                    mode as `--sandbox-store` (the paths muvm must read
                    pre-activation). This is the file `pkgs.closureInfo` writes
                    inside its output directory, not that directory itself; the
                    type above refuses the directory form.
                  '';
                };

                image = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "/nix/store/abcd-researcher-store-erofs";
                  description = ''
                    `"erofs"` mode only: the prebuilt erofs store image,
                    passed as munix's `--store-dev`. Must be set when
                    `mode = "erofs"` (checked by an assertion on the
                    aspect); leave it `null` in `"closure"` mode, where
                    nothing is materialised.
                  '';
                };
              };
            });
            default = null;
            example = lib.literalExpression ''
              {
                mode = "closure";
                storePaths = "''${toString guest.packages.''${system}.researcher-store-paths}/store-paths";
              }
            '';
            description = ''
              munix: closure-only /nix/store (opt-in). `null` keeps
              the whole-host store bind. When set, the guest sees only the
              paths listed in `storePaths`. `mode = "closure"` (the
              default) bind-mounts them straight from the host store at no
              disk cost; `mode = "erofs"` needs the prebuilt `image` and
              pays a full copy of the closure per guest. Build the inputs
              with `pkgs.closureInfo` (and `mkfs.erofs` for erofs mode) —
              see the hermes-munix-guest template's
              `researcher-store-paths` / `researcher-store-erofs` outputs.
            '';
          };

          modelKeySecret = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "/run/agenix/hermes-model-key";
            description = ''
              Path to the DECRYPTED model API key, read by the launcher
              at run time and passed into the compartment as the
              `HERMES_MODEL_KEY` env var. The path is secret-manager
              agnostic — agenix (`/run/agenix/<name>`) and sops-nix
              (`/run/secrets/<name>`) both work; the launcher just reads
              the file. `null` = keyless (halogen's current posture).
              The key NEVER lives in the nix store — only in the
              decrypted runtime file and the compartment's env.
            '';
          };

          extraPackages = lib.mkOption {
            type = lib.types.listOf lib.types.package;
            default = [ ];
            description = "Extra packages on this compartment's PATH.";
          };

          env = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Extra environment variables set inside this compartment.";
          };
        };
      };

      jailFor = name: prof:
        if prof.enforcement == "munix" then
          hj.mkMunixLauncher pkgs prof.munixPackage name prof
        else
          hj.mkBwrapJail pkgs cfg.package name prof;

      profilePackages = lib.mapAttrsToList jailFor cfg.profiles;
    in
    {
      options.deniac.ai.hermes = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Install the compartmentalized Hermes jails.";
        };

        package = lib.mkOption {
          type = lib.types.package;
          default = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.hermes-agent;
          defaultText = lib.literalExpression "inputs.llm-agents.packages.\${system}.hermes-agent";
          description = "The hermes-agent package (from the existing llm-agents pin).";
        };

        profiles = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule profileOpts);
          default = { };
          description = ''
            The role compartments. Each generates a launcher
            (`hermes-jailed-<name>` for bwrap, `hermes-munix-<name>` for
            munix) and renders its declared config.yaml + SOUL.md into
            `~/.hermes/profiles/<name>/` with a preserve-learned-keys
            merge.
          '';
        };
      };

      config = lib.mkIf cfg.enable {
        home.packages = profilePackages;

        # erofs is the only mode that materialises anything, so it is the
        # only one that can be half-configured: `mode = "erofs"` with no
        # `image` would render `--store-dev null` and die at boot. The
        # type can't express that cross-field rule (image is optional for
        # closure mode), so it is asserted here instead.
        assertions = lib.mapAttrsToList (name: prof: {
          assertion = prof.storeSlice == null
            || prof.storeSlice.mode != "erofs"
            || prof.storeSlice.image != null;
          message = ''
            deniac.ai.hermes: profile `${name}` sets storeSlice.mode = "erofs" but no
            storeSlice.image. erofs mode passes it to munix as `--store-dev`
            and cannot work without it. Either point it at the prebuilt image
            ("''${toString guest.packages.''${system}.researcher-store-erofs}") or
            leave storeSlice.mode at "closure", which needs no image and
            costs no extra disk.
          '';
        }) cfg.profiles;

        # Render each profile's declared config + SOUL into its HERMES_HOME,
        # merging over any learned config (declared wins).
        home.activation.hermes-render-profiles = lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ] ''
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: prof: ''
            PH="$HOME/.hermes/profiles/${name}"
            mkdir -p "$PH"
            ${hj.mergeScript pkgs} ${hj.renderProfileConfig pkgs name prof} "$PH/config.yaml"
            ${if prof.soul != null then "cp -f ${hj.renderProfileSoul pkgs name prof} \"$PH/SOUL.md\"" else ""}
          '') cfg.profiles)}
        '';
      };
    };
  };
}
