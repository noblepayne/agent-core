# Agent-Core Spec — Reusable Hermes Host Platform

**Status:** Active — audit passes 1–3 complete
**Owner:** Wes Payne
**Audience:** REPL (implementation), future host owners
**Date:** 2026-08-16 (spec, audit pass 1, independent audit pass 2); 2026-08-23 (pass 3: multi-profile + release-tag pin amendments)

---

## Goal

A minimal, inheritable NixOS flake that turns a blank box into a **hermes agent host**.
Downstream hosts (first: a podcast-infra host) import it as a flake input, pass host-specific knobs,
and get system + hermes config rendered by **one** `nixos-rebuild switch`.

```
one flake update  ─▶  agent-core.lock bumps hermes/injector/datom/nixpkgs
one rebuild       ─▶  systemd units AND hermes config.yaml, together
downstream        ─▶  thin flake: mkAgentHost { ... } + host bits
```

"Built once": hermes binary, injector jar, datom store are the *same derivations* for every
host (hermes config is data rendered by a module). Hosts with a shared binary cache add it via options.

---

## Decisions (locked, not debatable)

| Decision | Detail |
|---|---|
| **Name: `agent-core`** | Forge repo `repl/agent-core`. Locked. |
| **Versioning: pin for now** | `agent-core` owns a fully-pinned `flake.lock` **including nixpkgs**. Hosts do NOT bring their own nixpkgs by default; they ride the pin. Exception for host-side inputs (workshop, buzz-flake) — see "Versioning & Pinning". Escape hatch later: hosts add `inputs.agent-core.inputs.nixpkgs.follows`. |
| No microvm | Dropped entirely. Not a core concern. |
| No hosting-provider base in core | Infra base (e.g. a provider module) stays per-host. Host picks its own infra base. |
| Minimal path | Core ships: base + agent (hermes) + llm (injector/bifrost) + workspace clone + creds. |
| **LLM stack defaults ON** (2026-08-23) | `injector.enable` and `bifrost.enable` default **true** — first consumers (podcast host, reference host) both run the full stack. Disabling either must stay a one-line setting. Enabling injector with zero chains eval-fails loudly (inert proxy is worse than an error). Hermes itself works against any OpenAI-compatible provider without the stack; the stack is model-serving infra, opt-out not opt-in. |
| **First consumer: new podcast-infra host** (2026-08-23) | First real deployment boots a fresh hermes agent on an existing NixOS host for podcast infrastructure. Bootstrap story matters more than the later reference-host migration: box → flake → rebuild → agent alive → persona trained over time. Multiple profiles expected later on this host. The reference host migrates once core is proven there. |
| searxng stays | Moved into core as an opt-in module (`services.agent-core.searxng.enable`), default off. **Secret must be parameterized** (today `common/searxng.nix` hardcodes `SEARXNG_SECRET`). |
| creds convention in core | Standard credential layout + tmpfiles. Not secret provisioning. |
| `workspaceRepo` param | Core clones the host's persona repo; it does NOT ship a persona. |
| Core is secret-clean by construction | No literal secrets in core source. (See Audit pass 1 — the reference deployment embeds several.) |
| One-rebuild property | Core must preserve: hermes config flows from Nix settings, not hand-edited YAML. |
| **hermes-agent pinned to release tags** (2026-08-23) | Core's `hermes-agent` input pins a tagged release (`v2026.8.19` = v0.20.5 at spec time), not rolling `main`. The reference host tracked main @ an Aug 4 rev (~2.5 wk stale at decision time); migration folds this in.
| **Multi-profile hermes in core** (2026-08-23) | Core supports N named hermes agents per host alongside the default profile. One gateway unit per profile by default; multiplexing is an opt-in flag. See "Profiles: Multi-Agent Hosts". |

## Versioning & Pinning (locked — revisit later)

- `agent-core/flake.lock` is authoritative: **every** input including `nixpkgs` is pinned there.
- Core-only hosts add `agent-core` as their **only** flake input. No host-side `nixpkgs`,
  no `follows`. Hosts that need extra packages reach into `agent-core.inputs.nixpkgs`.
- **Exception (resolved pass 2):** hosts that keep host-side flake inputs (the reference host's
  `workshop`, `buzz-flake` — both carry `inputs.nixpkgs.follows`) declare their own
  `nixpkgs` input for those to follow. The core's lock stays authoritative for the
  *platform*; host-side inputs are the host's domain. The reference host keeps its two host inputs
  during/after migration. Core itself does NOT bundle workshop/buzz (keeps core minimal).
- A platform bump = `nix flake update` **inside agent-core**, then hosts bump `agent-core`'s
  rev (or consume branch-rolling `?ref=main`). One repo centralizes supply-chain bumps.
- **hermes-agent pins release tags, not main** (2026-08-23): `url = "github:NousResearch/hermes-agent?ref=v2026.8.19"`.
  Upstream moves fast (~746 commits between v0.20.4 and v0.20.5) and the Nix flake/module is
  Tier-2 "best effort" upstream — a tagged pin keeps the platform stable while still allowing
  deliberate bumps. The reference host tracks main; migration folds this in.
- Tradeoff accepted for now: core-only hosts can't independently move nixpkgs forward. Fine
  until one genuinely needs a newer nixpkgs — the escape hatch is the `follows` line.

---

## What Moves Where

### IN core (generic, parameterized)

| Source file (reference host) | Becomes | Notes |
|---|---|---|
| `flake.nix` (inputs + overlays + the core package bundle) | `flake.nix` | The input graph IS the platform. Core inputs: hermes-agent, mcp-injector, datom, workshop, mcp-nixos, clojure-mcp, opencode-flake, nixpkgs. the core package bundle (mcp-nixos, clojure-mcp, opencode) → llm module. **microvm + nixos-generators dropped; buzz-flake stays host-side.** |
| `common/configuration.nix` (generic halves) | `modules/base.nix` | zram, nix settings/substituters, journald retention, firewall base, user scaffolding (keys via param), common system packages, acme defaults, **sudo NOPASSWD for `workspaceUser` + wheel** (the agent needs sudo for rebuilds — today `configuration.nix:95`). |
| `hermes.nix` (service scaffolding) | `modules/agent.nix` | Generic settings defaults: injector provider, model, **delegation** (model `subagent`, provider injector — `hermes.nix:87`), `workspaceDir` (default `/var/lib/hermes/workspace`), compression thresholds, auxiliary tasks, display, session_reset, gateway/systemd-watchdog, hardening overrides, extraPackages, **datom service enable + plugin symlink** (`flake.nix:119` + `hermes.nix:304`), `environmentFiles` *pattern* (empty default), webhook platform (port as option), timer *templates* for memory-snapshot + reflection, **named-profile support**
   (`hermes.profiles.<name>` — see "Profiles: Multi-Agent Hosts"). |
| `common/mcp-injector.nix` | `modules/llm.nix` | Injector service + governance defaults + PII + MCP server defs. Model *chains* are defaults. **Host-coupled bits must be gated, not defaulted:** HA + searxng servers (point at an external smart-home/search host — `mcp-injector.nix:79,89`), `environmentFile` (`mcp-injector.nix:30` — omit unless a server needs it), thunder chain's SSH tunnel (`mcp-injector.nix:263`). |
| `common/bifrost.nix` | `modules/llm.nix` | Podman/bifrost container, tmpfiles. |
| `common/searxng.nix` | `modules/searxng.nix` | Opt-in, default off. Engine list + settings become defaults; **`SEARXNG_SECRET` moves to an option/envFile** (not literal). **Gating must also detach dependents:** when off, no `SEARXNG_URL` env on hermes (`hermes.nix:269`) and no searxng MCP server. |
| `common/configuration.nix` (workspace-clone unit) | `modules/workspace.nix` | Clones-or-**pulls** `workspaceRepo` param (today it clones once and never updates — `configuration.nix:218`) and symlinks its `flake.nix` → `/etc/nixos/flake.nix`. **The thin host flake lives inside the persona repo** — that's the composition contract. |
| creds tmpfiles | `modules/creds.nix` | `/var/lib/<service>/credentials` convention. |
| The infra-base module, `common/microvm.nix` | **nowhere** | Per-host / gone. `common/microvm.nix` is already dead (not in flake.nix's module list). |

### OUT of core (host layer)

| Source file | Why |
|---|---|
| `hermes.nix` identity bits | TTS voice selection + voices dir, city-specific timers (traffic checks, morning briefing, DNS sync), buzz env + `buzz-bridge.env` wiring, identity symlinks (SOUL/USER/MEMORY → from workspace), webhook secret + port choice. |
| `flake.nix` (checks + microvm config) | **firewall-sanity check** (`flake.nix:78`) — host-specific, and its hardcoded `8644/4242/51820` should be derived from `networking.firewall` config instead. **The microvm configuration** (`flake.nix:65`) — delete outright (microvm dropped). |
| `common/configuration.nix` host bits | hostname, internal vhosts, VPN stack + certs, personal users, host-specific pollers, the workspace unit (becomes the core's workspace module + host params). |
| `common/camofox.nix`, `miniflux.nix`, `buzz-relay.nix`, `buzz-bridge.nix` (+ the two `.py`) | Deferred. Personal/host-layer today (internal domains, channel IDs, proxy IPs, embedded keys). Become opt-in core modules later only if a second host wants them — and only after their secrets are parameterized. |
| `buzz-flake` (input + `systemPackages` wiring, `flake.nix:42,161`) | Deferred with the buzz modules. The reference host keeps the input + wiring host-side. |
| `memory/`, `skills/`, `scripts/`, `mlb-stats/`, `SOUL.md`, `AGENTS.md` | The persona. Lives in the workspace repo, injected via `workspaceRepo`. |

---

## Repo Layout (forge: `repl/agent-core`)

```
agent-core/
├── flake.nix              # inputs + mkAgentHost + module set
├── flake.lock             # THE lockfile. Bumps happen here.
├── modules/
│   ├── base.nix           # generic NixOS base
│   ├── agent.nix           # hermes service + settings rendering + named profiles
│   ├── llm.nix            # bifrost + mcp-injector + the core package bundle
│   ├── searxng.nix        # opt-in
│   ├── workspace.nix      # workspaceRepo clone unit
│   └── creds.nix          # credential layout + tmpfiles
├── defaults/
│   ├── model-chains.nix   # brain/coder/thinker/... chain defaults (host-overridable)
├── docs/
│   └── hermes-wiring.md   # host-side hermes expertise: how WE wire
│                          #   hermes→injector→bifrost→datom, gotchas.
│                          #   Distilled from LEARNINGS.md + memory.
└── lib.nix                # mkAgentHost lives here
```

`lib.nix` re-exports the modules so downstreams can also import them raw
(`agent-core.nixosModules.*`) without the helper.

---

## The Contract: `mkAgentHost`

```nix
# in the downstream host flake:
nixosConfigurations.<host> = agent-core.lib.mkAgentHost {
  hostName        = "myhost";
  system          = "x86_64-linux";
  adminKeys       = [ "ssh-ed25519 AAAA..." ];   # per-host; NOT in core
  credsDir        = "/var/lib/hermes/credentials";
  workspaceUser   = "hermes";                    # default: hermes
  workspaceRepo   = "https://forge.example.com/repl/myhost.git";

  hermes = {
    # settings merged into the rendered config.yaml (default profile)
    model = "brain";            # delegation model (see injector.chains)
    tts = { provider = "piper"; };
    timers = [];                # host timers (traffic checks, briefings, …)
    multiplex = false;          # true → default gateway serves all profiles

    # Optional extra named agents (see "Profiles: Multi-Agent Hosts")
    profiles = {
      # researcher = {
      #   settings.model.default = "...";
      #   environmentFiles = [ "/var/lib/hermes/credentials/researcher.env" ];
      #   workspaceRepo = "https://forge.../researcher-workspace.git";
      # };
    };
  };

  injector = {
    chains = {};                # {} → core defaults
    servers = {};               # EXTRA MCP servers, additive only
    governance = {};            # {} → core defaults
  };

  services = { searxng.enable = false; };   # opt-in modules

  extraModules = [
    ./host.nix                  # VPN/mesh, nginx vhost, personal user, infra base — anything host-shaped
  ];
};
```

Contract guarantees:
1. Every rendered `config.yaml` — the default profile **and** every named profile — is
   produced from Nix on activation. `HERMES_MANAGED=true` blocks runtime drift on each.
   (This is the "one rebuild does both" property.)
2. Core defaults compose cleanly — plain values that hosts override without `mkForce`.
   **Documented exceptions** where the upstream module hard-codes behavior: hermes service
   hardening overrides and injector's `HOME`/sandbox `mkForce`s (`hermes.nix:277`, `mcp-injector.nix:10`).
   Those ship as core defaults using `mkForce` internally — hosts that must override *those
   specific knobs* also use `mkForce`, and the spec's `docs/hermes-wiring.md` calls them out.
3. The systemd workspace unit is parameterized by `workspaceRepo` + `workspaceUser`; it
   clones-or-pulls on activation and symlinks `flake.nix → /etc/nixos/flake.nix`. **The thin
   host flake lives inside the persona repo** — one repo per host, `git push → rebuild`.
4. Core never references a host or operator by name.
5. No host-coupled defaults: core registers **no** MCP server, env file, or injector chain
   that requires a host to exist (no external smart-home dependency, no `home-assistant.env`, no SSH tunnel).

---

## Profiles: Multi-Agent Hosts (added 2026-08-23)

A host may run several independent hermes agents. Upstream hermes supports this natively
("profiles"): **a profile is a `HERMES_HOME` directory** — its own `config.yaml`, `.env`,
SOUL.md, memories, sessions, skills, cron, and gateway state. Two processes must never
share one profile (both auto-write memory; state compounds into garbage). The upstream
NixOS module is single-instance (`services.hermes-agent` only), so core generates the
per-profile wiring itself.

### Shape

**Single code path decision (pass-3 review):** core renders **all** hermes gateways —
default and named — through its own generator in `modules/agent.nix`. The upstream
`services.hermes-agent` module is not used for units (it is single-instance and Tier-2
best-effort upstream); core re-implements only what it needs from it: settings→config.yaml
render + merge, env-file merging into `.env`, `documents`/`hermesHomeFiles` install,
`.managed` marker, hardening defaults. One generator means zero hardening drift between
the default profile and named profiles across upstream bumps.

The **zero-arg profile is the default agent**: same options surface as specced elsewhere
(stateDir `/var/lib/hermes`, workspace `/var/lib/hermes/workspace`, injector defaults).
Named profiles are additive:

```nix
hermes.profiles.<name> = {
  enable        = true;    # default true
  settings      = {};      # merged over core hermes settings defaults for THIS profile
  environment   = {};      # non-secret env vars (store-safe)
  environmentFiles = [];   # secret env files — pattern: /var/lib/hermes/credentials/<name>.env
  documents     = {};      # workspace files (installed to this profile's workspace)
  hermesHomeFiles = {};    # HERMES_HOME files (SOUL.md etc.)
  extraPackages = [];
  extraArgs     = [];
  port          = null;    # required iff this profile serves an HTTP-inbound platform;
                           # eval-time uniqueness assertion across profiles
  workspaceRepo = null;    # optional per-profile clone-or-pull (same unit template as
                           # modules/workspace.nix); null → Nix-installed files only
};
```

Profile names must match `[a-zA-Z0-9_-]+` (no leading dash) — they become systemd unit
fragments (`hermes-<name>-gateway.service`) and path components; assert at eval time.

Layout per named profile `<p>` (default profile unchanged):

```
/var/lib/hermes/profiles/<p>/.hermes/     # HERMES_HOME — config.yaml rendered here
/var/lib/hermes/profiles/<p>/workspace/   # terminal.cwd / workingDirectory
```

### What core renders per profile

1. A systemd gateway unit `hermes-<name>-gateway.service` from the SAME generator as the
   default profile (identical hardening, watchdog, drain-timeout defaults), running as
   `workspaceUser`.
2. An exec wrapper exporting `HOME=<stateDir>/profiles/<p>`,
   `HERMES_HOME=.../.hermes`, `HERMES_PROFILE=<name>`, `HERMES_MANAGED=true`.
3. `config.yaml` from Nix settings (core defaults deep-merged with the profile's
   `settings`) at activation — the one-rebuild property holds **per profile**.
4. Directory scaffolding via tmpfiles/activation (0700, owned by `workspaceUser`).
5. Per-profile `restartTriggers`: a rebuild restarts only units whose config/docs changed.
6. The datom memory-plugin symlink into EVERY enabled profile's `HERMES_HOME/plugins/`
   (replaces the hardcoded `preStart` symlink in the reference config). Memory provider settings come from
   the merged defaults; hosts give each profile distinct bank/store identifiers via
   `hermes.profiles.<name>.settings.memory` — never share a memory bank across profiles.

Managed-mode blocking applies everywhere: `HERMES_MANAGED=true` + `.managed` marker per
profile home, so CLI mutation is blocked on every profile.

Identity mechanism note: the *default* profile keeps the host-layer pattern (identity
symlinks SOUL/USER → cloned workspace repo, per the OUT table). `hermesHomeFiles` is the
direct-install alternative available to any profile — including default — when the host
wants Nix-owned identity files instead of symlinks.

Trust boundary (explicit): isolation between profiles is **process/crash-domain level
only**. All profiles run as the same `workspaceUser` and can read every profile's
credential files under `/var/lib/hermes/credentials/`. Per-profile OS users for true
secret isolation are out of scope (hosts can add them via `extraModules` if needed).

Shared platform services: every profile inherits the injector provider/delegation
defaults and shares the ONE mcp-injector/bifrost pair over localhost HTTP — that is the
intent. Duplicate bot tokens across profiles are refused by upstream (keep that behavior).
searxng gating detaches `SEARXNG_URL` for **all** profiles, not just default.

Fresh-profile auth bootstrap: `environmentFiles` covers API keys; OAuth-style provider
state (`auth.json`) seeds on first interactive run per profile (or hosts pre-seed via
`hermesHomeFiles`). Documented in `docs/hermes-wiring.md`.

### Gateway topology

- **Default: one process per profile.** Process-level isolation — separate crash domains,
  separate memory footprints, restart one agent without touching others (see trust-boundary
  note above for what this does NOT isolate). Each profile needs its own platform bot
  tokens; an HTTP-inbound platform on a named profile requires that profile's `port`.
- **Opt-in multiplexing:** setting `gateway.multiplex_profiles = true` on the *default*
  profile makes its gateway serve every profile in one process. HTTP-inbound platforms
  then live ONLY on the default profile, reached via `/p/<name>/…` prefixes; per-token
  platforms (Telegram/Discord/…) still need per-profile tokens; session keys namespace as
  `agent:<profile>:…`; the multiplexer process also executes every served profile's cron
  jobs. Expose it as `hermes.multiplex = true` (renders the flag + suppresses secondary
  gateway units; activation installs still run); default off.

### Provenance & prior art

Design validated against a large production multi-agent deployment, which runs 7 named agents
this way: typed `profiles.<name>` submodule, per-profile exec wrappers + gateway units,
per-profile activation installs, `restartTriggers` on each unit, and an admin-doctor fleet
check that also detects skill-name collisions across agents' skill dirs (worth porting as
a flake check). Its lessons folded in here; that deployment's anti-patterns (2,400-line monolith,
string-concatenated YAML instead of attrset merge, inline secrets) are what this spec's
composition rules forbid.

---

## Credentials Convention (`modules/creds.nix`)

Standard layout only — provisioning stays manual/per-host.

```
/var/lib/<service>/credentials/
├── hermes.env           # provider keys, tokens (environmentFiles for systemd)
├── <name>.env           # per-profile hermes secrets (environmentFiles for
│                        #   hermes-<name>-gateway) — only for enabled profiles
├── home-assistant.env   # only if ha MCP enabled
├── cloudflare.env       # acme dnsProvider
└── buzz-bridge.env      # only if buzz-bridge enabled (host-layer today)
```

- tmpfiles creates dirs with correct owner/mode (`0750`/`0600`).
- systemd units reference via `environmentFiles`, never inline.
- Core ships the tmpfiles + env-file *pattern*; hosts drop in the actual files.

---

## Downstream Host Example

```nix
# host/flake.nix — lives INSIDE the persona repo (e.g. myhost), cloned to the host.
{
  inputs = {
    agent-core = { url = "git+ssh://forge@forge.example.com/repl/agent-core.git"; };
    # Core-only hosts stop here — no nixpkgs input, ride agent-core's pin.
    # The reference host additionally keeps its host-side inputs for now:
    #   workshop   = { url = "github:noblepayne/workshop"; inputs.nixpkgs.follows = "nixpkgs"; };
    #   buzz-flake = { url = "github:noblepayne/buzz-flake"; inputs.nixpkgs.follows = "nixpkgs"; };
    #   nixpkgs    = agent-core.inputs.nixpkgs;   # same rev as the core's pin
  };

  outputs = { self, agent-core, ... }:
    nixosConfigurations.myhost = agent-core.lib.mkAgentHost {
      hostName = "myhost";
      adminKeys = [ "ssh-ed25519 ..." ];
      workspaceRepo = "https://forge.example.com/repl/myhost-workspace.git";
      extraModules = [ ./host.nix ];   # infra base, services — anything host-shaped
    };
}
```

New host = ~20 lines + a persona repo. System + hermes both come from one pinned core.
Even during migration, the reference host's extra inputs point at the **same pinned nixpkgs** as the core.

---

## Migration Path (Reference Host)

0. **First deployment (podcast-infra host, pre-migration):** existing NixOS box adopts
   `agent-core` via `mkAgentHost` — injector + bifrost on (defaults), one hermes profile,
   persona repo seeded with a minimal SOUL/AGENTS.md and the thin host flake. This is the
   bootstrap proving ground; expect first-contact friction here, not during migration.
1. Build `agent-core` repo with the module set above. (The heavy lifts already exist in
   the reference host as `common/*.nix` + `hermes.nix` — this is a move-and-parameterize job.)
2. The reference host's flake becomes the thin host flake: `mkAgentHost` + `host.nix`
   (VPN/mesh, vhost, personal user, infra base, city timers, TTS voice, host-only integrations,
   firewall-sanity check, `buzz-flake` + `workshop` host inputs). **Delete the microvm configuration.**
3. `common/configuration.nix` dissolves: generic halves → core `base.nix`, reference-host halves → `host.nix`.
4. Verify: `nix flake check --no-build` + a real `nixos-rebuild switch` on the reference host as the test rig.
5. The reference host keeps working the whole time — the migration is *extraction*, not rewrite.

Security hygiene during migration (from pass 1): pull `hermes.nix`'s embedded secrets
(webhook secret, `HERMES_CALLBACK_SECRET`, `GROQ_API_KEY` at `hermes.nix:163,214,270`) into
`/var/lib/hermes/credentials/hermes.env` while the file is under the scalpel. Optional for
the host, mandatory for core (core is secret-clean by construction).

---

## Out of Scope (now)

- Secret provisioning (age/sops/vault) — manual per-host, layout only in core.
- Skills extraction — 56 skills stay in the persona repos.
- camofox/miniflux/buzz-* as core modules — only searxng joins core; rest follow if a
  second host actually needs them.
- Hermes product expertise — stays in the `hermes-docs` skill. Core `docs/hermes-wiring.md`
  only covers *host-side* wiring.

---

## Audit Log

### Pass 1 — 2026-08-16 (REPL, against source)

**Claims verified against actual files.** Corrections folded into the sections above.

| # | Finding | Severity | Action |
|---|---|---|---|
| 1 | **Embedded secrets across the reference deployment.** Several provider keys and platform secrets sat inline in service configs (webhook secret, callback secret, provider API key, search secret, integration keys). | High | Core must be secret-clean **by construction** — enforce with a CI check grepping core sources for known secret shapes. Host layer may keep whatever it likes, but migration should pull these toward env files. |
| 2 | `common/searxng.nix` is more generic than assumed (engine list is opinionated but works as defaults) — but its secret blocks reuse. | Medium | Parameterize secret + port; engines as defaults. |
| 3 | Workspace module must also symlink `flake.nix → /etc/nixos/flake.nix` (that's how `git push → rebuild` bootstraps today, `configuration.nix:205`). | Info | Now specified in the moves table. |
| 4 | `hermes.nix` splits cleanly: compression/session_reset/display/gateway-watchdog/hardening/extraPackages/datom-symlink are generic (→ agent.nix defaults). TTS voice, identity symlinks, buzz env, all timers except memory-snapshot/reflection templates are host. | Info | Reflected in moves table. |
| 5 | camofox/miniflux/buzz-* confirmed host-layer (internal domains, embedded creds) — correctly deferred, not just assumed. | Info | — |

**Open items for pass 2 (implementation review):**
- Exact `base.nix` split: which of `configuration.nix`'s 295 lines are truly generic vs
  the reference host. Candidate generic: zram, nix settings/substituters, journald, firewall base,
  user scaffolding, common packages, acme defaults, sudo. Candidate host: hostname, vhost,
  VPN/mesh, personal users, host-specific pollers, checks.
- `agent.nix` defaults `timezone` + `display.tool_progress` generically (host overrides).
- webhook platform: core ships the pattern; `port` and `secret` are host options.

### Pass 2 — 2026-08-16 (independent audit subagent, vs source)

| # | Finding | Severity | Resolution |
|---|---|---|---|
| 1 | `checks`/firewall-sanity lives in `flake.nix:78`, not `configuration.nix`; its hardcoded ports contradict "webhook port is host option". | HIGH | OUT table now lists it as host-layer, ports derived from `networking.firewall`. |
| 2 | "delegation chain per-host" fabricated — `hermes.nix:87-90` is fully generic. | MED | Moved to agent.nix defaults. |
| 3 | Injector not cleanly generic: HA/searxng servers pointed at an external host, `environmentFile` hardcodes `home-assistant.env` (boot fails without it), thunder chain needs SSH tunnel. | HIGH | Host-coupled bits are gated/conditional; core registers nothing host-dependent by default. Contract guarantee 5. |
| 4 | datom service enable unassigned (`flake.nix:119`). | HIGH | Folded into agent.nix row. |
| 5 | buzz-flake input sits in the core "inputs" row while spec defers buzz — contradiction. | MED | buzz-flake moved to host layer (+ host nixpkgs input for its `follows`). |
| 6 | sudo NOPASSWD for hermes unassigned (`configuration.nix:95`) — agent is crippled without it. | HIGH | base.nix provisions sudo for `workspaceUser`, parameterized. |
| 7 | The microvm configuration unassigned. | MED | Decided: delete. `common/microvm.nix` already dead. |
| 8 | Host-layer inputs (workshop, buzz-flake) violate "only agent-core" versioning — migration breaks as written. | BLOCKER | Versioning section amended: host-side inputs allowed w/ host nixpkgs input; core + hosts point at the same pinned rev. |
| 9 | `mkForce`-as-default defeats override guarantee. | MED | Guarantee 2 reworded: documented mkForce exceptions; hosts override those specific knobs with mkForce. |
| 10 | Workspace clone has no update path (clone-once); flake symlink authorship unspecified. | MED | Workspace unit clones-or-pulls; host flake lives in the persona repo, stated in moves + contract. |
| 11 | searxng opt-in leaves dangling refs (`SEARXNG_URL` env, injector searxng server). | MED | Gating also detaches dependents; listed in searxng row. |
| 12 | creds omit `buzz-bridge.env`; `workspaceDir` listed in both rows. | INFO | Both fixed; `workspaceDir` default owned by agent.nix, host overrides. |

### Pass 3 — 2026-08-23 (multi-profile investigation + pin decision)

Investigated hermes multi-profile support (upstream docs), the upstream NixOS module
surface, and a production multi-agent deployment as prior art. Findings folded into
"Profiles: Multi-Agent Hosts" and the Versioning section:

| # | Finding | Severity | Resolution |
|---|---|---|---|
| 1 | Upstream profiles = separate `HERMES_HOME` dirs; one gateway process per profile with own tokens; multiplexing gateway is opt-in (`gateway.multiplex_profiles`) with `/p/<name>/` prefixes and per-profile credential isolation. | INFO | Topology section written around these semantics. |
| 2 | Upstream NixOS module is single-instance — no profile/instance parameter on `services.hermes-agent`. | HIGH | Core generates per-profile units/wrappers/config itself (agent.nix owns it). |
| 3 | The prior-art deployment proves the pattern (7 agents): typed profile submodule, exec wrappers exporting HERMES_HOME/HERMES_PROFILE/HERMES_MANAGED, per-profile gateway units + restartTriggers, activation installs, skill-collision fleet check. | INFO | Adopted as prior art; anti-patterns called out and forbidden by composition rules. |
| 4 | Two processes on one profile corrupt memory state (upstream warning). | HIGH | Layout guarantees one unit ↔ one HERMES_HOME; managed marker per profile. |
| 5 | The reference host pins hermes-agent main @ Aug 4 rev; latest release is v0.20.5 (`v2026.8.19`, Aug 21); upstream flake is Tier-2 best-effort. | MED | Decision: pin release tags in core, bump deliberately. |
| 6 | The prior-art deployment's audited-sudo wrapper (`hermes-sudo`) and admin-doctor checks are host-layer wins worth documenting. | INFO → docs | Note for `docs/hermes-wiring.md`; skill-collision check as a candidate flake check. |

### Pass-3 review — 2026-08-23 (spec review subagent; findings folded)

| # | Finding | Severity | Resolution |
|---|---|---|---|
| 1 | Stale status header/dates vs pass 3. | MED | Header now reads passes 1–3 complete with 2026-08-23 amendment date. |
| 2 | Guarantee 1 didn't cover named profiles. | MED | Reworded: every rendered config.yaml, default and named. |
| 3 | Creds layout omitted per-profile env files. | MED | Added `<name>.env` row. |
| 4 | "Hard isolation" overstated same-user profiles. | MED | Trust-boundary paragraph added; per-profile OS users out of scope. |
| 5 | Two code paths (upstream module for default, hand-rolled for named) invite hardening drift across upstream bumps. | HIGH | **Decision: single generator in `modules/agent.nix` renders ALL gateways**; upstream module not used for units. |
| 6 | Pinned tag unverified against multiplex/profile features. | HIGH | Verified: `v2026.8.19` ships multi-profile-gateways docs (`multiplex_profiles`) in-repo. Build-time sanity check still worthwhile on first eval. |
| 7 | Named-profile HTTP-inbound port allocation undecided. | MED | Optional `port` option + eval-time uniqueness assertion. |
| 8 | Datom plugin symlink hardcoded to default HERMES_HOME in the reference config; named profiles would silently lack memory provider. | BLOCKER | Rendered into every enabled profile's activation (see Profiles §6); per-profile memory identifiers via `settings.memory`. |
| 9 | Named-profile workspaces had no content source beyond `documents`. | HIGH | Optional `workspaceRepo` per profile (clone-or-pull, same unit template as workspace.nix); null → Nix-installed files only. |
| 10 | Injector/bifrost sharing across profiles unstated; searxng detach scope unclear. | MED | Explicit statements added to Profiles section. |
| 11 | Cron ownership under multiplexing implicit. | INFO | Multiplexer executes served profiles' cron jobs — stated. |
| 12 | Profile-name validation missing (unit fragments/path components). | INFO | Eval-time `[a-zA-Z0-9_-]+` assertion specified. |
| 13 | auth.json bootstrap for fresh profiles unspecified. | INFO | First interactive run or pre-seed via hermesHomeFiles; documented in wiring doc. |
| 14 | SOUL mechanism ambiguity (symlink vs hermesHomeFiles). | INFO | Identity-mechanism note added. |
