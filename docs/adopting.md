# Adopting an Existing NixOS Box

For pointing a live machine at agent-core without breaking it. Written for the
first real consumer (podcast-infra host) but applies to any box.

## Before you touch anything

1. **Snapshot escape hatch**: confirm you can roll back — `nixos-rebuild` keeps
   previous generations in the boot menu, but know how to get there
   (reboot → choose "Generation N" from systemd-boot).
2. **Note current state**: `hostname`, `system.stateVersion` from
   `/etc/nixos`/current config, existing users, firewall ports, and anything
   listening that matters.

## Step-by-step

### 1. Create the persona repo

A minimal persona repo (this is also the host's flake):

```
myhost-workspace/
├── flake.nix          # mkAgentHost call (see README quickstart)
├── SOUL.md            # agent identity (can start as one paragraph)
├── AGENTS.md          # operating context for the agent
└── scripts/           # empty for now; memory-snapshot lands here later
```

Push it somewhere the box can reach over HTTPS or SSH.

**Bootstrap note:** the workspace unit retries every 30s until the clone
succeeds, so the repo can be private and keys can land after first rebuild —
but the *cleanest* path is getting deploy credentials on the box before step 3.

### 2. Wire the flake inputs

If the box's current config is a flake: add `agent-core` as an input. If it's
legacy `configuration.nix`: create a minimal wrapper flake that imports your
existing config as `extraModules` so nothing is lost on day one:

```nix
agent-core.lib.mkAgentHost {
  hostName = "myhost";
  adminKeys = [ "ssh-ed25519 AAAA..." ];
  workspaceRepo = "https://git.example.com/you/myhost-workspace.git";
  extraModules = [ ./old-configuration.nix ];  # legacy config rides along
};
```

Deal with conflicts incrementally later — do NOT delete old config on day one.

### 3. First rebuild

```bash
sudo nixos-rebuild switch --flake .#myhost
```

Expect: new `hermes` user, activation scaffolding (`/var/lib/hermes/…`),
gateway + injector units enabled. **Watch it:**

```bash
journalctl -u hermes-default-gateway -f
curl -s localhost:8089/health || systemctl status mcp-injector
systemctl status podman-bifrost   # pulls maximhq/bifrost on first start
```

First build may be long if hermes/injector derivations aren't in the binary
cache — hosts that run one add it via `agent-core.cacheSubstituters`.

### 4. Secrets (manual by design)

```bash
sudo install -d -m0750 -o hermes -g hermes /var/lib/hermes/credentials
sudo -e /var/lib/hermes/credentials/hermes.env   # OPENROUTER_API_KEY=…
chmod 600 /var/lib/hermes/credentials/hermes.env
systemctl restart hermes-default-gateway
```

Provider keys for the LLM tier itself belong in **bifrost** (its data dir /
dashboard), not in hermes.env — see docs/hermes-wiring.md.

### 5. Verify the smoke checklist

```bash
test -s /var/lib/hermes/.hermes/config.yaml && echo config ✓
test -f /var/lib/hermes/.hermes/.managed && echo managed ✓
test -L /var/lib/hermes/.hermes/plugins/datom && echo datom-plugin ✓
systemctl is-enabled hermes-default-gateway agent-workspace mcp-injector
hermes chat    # HERMES_HOME is exported system-wide; managed mode is on
```

Then talk to it. Memory writes should produce datom entries; model calls should
land in bifrost's dashboard.

## Known sharp edges

- **stateVersion**: never bump it. If the old config set one, keep theirs.
- **Existing `hermes` user**: if the box already had one from upstream's module,
  agent-core adopts it (same name/group/home). Check `id hermes` after.
- **Port collisions**: injector 8089, bifrost 8080, searxng 8888 are core
  defaults — check `ss -tlnp` before switching if other services live there.
- **Pairing-style platform state** written into config.yaml at runtime can be
  clobbered by rebuilds (full re-render). Prefer declaring platforms in Nix;
  OAuth tokens live in `auth.json`, which is safe.
