# Hermes agent platform: ONE gateway generator renders the default profile
# and every named profile (spec pass-3 review decision). The upstream
# services.hermes-agent module is NOT used for units — core owns rendering,
# activation installs, managed markers, and hardening so parity across
# upstream bumps is structural, not manual.
{
  hermes-agent,
  datom,
  ...
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  coreCfg = config.agent-core;
  cfg = coreCfg.hermes;
  inherit (lib) mkEnableOption mkIf mkOption types mkDefault;

  chainDefaults = import ../defaults/model-chains.nix {};
  resolvedChains = lib.recursiveUpdate chainDefaults coreCfg.injector.chains;

  hermesPkg = hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
    extraDependencyGroups = cfg.dependencyGroups;
    extraPythonPackages = cfg.extraPythonPackages;
  };

  profileType = types.submodule ({config, ...}: {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
      };

      settings = mkOption {
        type = types.attrs;
        default = {};
        description = "Merged over the core hermes settings defaults for this profile.";
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Non-secret env vars exported to the gateway (store-safe).";
      };

      environmentFiles = mkOption {
        type = types.listOf (types.either types.str types.path);
        default = [];
        description = "Secret env files concatenated into HERMES_HOME/.env (0600).";
      };

      documents = mkOption {
        type = types.attrsOf (types.either types.str types.path);
        default = {};
        description = "Files installed into this profile's workspace.";
      };

      hermesHomeFiles = mkOption {
        type = types.attrsOf (types.either types.str types.path);
        default = {};
        description = "Files installed into this profile's HERMES_HOME.";
      };

      extraPackages = mkOption {
        type = types.listOf types.package;
        default = [];
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
      };

      port = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "Required iff this profile serves an HTTP-inbound platform.";
      };

      workspaceRepo = mkOption {
        type = types.str;
        default = "";
        description = "Optional per-profile clone-or-pull repo for its workspace.";
      };
    };
  });

  # Upstream profile model: named profiles live under the DEFAULT profile's
  # home in ``profiles/<name>/`` and that directory IS the profile's
  # HERMES_HOME (config.yaml/.env/SOUL.md at its top level). Upstream
  # discovery (`profiles_to_serve`, `hermes profile list`, the dashboard,
  # kanban) enumerates ``<default_home>/profiles/*`` — anything else is
  # invisible to those surfaces (spec pass-3: "one gateway per profile",
  # this file's "Named profiles nest" predecessor put them under
  # ``stateDir/profiles/<name>/.hermes`` instead, which upstream cannot see).
  # The default profile home is ``<stateDir>/.hermes`` and it IS baseDir.
  profileBaseDir = name:
    if name == "default"
    then "${coreCfg.stateDir}/.hermes"
    else "${coreCfg.stateDir}/.hermes/profiles/${name}";

  settingsDefaults = name: let
    workspace =
      if name == "default"
      then "${coreCfg.stateDir}/workspace"
      else "${profileBaseDir name}/workspace";
  in {
    _config_version = 33;

    providers."mcp-injector" = {
      api = "http://127.0.0.1:${toString coreCfg.injector.port}/v1";
      transport = "chat_completions";
      api_key = "no-key-required";
      discover_models = false;
      models = builtins.attrNames resolvedChains;
    };

    model = {
      provider = "custom:mcp-injector";
      default = "brain";
      api_mode = "chat_completions";
    };

    terminal = {
      backend = "local";
      cwd = workspace;
      timeout = 180;
    };

    toolsets = ["all"];

    memory = {
      memory_enabled = true;
      user_profile_enabled = true;
      memory_char_limit = 2200;
      user_char_limit = 1375;
      write_approval = false;
      provider = "datom";
    };

    agent = {
      max_turns = 200;
      verbose = false;
      # Grace period for active turns on SIGTERM; TimeoutStopSec reserves more.
      restart_drain_timeout = 150;
    };

    delegation = {
      model = "subagent";
      provider = "custom:mcp-injector";
    };

    auxiliary = {
      compression.enabled = true;
      vision = {};
      web_extract = {};
    };

    compression = {
      enabled = true;
      threshold = 0.70;
      target_ratio = 0.20;
      protect_last_n = 20;
      protect_first_n = 3;
    };

    display = {
      compact = false;
      skin = "default";
      tool_progress = "new";
      runtime_footer = {
        enabled = true;
        fields = ["model" "context_pct"];
      };
      file_mutation_verifier = true;
      timestamps = true;
    };

    file_read_max_chars = 100000;
    tool_output = {
      max_bytes = 50000;
      max_lines = 2000;
      max_line_length = 2000;
    };
    context_file_max_chars = 20000;

    timezone = "UTC";

    session_reset = {
      mode = "idle";
      idle_minutes = 2880;
    };

    # systemd watchdog replaces the internal loop watchdog (production LEARNINGS).
    gateway = {
      loop_watchdog = false;
      systemd_watchdog_seconds = 300;
    };

    mcp_servers.nixos = {
      command = lib.getExe coreCfg.pkgs.mcp-nixos;
      args = [];
      enabled = true;
      timeout = 120;
      tools = {};
    };
  };

  timerType = types.submodule {
    options = {
      description = mkOption {
        type = types.str;
        default = "";
      };
      schedule = mkOption {
        type = types.str;
        description = "systemd OnCalendar expression.";
      };
      script = mkOption {
        type = types.either types.path types.str;
        description = "Executable path or inline dash script body.";
      };
      persistent = mkOption {
        type = types.bool;
        default = true;
      };
    };
  };

  # Renders one enabled profile into { activation, service, configYaml }.
  mkProfile = name: pcfg: let
    isDefault = name == "default";
    baseDir = profileBaseDir name;
    # The profile directory IS the HERMES_HOME (upstream profile model):
    # config.yaml/.env/SOUL.md/... live at its top level.
    hermesHome = baseDir;
    # Default profile keeps the legacy workspace at stateDir/workspace;
    # named profiles get workspace/ inside their home (upstream bootstraps
    # a workspace dir in every profile home).
    workspace =
      if isDefault
      then "${coreCfg.stateDir}/workspace"
      else "${baseDir}/workspace";

    muxFlag = lib.optionalAttrs (isDefault && cfg.multiplex) {
      gateway.multiplex_profiles = true;
    };

    renderedSettings =
      lib.recursiveUpdate (lib.recursiveUpdate (settingsDefaults name) muxFlag)
      pcfg.settings;

    configYaml = (pkgs.formats.yaml {}).generate "hermes-${name}-config" renderedSettings;

    envStatic =
      pkgs.writeText "hermes-${name}-env-static" (lib.concatStringsSep "\n"
        (lib.mapAttrsToList (k: v: "${k}=${v}") pcfg.environment));

    wrapper = pkgs.writeShellScript "hermes-${name}-gateway-exec" ''
      export HOME="${coreCfg.stateDir}"
      export HERMES_HOME="${hermesHome}"
      export HERMES_MANAGED="true"
      exec ${hermesPkg}/bin/hermes gateway run ${lib.escapeShellArgs pcfg.extraArgs} "$@"
    '';

    activation = ''
      # ── profile: ${name} ──
      install -d -m 0750 -o ${coreCfg.workspaceUser} -g ${coreCfg.workspaceUser} ${baseDir}
      install -d -m 0700 -o ${coreCfg.workspaceUser} -g ${coreCfg.workspaceUser} ${hermesHome}
      # Upstream profile home bootstrap dirs (profiles.py _PROFILE_DIRS) plus
      # agent-core specific ones. `home/` is the subprocess HOME used by
      # terminal.home_mode: profile; `workspace` is created separately below.
      for d in cron logs memories plugins sessions skills state plans skins home; do
        install -d -m 0700 -o ${coreCfg.workspaceUser} -g ${coreCfg.workspaceUser} "${hermesHome}/$d"
      done
      install -d -m 0750 -o ${coreCfg.workspaceUser} -g ${coreCfg.workspaceUser} ${workspace}

      install -m 0600 -o ${coreCfg.workspaceUser} -g ${coreCfg.workspaceUser} \
        ${configYaml} ${hermesHome}/config.yaml

      : > "${hermesHome}/.env"
      ${lib.concatStringsSep "\n" (map (f: ''cat "${toString f}" >> "${hermesHome}/.env"'') pcfg.environmentFiles)}
      ${lib.optionalString (pcfg.environment != {}) ''
        cat ${envStatic} >> "${hermesHome}/.env"
      ''}
      chown ${coreCfg.workspaceUser}:${coreCfg.workspaceUser} ${hermesHome}/.env
      chmod 0600 ${hermesHome}/.env

      touch ${hermesHome}/.managed
      chown ${coreCfg.workspaceUser}:${coreCfg.workspaceUser} ${hermesHome}/.managed
      chmod 0644 ${hermesHome}/.managed

      ${lib.optionalString coreCfg.datom.enable ''
        rm -f ${hermesHome}/plugins/datom
        ln -sf ${config.services.datom.hermesPlugin}/plugins/memory/datom ${hermesHome}/plugins/datom
      ''}

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList
        (
          rel: value:
            if lib.isString value && !lib.isPath value
            then ''
              install -D -m 0644 -o ${coreCfg.workspaceUser} -g ${coreCfg.workspaceUser} \
                ${(pkgs.writeText "hermes-${name}-${baseNameOf rel}" value)} "${hermesHome}/${rel}"
            ''
            else ''
              install -D -m 0644 -o ${coreCfg.workspaceUser} -g ${coreCfg.workspaceUser} \
                ${value} "${hermesHome}/${rel}"
            ''
        )
        pcfg.hermesHomeFiles)}

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList
        (
          rel: value:
            if lib.isString value && !lib.isPath value
            then ''
              install -D -m 0644 -o ${coreCfg.workspaceUser} -g ${coreCfg.workspaceUser} \
                ${(pkgs.writeText "hermes-${name}-ws-${baseNameOf rel}" value)} "${workspace}/${rel}"
            ''
            else ''
              install -D -m 0644 -o ${coreCfg.workspaceUser} -g ${coreCfg.workspaceUser} \
                ${value} "${workspace}/${rel}"
            ''
        )
        pcfg.documents)}
    '';

    service = {
      description = "Hermes Agent gateway (${name})";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      restartTriggers = [configYaml wrapper envStatic];
      path = pcfg.extraPackages;
      serviceConfig = let
        hardeningOff = {
          NoNewPrivileges = false;
          PrivateTmp = false;
          ProtectHome = false;
          ProtectSystem = false;
        };
      in
        {
          Type = "notify";
          NotifyAccess = "main";
          User = coreCfg.workspaceUser;
          Group = coreCfg.workspaceUser;
          WorkingDirectory = workspace;
          ExecStart = wrapper;
          Restart = "always";
          RestartSec = 5;
          WatchdogSec = "300";
          TimeoutStopSec = 240;
          OOMScoreAdjust = -100;
          UMask = "0077";
        }
        // hardeningOff;
    };
  in {inherit activation service configYaml;};

  enabledProfiles = lib.filterAttrs (_: p: p.enable) cfg.profiles;

  generated = lib.mapAttrs mkProfile enabledProfiles;

  # One gateway process per profile (default). Under multiplexing the
  # default gateway serves every profile — named profiles must not run
  # their own `gateway run` (upstream hard-errors when a multiplexer is
  # live); keep their config renders + activation, drop their units.
  gatewayUnits =
    lib.filterAttrs (n: _: !cfg.multiplex || n == "default") generated;

  namedPorts =
    lib.filter (p: p != null) (lib.mapAttrsToList (_: p: p.port) enabledProfiles);

  timerList =
    lib.mapAttrsToList (name: t: let
      exec =
        if lib.isPath t.script || (lib.isString t.script && lib.hasPrefix "/" t.script)
        then t.script
        else pkgs.writers.writeDash "agent-${name}-script" t.script;
      workspace =
        if name == "default"
        then "${coreCfg.stateDir}/workspace"
        else "${profileBaseDir name}/workspace";
    in {
      inherit name;
      service = {
        description =
          if t.description != ""
          then t.description
          else "agent-core timer (${name})";
        after = ["network-online.target"];
        wants = ["network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          User = coreCfg.workspaceUser;
          Group = coreCfg.workspaceUser;
          WorkingDirectory = workspace;
          ExecStart = "${exec}";
        };
      };
      timer = {
        description = "agent-core timer (${name})";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = t.schedule;
          Persistent = t.persistent;
          Unit = "agent-${name}.service";
        };
      };
    })
    cfg.timers;
in {
  imports = [datom.nixosModules.default];

  options.agent-core.hermes = {
    dependencyGroups = mkOption {
      type = types.listOf types.str;
      default = ["voice" "messaging"];
      description = "pyproject optional extras baked into the sealed hermes venv.";
    };

    extraPythonPackages = mkOption {
      type = types.listOf types.package;
      default = [];
      description = "Entry-point plugins added to PYTHONPATH (built with python312Packages).";
    };

    addToSystemPackages = mkOption {
      type = types.bool;
      default = true;
      description = "Put the hermes CLI on PATH and export HERMES_HOME of the default profile system-wide.";
    };

    multiplex = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Serve every profile through the DEFAULT profile's gateway (upstream
        gateway.multiplex_profiles). Suppresses secondary gateway units;
        activation installs still run. Default off — one process per profile
        is the isolation-preserving default.
      '';
    };

    profiles = mkOption {
      type = types.attrsOf profileType;
      default = {};
      description = ''
        Named hermes agents. "default" is pre-seeded by mkAgentHost; extra
        names become hermes-<name>-gateway units with their home under
        <stateDir>/.hermes/profiles/<name> (upstream discovery root).
      '';
    };

    timers = mkOption {
      type = types.attrsOf timerType;
      default = {};
      description = ''
        Timer templates running in the DEFAULT profile's workspace as
        workspaceUser (memory-snapshot / reflection pattern). Host timers with
        other shapes belong in extraModules.
      '';
    };
  };

  config = {
    services.datom.enable = mkIf coreCfg.datom.enable true;

    assertions = [
      {
        # Upstream profile-name contract (hermes_cli/profiles.py
        # _PROFILE_ID_RE + reserved names): lowercase start, [a-z0-9_-],
        # max 64 chars. Names out of this shape are silently invisible to
        # upstream resolution (`-p`, multiplex enumeration, dashboard).
        # `default` is allowed — it is upstream's built-in root-profile alias
        # (reserved only against creating a NEW profile with that name).
        assertion = let
          bad =
            lib.filter
            (
              n:
                (builtins.match "[a-z0-9][a-z0-9_-]{0,63}" n)
                == null
                || (builtins.elem n ["hermes" "test" "tmp" "root" "sudo"])
            )
            (builtins.attrNames enabledProfiles);
        in
          bad == [];
        message = "agent-core.hermes.profiles: names must match [a-z0-9][a-z0-9_-]{0,63} and not be reserved (hermes/test/tmp/root/sudo) — upstream resolves these as unit/path components: ${toString (builtins.attrNames enabledProfiles)}";
      }
      {
        assertion = lib.length namedPorts == lib.length (lib.unique namedPorts);
        message = "agent-core.hermes.profiles: duplicate port assignment across profiles.";
      }
      {
        assertion = !cfg.multiplex || !lib.any (p: p.port != null) (lib.removeAttrs enabledProfiles ["default"]);
        message = "multiplex mode: named profiles must not bind ports; HTTP platforms live only on the default profile (/p/<name>/ prefixes).";
      }
    ];

    environment.systemPackages = mkIf cfg.addToSystemPackages [hermesPkg];

    environment.sessionVariables =
      {
        # Native python libs for TTS/ML paths (ported from production configs).
        LD_LIBRARY_PATH = lib.makeLibraryPath [pkgs.zlib pkgs.stdenv.cc.cc];
      }
      // (mkIf cfg.addToSystemPackages {
        HERMES_HOME = mkDefault "${profileBaseDir "default"}";
      });
    programs.nix-ld = {
      enable = true;
      libraries = [pkgs.zlib pkgs.stdenv.cc.cc];
    };

    systemd.services =
      (lib.listToAttrs (lib.mapAttrsToList
        (name: g: {
          name = "hermes-${name}-gateway";
          value = g.service;
        })
        gatewayUnits))
      // (lib.foldl' (acc: u: acc // u) {}
        (lib.mapAttrsToList
          (
            name: pcfg:
              lib.optionalAttrs (pcfg.enable && pcfg.workspaceRepo != "") {
                "agent-profile-${name}-workspace" = {
                  description = "Clone-or-pull agent workspace (${name})";
                  wantedBy = ["multi-user.target"];
                  after = ["network-online.target"];
                  wants = ["network-online.target"];
                  restartTriggers = [pcfg.workspaceRepo];
                  serviceConfig = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                    Restart = "on-failure";
                    RestartSec = "30s";
                    Environment = "PATH=${lib.makeBinPath [pkgs.coreutils pkgs.git]}";
                    ExecStart = pkgs.writers.writeDash "agent-${name}-workspace-exec" ''
                      workspace="${profileBaseDir name}/workspace"
                      mkdir -p "$workspace"
                      if [ ! -d "$workspace/.git" ]; then
                        git clone ${pcfg.workspaceRepo} "$workspace"
                      else
                        git -C "$workspace" pull --ff-only
                      fi
                      chown -R ${coreCfg.workspaceUser}:${coreCfg.workspaceUser} \
                        "${profileBaseDir name}/workspace"
                    '';
                  };
                };
              }
          )
          cfg.profiles))
      // (lib.listToAttrs (map (t: {
          name = "agent-${t.name}";
          value = t.service;
        })
        timerList));

    systemd.timers = lib.listToAttrs (map (t: {
        name = "agent-${t.name}";
        value = t.timer;
      })
      timerList);

    networking.firewall.allowedTCPPorts =
      lib.filter (p: p != null) namedPorts;

    system.activationScripts.agent-core-profiles = lib.stringAfter ["users"] ''
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (_: g: g.activation) generated)}
    '';
  };
}
