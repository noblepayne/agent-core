# Model-serving layer: bifrost gateway (podman) + mcp-injector + core package
# bundle. Defaults are ON (first consumers all run the full stack); each piece
# disables with one line. Host-coupled things exist only behind options that
# default off/empty (spec contract guarantee 5).
{
  mcp-injector,
  workshop,
  mcp-nixos,
  clojure-mcp,
  opencode-mcp,
  opencode,
  ...
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.agent-core;
  chainDefaults = import ../defaults/model-chains.nix {};

  # Host chains merge OVER defaults (recursiveUpdate: right side wins).
  resolvedChains = lib.recursiveUpdate chainDefaults cfg.injector.chains;

  # Rendered bifrost seed config: providers with env.* key refs (secrets
  # resolve from the container's credentialsFile at runtime, never in-store).
  bifrostConfig = (pkgs.formats.json {}).generate "bifrost-config.json" {
    "$schema" = "https://www.getbifrost.ai/schema";
    providers =
      lib.mapAttrs
      (_: p:
        {
          keys = map (k: {inherit (k) name value models weight;}) p.keys;
        }
        // p.extraConfig)
      cfg.bifrost.providers;
    config_store = {
      enabled = true;
      type = "sqlite";
      # Absolute path, pinned to the durable volume. Relative paths resolve
      # against the container WORKDIR (/app), NOT -app-dir — "./config.db"
      # put the whole config store on ephemeral container FS and every
      # dashboard edit died on container recreate.
      config.path = "/app/data/config.db";
    };
  };
  inherit (lib) mkEnableOption mkIf mkOption types;
in {
  imports = [mcp-injector.nixosModules.default];

  options.agent-core = {
    bifrost = {
      enable = mkEnableOption "bifrost LLM gateway container" // {default = true;};

      providers = mkOption {
        type = types.attrsOf (types.submodule {
          options = {
            keys = mkOption {
              type = types.listOf (types.submodule {
                options = {
                  name = mkOption {
                    type = types.str;
                    description = "Key label inside bifrost.";
                  };
                  value = mkOption {
                    type = types.str;
                    description = ''
                      Key value. Use "env.VARNAME" to resolve the secret from
                      the container environment (credentialsFile) \u2014 keeps
                      secrets out of the rendered config.json and the store.
                    '';
                  };
                  models = mkOption {
                    type = types.listOf types.str;
                    default = [];
                    description = "Restrict key to these models; empty = all.";
                  };
                  weight = mkOption {
                    type = types.float;
                    default = 1.0;
                  };
                };
              });
              default = [];
            };
            extraConfig = mkOption {
              type = types.attrs;
              default = {};
              description = "Provider-level passthru merged into its config block.";
            };
          };
        });
        default = {};
        description = ''
          Upstream providers seeded into the container's config.json at
          activation and bootstrapped into bifrost's sqlite config store.
          Dashboard edits persist in the DB afterward; the seed is the
          bootstrap source, not a continuously-enforced contract. Key values
          support "env.VARNAME" indirection against credentialsFile so
          secrets never enter the nix store.
        '';
      };

      credentialsFile = mkOption {
        type = types.nullOr types.str;
        default = "/var/lib/bifrost/credentials.env";
        description = ''
          Env file passed to the container; holds the VARNAME values that
          config.json env.* references resolve against. Created (empty) by
          tmpfiles if absent.
        '';
      };
    };

    injector = {
      enable = mkEnableOption "mcp-injector shim service" // {default = true;};

      port = mkOption {
        type = types.port;
        default = 8089;
      };

      bind = mkOption {
        type = types.str;
        default = "127.0.0.1";
      };

      llmUrl = mkOption {
        type = types.str;
        default = "http://127.0.0.1:8080";
        description = "Upstream OpenAI-compatible endpoint (bifrost by default).";
      };

      # {} means core defaults (defaults/model-chains.nix).
      chains = mkOption {
        type = types.attrs;
        default = {};
        description = "Extra/overriding virtual-model chains, merged over defaults.";
      };

      servers = mkOption {
        type = types.attrs;
        default = {};
        description = "EXTRA MCP server definitions, additive only.";
      };

      governance = mkOption {
        type = types.attrs;
        default = {};
        description = "Overrides merged over the core governance defaults.";
      };

      homeAssistant = {
        enable = mkEnableOption "Home Assistant MCP server";
        url = mkOption {
          type = types.str;
          default = "";
        };
        tokenFile = mkOption {
          type = types.nullOr types.path;
          default = null;
        };
      };

      opencode = {
        enable = mkEnableOption "OpenCode v2 MCP bridge";
        url = mkOption {
          type = types.str;
          default = "";
        };
        passwordFile = mkOption {
          type = types.nullOr types.path;
          default = null;
        };
      };
    };
  };

  options.agent-core.pkgs = {
    mcp-nixos = mkOption {type = types.package;};
    clojure-mcp = mkOption {type = types.package;};
    opencode-mcp = mkOption {type = types.package;};
    opencode = mkOption {type = types.package;};
    opencode2 = mkOption {
      type = types.package;
      description = "opencode2 beta line (linux-x64 only upstream).";
    };
    workshop-client = mkOption {type = types.package;};
  };

  config = lib.mkMerge [
    {
      # Core package bundle.
      agent-core.pkgs = {
        mcp-nixos = mcp-nixos.packages."${pkgs.stdenv.hostPlatform.system}".default;
        clojure-mcp = clojure-mcp.packages."${pkgs.stdenv.hostPlatform.system}".default;
        opencode-mcp = opencode-mcp.packages."${pkgs.stdenv.hostPlatform.system}".default;
        opencode = opencode.packages."${pkgs.stdenv.hostPlatform.system}".opencode-avx;
        # baseline build: VM guests may lack AVX passthrough
        opencode2 = opencode.packages."${pkgs.stdenv.hostPlatform.system}".opencode2;
        workshop-client =
          workshop.packages."${pkgs.stdenv.hostPlatform.system}".workshop-client
          or workshop.packages."${pkgs.stdenv.hostPlatform.system}".default;
      };

      environment.systemPackages = [cfg.pkgs.opencode];
    }

    (mkIf cfg.bifrost.enable {
      # Declarative provider seeding: rendered config.json (env.* key refs,
      # no secrets in-store) is bind-mounted into the container and
      # bootstraps bifrost's config store at startup.
      systemd.tmpfiles.rules = [
        "d /var/lib/bifrost 0777 root root -"
        "f ${cfg.bifrost.credentialsFile} 0600 root root -"
      ];

      systemd.services.podman-bifrost = {
        restartTriggers = [bifrostConfig];
      };

      virtualisation.podman = {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true;
        autoPrune = {
          enable = true;
          flags = ["--all"];
        };
      };

      virtualisation.oci-containers = {
        backend = "podman";
        containers.bifrost = {
          image = "maximhq/bifrost:latest";
          autoStart = true;
          volumes = [
            "/var/lib/bifrost:/app/data:U"
            "${bifrostConfig}:/app/data/config.json"
          ];
          environmentFiles =
            lib.optional (cfg.bifrost.credentialsFile != null)
            cfg.bifrost.credentialsFile;
          environment = {
            APP_PORT = "8080";
            APP_HOST = "0.0.0.0";
            LOG_LEVEL = "info";
            LOG_STYLE = "json";
          };
          extraOptions = [
            "--network=host"
            "--memory=2048m"
            "--cpus=2"
            "--pids-limit=1024"
          ];
        };
      };

      # Provider API keys reach bifrost via credentials.env (env.* refs in
      # the rendered config) — never inline here.
    })

    (mkIf cfg.injector.enable {
      assertions = [
        {
          assertion = builtins.attrNames resolvedChains != [];
          message = "agent-core.injector.enable with zero model chains is inert; set injector.chains or disable the injector.";
        }
      ];

      services.mcp-injector = {
        enable = true;
        port = cfg.injector.port;
        host = cfg.injector.bind;
        llmUrl = cfg.injector.llmUrl;
        openFirewall = false;
        maxIterations = 50;
        environmentFile =
          if cfg.injector.homeAssistant.enable && cfg.injector.homeAssistant.tokenFile != null
          then toString cfg.injector.homeAssistant.tokenFile
          else if cfg.injector.homeAssistant.enable
          then "${cfg.credsDir}/home-assistant.env"
          else null;

        governance =
          lib.recursiveUpdate {
            mode = "permissive";
            policy.allow = ["clojure-eval"];
            pii = {
              enabled = true;
              mode = "replace";
              trust = "restore";
            };
            passthroughTrust = {
              read = "restore";
              edit = "restore";
              exec = "none";
              write = "restore";
            };
            audit = {
              enabled = true;
              path = "${cfg.stateDir}/mcp-injector-audit.log.ndjson";
            };
            oSeriesCompat = true;
            loopPinning = true;
            pinTemp = 0.1;
            pinEffort = "low";
          }
          cfg.injector.governance;

        mcpServers.servers =
          {
            nixos = {
              cmd = pkgs.lib.getExe cfg.pkgs.mcp-nixos;
              trust = "restore";
            };
            clojure = {
              cmd = "${lib.getExe cfg.pkgs.clojure-mcp} :project-dir / :enable-logging? true";
              trust = "restore";
            };
          }
          // (lib.optionalAttrs cfg.datom.enable {
            datom.url = "http://127.0.0.1:9090/mcp";
            datom.trust = "restore";
          })
          // (lib.optionalAttrs config.services.agent-core.searxng.enable {
            searxng.url = "http://127.0.0.1:${toString config.services.agent-core.searxng.port}/mcp";
          })
          // (lib.optionalAttrs (cfg.injector.homeAssistant.enable && cfg.injector.homeAssistant.url != "") {
            ha = {
              url = cfg.injector.homeAssistant.url;
              headers.Authorization = {
                env = "HA_TOKEN";
                prefix = "Bearer ";
              };
              trust = "restore";
            };
          })
          // (lib.optionalAttrs (cfg.injector.opencode.enable && cfg.injector.opencode.url != "") {
            opencode = {
              cmd = lib.getExe cfg.pkgs.opencode-mcp;
              env =
                {
                  OPENCODE_URL = cfg.injector.opencode.url;
                }
                // (lib.optionalAttrs (cfg.injector.opencode.passwordFile != null) {
                  OPENCODE_PASSWORD_FILE = toString cfg.injector.opencode.passwordFile;
                });
              trust = "restore";
            };
          })
          // cfg.injector.servers;

        mcpServers.llm-gateway = {
          url = cfg.injector.llmUrl;
          virtual-models = resolvedChains;
        };
      };

      # Documented exception: upstream injector module forces HOME/sandbox
      # internally, so these overrides also use mkForce (spec contract
      # guarantee 2). The injector needs workspace access and headroom for
      # JVM threads (TasksMax=100 caused native-thread exhaustion).
      systemd.services.mcp-injector = {
        after = lib.optionals cfg.bifrost.enable ["podman-bifrost.service"];
        wants = lib.optionals cfg.bifrost.enable ["podman-bifrost.service"];
        environment = {
          HOME = lib.mkForce cfg.stateDir;
          JAVA_TOOL_OPTIONS = lib.mkForce "-Duser.home=${cfg.stateDir}";
        };
        serviceConfig = {
          User = lib.mkForce cfg.workspaceUser;
          Group = lib.mkForce cfg.workspaceUser;
          PrivateTmp = lib.mkForce false;
          ProtectHome = lib.mkForce false;
          ProtectSystem = lib.mkForce false;
          TasksMax = lib.mkForce 500;
        };
      };
    })
  ];
}
