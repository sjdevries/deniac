# ── APPROVED tool list for the coder VM closure ──────────────────────
# The TRUSTED side of the tool-request loop.
#
#   agent asks  →  ~/tool-requests/coder.txt   (UNTRUSTED, raw)
#   human reviews the PACKAGE (typosquat / CVE check — the request is
#   itself a supply-chain vector) and promotes approved ones HERE.
#   rebuild     →  nix build …#packages.x86_64-linux.coder-store-erofs
#   restart     →  the coder VM boots the new slice with the tool.
#
# mkGuest reads this list, so the closure ONLY ever contains APPROVED
# tools — never whatever the agent asked for. The VM stays read-only;
# the only mutable thing is this tracked, reviewed list.
#
# NOTE (skeleton): this lives in the template for now because the
# template owns the coder closure. In a fuller design the approved list
# moves to the CONSUMER fleet (which would build the coder closure via
# `inputs.hermes-munix-guest.lib.mkGuest { packages = base ++ approved; }`),
# keeping the user's tool decisions out of the public framework repo.
pkgs: [
  # Approved packages go here, e.g.:
  # pkgs.cargo
  # pkgs.python3
  # pkgs.go
]
