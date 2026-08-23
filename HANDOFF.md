# HANDOFF — agent-core bootstrap

**For:** a fresh-context agent picking this up
**Date:** 2026-08-23
**State:** empty repo. Your job: build the thing the spec describes.
**Spec (canonical, read first):** [`docs/agent-core-spec.md`](docs/agent-core-spec.md) — audited 3 passes (pass 3 adds multi-profile support + hermes release-tag pin), all findings folded in. It is the source of truth. This file just orients you.

---

## Mission (one paragraph)

Extract a minimal, inheritable NixOS flake from Wes's existing agent host so that **any new box can become a hermes agent host with a ~20-line flake**. The core pins its own lockfile (including nixpkgs); hosts ride the pin. One `nixos-rebuild switch` renders both system config AND hermes' `config.yaml` — that property already works on the reference host via the hermes NixOS module; do not lose it. **First real consumer is a NEW podcast-infrastructure host** (fresh hermes agent, injector+bifrost defaults ON, multi-profile expected later); the reference host migrates onto it after core is proven there. That host staying functional through migration remains the acceptance test.

## Source material (read-only — port from these)

All in the private reference-host repo:

| File | What to take from it |
|---|---|
| `flake.nix` | Input graph (hermes-agent, mcp-injector, datom, workshop, mcp-nixos, clojure-mcp, opencode-flake), overlays, inline `core package bundle` module (~line 130-164) |
| `hermes.nix` | Generic hermes settings defaults → `modules/agent.nix` (see spec moves table for exact split; delegation + datom enable are CORE, TTS voice/timers/identity symlinks are HOST). agent.nix also owns multi-profile support (`hermes.profiles.<name>` — spec section "Profiles: Multi-Agent Hosts", added after the multi-agent prior-art investigation) |
| `common/configuration.nix` | Generic halves → `modules/base.nix` (zram, nix settings, journald, firewall base, user scaffolding, packages, acme defaults, sudo NOPASSWD for workspaceUser). Host bits stay behind |
| `common/mcp-injector.nix` | → `modules/llm.nix`. **Gate everything host-coupled**: HA/searxng servers point at an external host, `environmentFile` hardcodes `home-assistant.env`, thunder chain needs SSH tunnel |
| `common/bifrost.nix` | → `modules/llm.nix` (podman container) |
| `common/searxng.nix` | → `modules/searxng.nix` opt-in. Parameterize `SEARXNG_SECRET` (currently hardcoded, line ~181). Gating must detach dependents: hermes `SEARXNG_URL` env (`hermes.nix:269`) + injector searxng server |
| workspace clone unit (`configuration.nix:205`) | → `modules/workspace.nix`. Fix: clones-once today (`if [ ! -d .git ]`) — make it clone-or-pull |

## Hard rules (violating any of these = doing it wrong)

1. **Secret-clean by construction.** No literal API keys/tokens/secrets anywhere in this repo. The reference deployment embeds several in its service configs — do NOT port them as literals; parameterize into env files/options. A grep check for secret shapes should pass.
2. **No host names in core.** No host or operator names. Host-coupled things exist only behind options that default off/empty.
3. **No persona.** SOUL/skills/memory/scripts live in the host's `workspaceRepo`, cloned by `modules/workspace.nix`. Core ships zero persona.
4. **Pin everything** in this repo's `flake.lock` including nixpkgs. No `follows = "nixpkgs"` on inputs unless unavoidable.
5. **hermes-agent pins a release tag** (`v2026.8.19` at spec time), not rolling main — see spec Versioning section.
6. **Defaults compose cleanly.** Plain values hosts can override without mkForce. Two documented mkForce exceptions allowed (hermes hardening overrides `hermes.nix:277`; injector sandbox forces `mcp-injector.nix:10`) — document them in `docs/hermes-wiring.md` when you write it.
7. **Format:** `alejandra` on every `.nix` file. Verify: `nix flake check --no-build`.

## Target layout

```
flake.nix              # inputs + mkAgentHost + nixosModules.* exports
flake.lock             # fully pinned
lib.nix                # mkAgentHost
modules/base.nix       # generic NixOS base
modules/agent.nix      # hermes service + settings defaults + datom
modules/llm.nix        # bifrost + mcp-injector + core package bundle bundle
modules/searxng.nix    # opt-in, default off
modules/workspace.nix  # workspaceRepo clone-or-pull unit + /etc/nixos symlink
modules/creds.nix      # credentials dir convention + tmpfiles
defaults/model-chains.nix
docs/hermes-wiring.md  # host-side wiring expertise (write last)
```

## Suggested order

1. `flake.nix` skeleton: copy the reference host's input graph minus microvm/nixos-generators/buzz-flake. Get `nix flake check --no-build` green on an empty outputs set.
2. Port modules one at a time in spec order (base → creds → llm → agent → workspace → searxng), checking eval after each: `nix eval .#nixosModules.default` style sanity or a scratch test host.
3. Write `lib.nix` / `mkAgentHost` per the spec contract (options: hostName, system, adminKeys, credsDir, workspaceUser, workspaceRepo, hermes{model,tts,timers,profiles,multiplex}, injector{chains,servers,governance}, services.searxng.enable, extraModules).
   NOTE: agent.nix owns a SINGLE gateway generator used by default AND named profiles — do not use upstream `services.hermes-agent` for units (spec pass-3 review finding 5).
4. Scratch test: a throwaway `nixosConfigurations.testhost = mkAgentHost {...}` that evaluates clean. Delete before commit if you like, or keep as a check.
5. THEN migrate the reference host onto it (that's a separate session — coordinate with Wes; involves a real rebuild on the live box).

## Repo logistics

- **Input-passing convention (locked at skeleton):** every module takes `coreInputs` (all flake inputs + `self`) at import time and returns a NixOS module: `import ./modules/x.nix coreInputs`. `mkAgentHost` must thread the same inputs via `specialArgs` inside its `nixosSystem` wrapper. Do not write modules as plain `{config, lib, pkgs, ...}:` functions that need flake inputs.
- **Forge is primary; GitHub mirrors consumers.** `mcp-injector` (github:noblepayne/mcp-injector) and `datom` (github:noblepayne/datom, single-branch main) live on forge first, then mirror to public GitHub so downstreams can eval without forge SSH. Mirror flow: push forge → push same refs to GitHub. datom history was re-rooted 2026-08-23 onto an orphan `init` after a 108MB `.lsp/` cache blob purge; all pre-rewrite revs are orphaned; the reference host's lock needs a `datom` update at migration.
- **nixpkgs skew is accepted:** no `follows` anywhere means the lock holds ~8 distinct transitive nixpkgs revs. That's the cost of hard rule 4 — don't "fix" it by adding follows.
- **Branch ontology (2026-08-23):** every repo is single-branch `main` with a clean orphan root — no mirror/feature branch pairs. Forge and GitHub mains are identical; forge is where dev lands first. clojure-mcp remains branch-pinned `feat/flake` upstream.
- Remote once Wes creates it on the forge:
  `git remote add origin git@github.com:noblepayne/agent-core.git  # plus forge when created`
- Don't push until Wes confirms the forge repo exists.
- Commit small and often; conventional-ish messages fine.
- Spec lives canonically here (`docs/agent-core-spec.md`, derived from the reference host's spec). If you change decisions, update BOTH copies or note divergence.

## Context you'll want

- Hermes product docs: `hermes-agent.nousresearch.com/docs/llms.txt` (there's also a `hermes-docs` skill in the reference workspace).
- Why the injector stack exists: `<reference repo>/specs/mcp-injector-vision.md`.
- **Model-chain maintenance:** persona skill `update-llm-models` (in the reference workspace);
  probes models for tool-calling then rewrites chains — but its paths target
  `common/mcp-injector.nix`. After extraction it must point at
  `agent-core/defaults/model-chains.nix` instead (update the skill during reference-host migration).
- Multi-agent prior art: an internal production deployment running 7 named hermes agents via per-profile units/wrappers; design folded into spec section "Profiles: Multi-Agent Hosts" (audit pass 3).
- Operational gotchas distilled so far: `<reference repo>/LEARNINGS.md`, `<reference repo>/docs/CONFIG-ARCHITECTURE.md`.

## Status checklist

- [ ] flake.nix skeleton + pinned lock (hermes-agent @ release tag)
- [ ] modules/base.nix
- [ ] modules/creds.nix
- [ ] modules/llm.nix (gated host-coupled bits)
- [ ] modules/agent.nix (incl. datom, delegation defaults, hermes.profiles.<name> multi-profile units/wrappers, multiplex opt-in)
- [ ] modules/workspace.nix (clone-or-pull)
- [ ] modules/searxng.nix (parameterized secret, detaches dependents when off)
- [ ] lib.nix / mkAgentHost contract
- [ ] test host evaluates clean (`nix flake check`)
- [ ] alejandra-clean
- [ ] docs/hermes-wiring.md
