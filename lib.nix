# mkAgentHost: the downstream contract. See docs/agent-core-spec.md
# ("The Contract: mkAgentHost") for the option set and guarantees.
#
# Takes coreInputs at import time (repo convention). Threads coreInputs via
# specialArgs so the module set can reach flake inputs.
{
  nixpkgs,
  self,
  ...
}: let
  inherit (nixpkgs) lib;
in {
  # Shared by mkAgentHost and the VM smoke test so both exercise identical
  # module composition. Returns a list of NixOS modules.
  hostModules = {
    hostName,
    adminKeys ? [],
    credsDir ? "/var/lib/hermes/credentials",
    workspaceUser ? "hermes",
    workspaceRepo,
    hermes ? {},
    injector ? {},
    services ? {},
    extraModules ? [],
  }:
    [
      self.nixosModules.default
      {
        networking.hostName = hostName;

        agent-core = {
          inherit adminKeys workspaceUser credsDir workspaceRepo;

          # Named host profiles pass through; the default profile folds in
          # convenience args (model/tts), explicit settings always win.
          hermes.profiles =
            builtins.removeAttrs (hermes.profiles or {}) ["default"]
            // {
              "default" =
                (hermes.profiles or {}).default or {}
                // {
                  settings = let
                    convenienceSettings =
                      lib.optionalAttrs (hermes ? model) {
                        model.default = hermes.model;
                      }
                      // lib.optionalAttrs (hermes ? tts) {tts = hermes.tts;};
                    userDefaultSettings =
                      ((hermes.profiles or {}).default or {}).settings or {};
                  in
                    lib.recursiveUpdate convenienceSettings userDefaultSettings;
                };
            };

          injector.chains = injector.chains or {};
          injector.servers = injector.servers or {};
          injector.governance = injector.governance or {};
        };

        services.agent-core.searxng = services.searxng or {};

        agent-core.hermes.timers = hermes.timers or {};
      }
    ]
    ++ extraModules;

  mkAgentHost = args @ {
    hostName,
    system ? "x86_64-linux",
    ...
  }:
    lib.nixosSystem {
      inherit system;
      specialArgs = self.inputs;
      modules = self.lib.hostModules (builtins.removeAttrs args ["system"]);
    };
}
