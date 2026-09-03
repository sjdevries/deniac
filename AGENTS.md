# AGENTS.md

Operating rules for agents (and humans) working in this repo. **Read this before
touching code, running a build, or doing research.** The rules in §1 are
non-negotiable.

---

## Repo in one paragraph

**deniac** is a public, à-la-carte library of
[den](https://github.com/denful/den) aspects for NixOS home labs — *domain*
aspects (`filesystems`, `state`, `networks`, `gaming`) with software
*sub-aspects* underneath (`filesystems.zfs`, `state.impermanence`), composed via
`includes` and shared across flakes through den's namespace mechanism.
**MIT-licensed, early development**: the design is settled (see the README), the
first aspects are in progress. **The README is the design home** — aspect model,
data-tier contract, status checklist — keep it in sync with any structural
change. deniac is grown from a private reference fleet; that fleet's repo is
**deliberately not named anywhere in this repo**.

---

## 1. ABSOLUTE RULES (build & git) — no exceptions

### 1.1 A clean tree is required before ANY build or run

> **The git repo MUST be in a clean state before attempting any build.**
> **Never attempt to build or run from a dirty tree.**

- Before running **any** build or eval — `nix build`, `nix run`, `nix flake
  check`, `nix flake metadata`, or any other command that evaluates this flake —
  the working tree must be clean:

  ```sh
  git status --porcelain        # MUST print nothing
  ```

- **If the tree is dirty, stop.** Stage and **commit** the change with an
  accurate description (§1.3), verify `git status --porcelain` is empty,
  *then* build.

### 1.2 The rename-breaks-builds trap (why 1.1 is absolute)

> **The build can and does break if you rename or move a module file and do not
> `git commit` the change first.**

The module tree is resolved from disk at eval time (via `import-tree` + den).
Renaming or moving a module file without committing leaves the build pointing at
stale references and produces confusing, hard-to-diagnose breakage. **Commit
before you rename, move, or restructure any module.**

### 1.3 Commit with accurate descriptions

- **Always commit changes with accurate descriptions.** The message must state
  *what* changed and *why*.
- **Iterating on a stubborn fix is fine — and good.** Committing each attempt
  separately (one commit per variant) keeps every attempt independently
  buildable and **revertible**. Name the variant, though — bare `test` /
  `wip` / `fix` doesn't tell you what differs between attempts:

  - `filesystems.zfs: attempt 2/3 — pool from disko, not zfs module`

### 1.4 `main` is the public stable branch

- `main` is always expected to be **clean and buildable**. Small changes (a doc
  tweak, a config nudge, one obvious fix) commit directly on `main`: clean
  tree, accurate message, build to confirm.
- Non-trivial work branches off clean `main`: `feat/...`, `fix/...`, `chore/...`
  (e.g. `feat/filesystems-zfs`) — commit, build/test on the branch, merge back,
  **build `main` again** to confirm it stayed green.
- A public remote exists (`origin` = GitHub). **Never push a dirty or
  unbuildable state to `main`.** Feature branches may be pushed and opened as
  PRs when review is wanted. No force-push to `main`.

---

## 2. Where things go

| Kind of artifact | Goes to |
| --- | --- |
| **Aspects** (domain + sub-aspects) | `modules/` — den auto-loads the tree (`import-tree`); `_`-prefixed dirs are ignored |
| **Aspect tests** | `modules/` — den modules exposing `flake.tests.<name>` via the `denTest` helper (same shape as den's own `templates/ci/modules/`) |

This repo has no `research/` or `result/` directories — it ships aspects, not
scratch space. Working notes are a local-only concern (e.g. a gitignored
`AGENTS.local.md`), never committed here.

---

## 3. den pin & verification

- **den is a pinned flake input.** Verify den syntax against **the pinned
  input** — not against the web, not from memory. The den docs move; the pin
  doesn't. A local clone of den's docs checked out at the pinned tag is the
  fastest reference when one is available in your environment.
- The README's consumer example was written against the **v0.18.0** namespace
  guide. Before the first aspect ships, re-verify the exact namespace/export
  syntax against *this repo's* pinned den input, and fix the README to match
  (known re-verification step).
- Bumping the den pin is a deliberate, separate commit: new pin +
  re-verification, message says what changed.

---

## 4. License & content discipline (public repo)

- **MIT.** This repo is public and read by strangers:
  - **No secrets, no credentials, no personal data** — ever.
  - **Never reference the private sister repo** (its name, paths, hosts,
    hardware details) in code, docs, commits, or issues.
- **The core stack is all permissive** (verified against upstream, 2026-07):
  - **den** — Apache-2.0 (flake input)
  - **nixpkgs** — MIT (repo `COPYING`; flake input)
  - **home-manager** — MIT (repo `LICENSE`; flake input)

  Depending on all three as flake inputs is unproblematic, and even vendoring
  a snippet is license-compatible — **preserve the copyright notice with
  anything you copy**.
- **What stays out:** nixpkgs *packages* (e.g. `pkgs.steam`) each carry their
  own license and are referenced as inputs, never copied into this tree. Code
  copied into this repo should be permissive (MIT/BSD) with notices intact.
- **Dependencies are flake inputs, not vendored code.** den, nixpkgs,
  home-manager, etc. are pinned inputs — that is the entire dependency model.
- **Provenance:** when an aspect is adapted from a community implementation,
  name the source repo + file in the commit message so the origin is traceable.

---

## 5. Aspect conventions

- **Domain aspect + sub-aspects.** A domain aspect (`filesystems`) owns a
  feature area; the specific software lives under it via den's `provides`
  (`filesystems.zfs`). Cross-aspect dependencies compose via `includes` (a DAG).
- **Layout is zero-cost in den** — aspects are identified by name, not path.
  Default to a **single file per domain aspect**; split a sub-aspect out into
  `modules/<domain>/<sub>.nix` when it grows (~150–200 lines) or becomes its
  own task, and let the parent file become a small `includes` index.
- **Stay overridable** — `lib.mkDefault` where downstream flakes should be able
  to override; host/user-parametric behavior via den's `__functor` pattern.
- **The bar per aspect (no aspect ships without all three):**
  1. a `denTest` (exposed as `flake.tests.*`),
  2. documentation (what it configures, which options, defaults),
  3. a usage example (in its docs or the README).

---

## 6. Community first (before inventing)

> **When adding a capability — a service, a program, or a pattern — first check
> how the community implements it and adapt that. Do not invent from scratch.**

- **Where:** the **dendrix** registry (live roster: https://dendrix.denful.dev/)
  — community den repos with per-repo aspect trees.
- **How:** read the aspect's module in that repo (raw GitHub), note the option
  structure, defaults, and edge cases, then write it in **deniac's** style
  (domain/sub-aspect model, `lib.mkDefault`, `denTest`).
- **Status:** reference implementations only — do not add community repos as
  flake inputs or pin to their aspects.
- **Provenance** per §4: name the source in the commit message.

---

## 7. Status & roadmap

- The **"Status" checklist in the README is the roadmap.** Update it in the
  same commit that lands the item (an aspect, a test, docs, templates).
- The design draft with full verification notes lives in the private sister
  repo — for this repo, the README is the source of truth.
