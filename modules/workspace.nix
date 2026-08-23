# Workspace clone-or-pull + /etc/nixos symlink.
# The thin host flake lives INSIDE the persona repo — one repo per host,
# `git push -> rebuild` (spec contract guarantee 3).
_: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.agent-core;
  user = cfg.workspaceUser;
in {
  options.agent-core.workspaceRepo = let
    inherit (lib) mkOption types;
  in
    mkOption {
      type = types.str;
      default = "";
      description = "Git URL of the host persona repo. Empty disables the workspace unit.";
    };

  config = lib.mkIf (cfg.workspaceRepo != "") {
    # Retries until forge credentials land — first-boot chicken-and-egg is
    # handled by failure + retry, not by ordering magic.
    systemd.services.agent-workspace = {
      description = "Clone-or-pull the agent workspace repo";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      restartTriggers = [cfg.workspaceRepo];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "30s";
        Environment = "PATH=${lib.makeBinPath [pkgs.coreutils pkgs.git]}";
        ExecStart = pkgs.writers.writeDash "agent-workspace-exec" ''
          workspace="${cfg.stateDir}/workspace"
          mkdir -p "$workspace"
          if [ ! -d "$workspace/.git" ]; then
            git clone ${cfg.workspaceRepo} "$workspace"
          else
            git -C "$workspace" pull --ff-only
          fi
          chown -R ${user}:${user} "${cfg.stateDir}/workspace"
          mkdir -p /etc/nixos
          ln -sfn "$workspace/flake.nix" /etc/nixos/flake.nix
        '';
      };
    };
  };
}
