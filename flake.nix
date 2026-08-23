{
  description = "agent-core — reusable hermes agent host platform";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Pinned to release tags, not rolling main (spec: Versioning & Pinning).
    hermes-agent = {
      url = "github:NousResearch/hermes-agent/v2026.8.19";
    };

    # Both mirrors of forge repos (forge remains primary upstream; see
    # HANDOFF "Repo logistics"). Public so downstream consumers can eval.
    mcp-injector.url = "github:noblepayne/mcp-injector";

    datom.url = "github:noblepayne/datom";

    workshop = {
      url = "github:noblepayne/workshop";
    };

    mcp-nixos = {
      url = "github:utensils/mcp-nixos";
    };

    clojure-mcp = {
      url = "github:noblepayne/clojure-mcp/feat/flake";
    };

    opencode = {
      url = "github:noblepayne/opencode-flake";
    };
  };

  outputs = {
    self,
    nixpkgs,
    hermes-agent,
    mcp-injector,
    datom,
    workshop,
    mcp-nixos,
    clojure-mcp,
    opencode,
  }: let
    forSystems = nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux"];

    # Repo-wide convention: modules close over flake inputs at IMPORT time
    # (`import ./modules/x.nix coreInputs` returns a NixOS module). Hosts ride
    # the pin — per-host input swapping happens host-side via follows, not here.
    coreInputs = {
      inherit
        nixpkgs
        self
        hermes-agent
        mcp-injector
        datom
        workshop
        mcp-nixos
        clojure-mcp
        opencode
        ;
    };
  in {
    formatter = forSystems (system: nixpkgs.legacyPackages.${system}.alejandra);

    # Re-exported so downstreams can import modules raw without mkAgentHost.
    # Composite exports (creds/llm/searxng/workspace/agent) pull their own
    # dependencies and are STANDALONE — do not mix composites with `default`
    # (double-importing a module breaks option declaration). To compose by
    # hand, import the raw module paths instead.
    nixosModules = let
      mod = path: import path coreInputs;
      withDeps = deps: path: {imports = deps ++ [(mod path)];};
      baseMod = mod ./modules/base.nix;
      searxngMod = mod ./modules/searxng.nix;
    in {
      base = baseMod;
      creds = withDeps [baseMod] ./modules/creds.nix;
      llm =
        withDeps
        [baseMod searxngMod]
        ./modules/llm.nix;
      searxng = withDeps [baseMod] ./modules/searxng.nix;
      workspace = withDeps [baseMod] ./modules/workspace.nix;
      agent =
        withDeps
        [baseMod searxngMod]
        ./modules/agent.nix;
      default = {
        imports = [
          baseMod
          (mod ./modules/searxng.nix)
          (mod ./modules/llm.nix)
          (mod ./modules/workspace.nix)
          (mod ./modules/creds.nix)
          (mod ./modules/agent.nix)
        ];
      };
    };

    lib = import ./lib.nix coreInputs;

    # Scratch test host: proves the full mkAgentHost path evaluates clean.
    # Kept as a flake check; delete if it ever becomes noise.
    nixosConfigurations.testhost = self.lib.mkAgentHost {
      hostName = "testhost";
      adminKeys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForEvalOnly testhost"];
      workspaceRepo = "https://example.com/persona.git";

      hermes = {
        model = "brain";
        profiles.researcher.settings.model.default = "coder";
      };

      extraModules = [
        ({lib, ...}: {
          fileSystems."/" = {
            device = "/dev/disk/by-label/nixos";
            fsType = "ext4";
          };
          boot.loader.systemd-boot.enable = true;
          boot.loader.efi.canTouchEfiVariables = true;
        })
      ];
    };

    checks.x86_64-linux = let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in rec {
      # Spec pass 1, finding 1: secret-clean by construction, enforced.
      secrets-clean =
        pkgs.runCommand "agent-core-secrets-clean"
        {nativeBuildInputs = [pkgs.gnugrep];}
        ''
          if grep -rInE '(api_key|apiKey|token|secret|password)[[:space:]]*=[[:space:]]*"[A-Za-z0-9_-]{16,}"' \
              --include='*.nix' ${self} | grep -v no-key-required; then
            echo "secret-shaped literals found (see above)" >&2
            exit 1
          fi
          touch $out
        '';

      # Boots the real host composition in QEMU and asserts the activation
      # artifacts exist. Heavyweights stubbed so the build stays reasonable.
      smoke-vm = nixpkgs.lib.nixos.runTest {
        hostPkgs = pkgs;
        imports = [
          {
            name = "agent-core-smoke";
            nodes.machine = {
              imports =
                self.lib.hostModules {
                  hostName = "machine";
                  workspaceRepo = "https://example.invalid/persona.git";
                  hermes.profiles.researcher.enable = true;
                }
                ++ [
                  ({lib, pkgs, ...}: {
                    agent-core.bifrost.enable = false; # no container pulls in VM
                    virtualisation.memorySize = 4096;
                    virtualisation.cores = 2;

                    # Stub the heavyweight package bundle; the wiring under
                    # test is profiles/units/activation, not upstream builds.
                    agent-core.pkgs.opencode = lib.mkForce (pkgs.runCommand "stub-opencode" {} ''
                      mkdir -p $out/bin && touch $out/bin/opencode && chmod +x $out/bin/opencode
                    '');
                  })
                ];
            };

            testScript = ''
              machine.start()
              machine.wait_for_unit("multi-user.target", timeout=900)

              # default profile artifacts from the activation script
              machine.succeed("test -s /var/lib/hermes/.hermes/config.yaml")
              machine.succeed("test -f /var/lib/hermes/.hermes/.managed")
              machine.succeed("test -L /var/lib/hermes/.hermes/plugins/datom")
              machine.succeed("test -d /var/lib/hermes/workspace")

              # named profile layout + rendered config
              machine.succeed("test -s /var/lib/hermes/profiles/researcher/.hermes/config.yaml")
              machine.succeed("test -d /var/lib/hermes/profiles/researcher/workspace")
              machine.succeed("test -f /var/lib/hermes/profiles/researcher/.hermes/.managed")

              # units exist and are wired for boot
              machine.succeed("systemctl is-enabled hermes-default-gateway")
              machine.succeed("systemctl is-enabled hermes-researcher-gateway")
              machine.succeed("systemctl is-enabled agent-workspace")

              # rendered config is valid YAML and carries core defaults
              machine.succeed(
                  "${pkgs.yq-go}/bin/yq eval-all '.' /var/lib/hermes/.hermes/config.yaml > /dev/null")
              machine.succeed(
                  "grep -q 'provider: custom:mcp-injector' /var/lib/hermes/.hermes/config.yaml")
              machine.succeed(
                  "grep -q 'cwd: /var/lib/hermes/profiles/researcher/workspace' /var/lib/hermes/profiles/researcher/.hermes/config.yaml")

              # env file is locked down
              machine.succeed(
                  "test \"$(stat -c '%a' /var/lib/hermes/.hermes/.env)\" = 600")
            '';
          }
        ];
      };
    };
  };
}
