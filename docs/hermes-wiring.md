# Hermes Wiring — Host-Side Guide

**Audience: whoever owns/operates a box built on agent-core** — downstream host
owners, future maintainers, and agents administering their own host. This is
the ops manual for the glue agent-core renders.

How agent-core wires a hermes host together, and the operational lessons baked
into its defaults. This covers **host-side glue only** — hermes product behavior lives in
upstream docs and the `hermes-docs` skill.

---

## The Request Path

```
hermes gateway                    provider = custom:mcp-injector
        │
        ▼
mcp-injector shim  :8089          virtual-model chains, governance, PII redaction,
        │                         MCP tool passthrough, audit log
        ▼
bifrost gateway    :8080          one OpenAI-compatible endpoint normalizing every
        │                         upstream provider + auth
        ▼
zen · nvidia NIM · openrouter · groq · …
```

Three things follow from this shape:

1. **`brain`, `coder`, `subagent` etc. are not models — they're injector chains**:
   ordered failover lists tried top-down on error/rate-limit, with per-chain
   cooldowns. Defined in `defaults/model-chains.nix`; hosts override via
   `injector.chains`.
2. **The hermes model list derives from chain names.** agent-core renders
   `providers.mcp-injector.models` from `builtins.attrNames` of the resolved
   chains — add a chain, it appears in `/model`. No second place to update.
3. **Delegation pins to `subagent`** by default (`delegation.model = "subagent"`),
   so spawned child agents ride the speed/free tier while root uses `brain`.

## The One-Rebuild Property

Every rendered `config.yaml` — default profile and named profiles — comes from Nix
at activation. Each profile's home carries:

- `HERMES_MANAGED=true` in the gateway environment, and
- a `.managed` marker file in `$HERMES_HOME`

Together these block `hermes setup`, `hermes config set`, and `gateway install`
with an error naming the rebuild command. **Never hand-edit YAML.** If a setting
is wrong, change the Nix that renders it.

Skills are the exception: installed skills write to `$HERMES_HOME/skills/` at
runtime, are NOT managed by NixOS, and survive rebuilds.

## Profiles

Default topology is **one process per profile**: separate crash domains, restart
one agent without touching others, each with its own bot tokens (upstream refuses
duplicate `(platform, token)` pairs across profiles — keep it that way).

`hermes.multiplex = true` flips to a single multiplexing gateway owned by the
default profile. Use only when process count genuinely hurts (containers, many
low-traffic profiles). Under multiplexing, HTTP-inbound platforms live ONLY on the
default profile behind `/p/<name>/…` prefixes.

Trust boundary: profiles isolate processes, not secrets — all profiles share
`workspaceUser` and can read every `credentials/*.env`.

Fresh profile auth: `environmentFiles` covers API keys; OAuth-style state
(`auth.json`) seeds on first interactive run per profile, or pre-seed via
`hermesHomeFiles`.

## Why the Defaults Look Weird (scar tissue)

Each of these was a real production failures. Don't "clean them up."

- **systemd watchdog instead of the internal loop watchdog**
  (`gateway.loop_watchdog = false`, `gateway.systemd_watchdog_seconds = 300`,
  unit `Type=notify`). The internal watchdog had untunable ~120s patience and
  false-positived on a memory-constrained host — exit-75 restart loops during
  terminal spill-redaction. systemd gives declarative patience and faulthandler
  dumps on SIGABRT.

- **`TimeoutStopSec = 240` with `restart_drain_timeout = 150`.** Drain needs ≥ its
  own value plus ~30s grace; systemd's old 90s default SIGKILLed mid-drain, which
  amputated in-flight sessions on every rebuild.

- **Injector `TasksMax = 500`.** The JVM hits NixOS's default 100-task limit and
  dies with "Unable to create native thread."

- **Relaxed hardening on agent units** (`NoNewPrivileges/ProtectHome/ProtectSystem/
  PrivateTmp` off). Agents need passwordless sudo for rebuilds and shared `/tmp`
  for uploads/exports. base.nix grants sudo NOPASSWD to `workspaceUser` only —
  wheel stays password-required unless the host changes it.

- **Documented `mkForce` exceptions.** Core defaults otherwise compose as plain
  values. Exactly two places force internally:
  1. the injector sandbox block (`HOME`, `JAVA_TOOL_OPTIONS`, `TasksMax`,
     `ProtectSystem`, …) — upstream injector module owns those knobs;
  2. hermes service hardening, which core renders itself, so hosts overriding
     those specific unit attrs also use `mkForce`.

- **`dependencyGroups`: valid extras only.** Groups come from hermes-agent's
  pyproject.toml at the pinned tag. `"cli"` does not exist at v2026.8.19 — the
  package override fails validation at eval, which is the correct failure mode.
  Check the tag's pyproject before adding groups.

## Secrets

Layout only — provisioning is manual (age/sops/vault deliberately out of scope):

```
/var/lib/hermes/credentials/
├── hermes.env           # default profile: TELEGRAM_BOT_TOKEN, GROQ_API_KEY, …
├── <name>.env           # one per named profile using secrets
├── home-assistant.env   # only if injector.homeAssistant enabled
└── cloudflare.env       # acme dnsProvider (host-layer)
```

Units reference files via `environmentFiles`, never inline values — anything in a
Nix expression lands world-readable in `/nix/store`.

Upstream LLM provider keys live in **bifrost**, not hermes: hermes talks to
`mcp-injector` with `api_key = "no-key-required"`. Set provider keys through
bifrost's data dir/dashboard on first run. A provider-wide 401 through bifrost is
a key problem, not a model problem.

## Chain Maintenance

Models rot fast: delistings, promo endings, rate-limit drift. **API model lists
lie** — probe tool-calling live before trusting any model. A persona
skill `update-llm-models` encodes the full methodology (fetch catalog from both
bifrost endpoints → spot-check current chains → probe candidates → rebuild chains
tier-first with paid backstops). Point it at this repo's `defaults/model-chains.nix`.

Chain health after deploy:

```bash
curl -s http://localhost:8089/api/v1/llm/cooldowns | jq .
```

All traffic landing on the paid backstop = chain needs refresh.

## Common Tasks

| Task | Where |
|---|---|
| Change a hermes setting | profile `settings` in host flake → rebuild |
| Add a virtual model chain | `defaults/model-chains.nix` or `injector.chains` override |
| Add an MCP server (host-coupled) | `injector.servers` (additive) |
| Add a named agent | `hermes.profiles.<name>` |
| Bump platform versions | `nix flake lock` inside agent-core (tag bump first); hosts ride the pin |

After delegation changes: reset running sessions (`/reset`) — settings read at
session start.

## Rebuild

```bash
nix flake check --no-build                # fast validity
sudo nixos-rebuild switch                 # system AND all hermes configs, atomically
journalctl -u hermes-default-gateway -f   # watch a profile
```

One rebuild renders everything. That's the contract.
