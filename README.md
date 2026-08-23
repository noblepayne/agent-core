# agent-core

A minimal, inheritable NixOS flake that turns any NixOS box into a **hermes
agent host** with a ~20-line flake. One `nixos-rebuild switch` renders both the
system configuration AND every hermes agent's `config.yaml`.

```
one flake update  ─▶  agent-core's lock bumps hermes/injector/datom/nixpkgs
one rebuild       ─▶  systemd units + hermes config.yaml, together
new host          ─▶  thin flake inside your persona repo + mkAgentHost
```

## Quickstart

Your host flake lives **inside your persona repo** (cloned to the box by the
workspace unit — `git push → rebuild`):

```nix
# flake.nix in your persona repo
{
  inputs.agent-core.url = "github:<you>/agent-core";  # or your forge

  outputs = { self, agent-core }: {
    nixosConfigurations.myhost = agent-core.lib.mkAgentHost {
      hostName      = "myhost";
      adminKeys     = [ "ssh-ed25519 AAAA..." ];
      workspaceRepo = "https://git.example.com/you/myhost-workspace.git";
    };
  };
}
```

Then drop provider secrets into `/var/lib/hermes/credentials/hermes.env`
(`OPENROUTER_API_KEY=…` or whatever your setup needs) and rebuild.

Defaults give you: hardened NixOS base, one hermes gateway with datom memory,
the mcp-injector model-chain shim, and the bifrost LLM gateway container. Every
piece disables with one line. See `docs/agent-core-spec.md` for the full option
contract (`mkAgentHost`) and `docs/hermes-wiring.md` for how it all fits
together and why the defaults look weird.

## Multiple agents on one host

```nix
hermes = {
  profiles.researcher.settings.model.default = "coder";
  # each profile = own HERMES_HOME, sessions, memory, gateway unit:
  #   /var/lib/hermes/profiles/researcher/{.hermes,workspace}
  #   hermes-researcher-gateway.service
};
```

## Development

- `nix flake check --no-build` — fast validity + secret-shape scan
- `nix build .#checks.x86_64-linux.smoke-vm -L` — boots the real composition in
  QEMU and asserts activation artifacts (slow first time)
- `docs/agent-core-spec.md` is canonical; `HANDOFF.md` orients fresh agents
