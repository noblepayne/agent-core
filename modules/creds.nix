# Credential directory convention. Layout only — provisioning is manual
# per-host (spec: Credentials Convention).
_: {
  config,
  lib,
  ...
}: let
  cfg = config.agent-core;
  inherit (lib) mkOption types;
in {
  options.agent-core.credsDir = mkOption {
    type = types.str;
    default = "${cfg.stateDir}/credentials";
    defaultText = lib.literalExpression "\${config.agent-core.stateDir}/credentials";
    description = "Directory holding <service>.env secret files referenced via environmentFiles.";
  };

  config = {
    systemd.tmpfiles.rules = [
      "d ${cfg.credsDir} 0750 ${cfg.workspaceUser} ${cfg.workspaceUser} -"
    ];
  };
}
