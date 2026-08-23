# Opt-in SearXNG module. Default OFF.
# Secret is parameterized via an env file — never a literal (spec pass 1, #2).
# Gating detaches dependents: when off, no SEARXNG_URL reaches hermes and no
# searxng MCP server registers on the injector (llm.nix / agent.nix read the
# enable flag).
_: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.agent-core.searxng;
  inherit (lib) mkEnableOption mkIf mkOption types;

  engine = name: weight: {
    inherit name weight;
    disabled = false;
    categories = ["general"];
  };
in {
  options.services.agent-core.searxng = {
    enable = mkEnableOption "SearXNG metasearch";

    port = mkOption {
      type = types.port;
      default = 8888;
    };

    bind = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind address. Open up only behind a tailnet/firewall boundary.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
    };

    secretFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        File containing SEARXNG_SECRET=<hex>. Required for stable URL
        encryption across restarts; without it SearXNG generates an
        ephemeral secret each start.
      '';
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [cfg.port];

    services.searx = {
      enable = true;
      package = pkgs.searxng;
      redisCreateLocally = true;
      configureUwsgi = true;

      uwsgiConfig = {
        http = "${cfg.bind}:${toString cfg.port}";
        disable-logging = false;
        workers = 4;
        threads = 4;
      };

      settings = {
        use_default_settings = true;

        server = {
          port = cfg.port;
          bind_address = cfg.bind;
          limiter = false;
          image_proxy = true;
        };

        search = {
          formats = ["html" "json" "rss"];
          safe_search = 0;
          autocomplete = "google";
        };

        ui = {
          default_theme = "simple";
          infinite_scroll = false;
          query_in_title = true;
          default_locale = "en";
          results_on_new_tab = false;
        };

        general = {
          debug = false;
          instance_name = "SearXNG";
        };

        # Each engine needs disabled=false AND categories=["general"] to be
        # selected for default queries. Opinionated-but-working defaults.
        engines =
          [
            (engine "google" 1.5)
            (engine "bing" 1.3)
            (engine "brave" 1.2)
            (engine "duckduckgo" 1.0)
            (engine "qwant" 1.0)
            (engine "mojeek" 0.8)
            (engine "startpage" 0.8)
            (engine "mwmbl" 0.9)
            (engine "yandex" 0.7)
            (engine "fynd" 0.6)
            (engine "searchmysite" 0.5)
          ]
          ++ [
            (engine "github" 1.2)
            (engine "stackoverflow" 1.1)
            (engine "hackernews" 1.0)
            (engine "gitlab" 0.8)
            (engine "mdn" 1.0)
            (engine "docker hub" 0.7)
            (engine "pypi" 0.7)
          ]
          ++ [
            (engine "huggingface" 1.0)
            (engine "huggingface datasets" 0.8)
            (engine "huggingface spaces" 0.8)
          ]
          ++ [
            (engine "arxiv" 1.2)
            (engine "semantic scholar" 1.0)
            (engine "google scholar" 1.0)
            (engine "openalex" 0.8)
            (engine "crossref" 0.7)
            (engine "pubmed" 0.7)
          ]
          ++ [
            (engine "google news" 1.0)
            (engine "bing news" 0.8)
            (engine "brave.news" 0.8)
            (engine "reuters" 0.9)
          ]
          ++ [
            (engine "wikipedia" 1.2)
            (engine "nixos wiki" 1.0)
          ]
          ++ [
            (engine "alpine linux packages" 0.5)
            (engine "crates.io" 0.5)
            (engine "npm" 0.5)
          ];
      };

      limiterSettings = {
        real_ip = {
          x_for = 1;
          ipv4_prefix = 32;
          ipv6_prefix = 56;
        };
        botdetection = {
          ip_limit = {
            filter_link_local = true;
            link_token = true;
          };
        };
      };
    };

    systemd.services.uwsgi = {
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "5s";
      };
      environmentFile = lib.mkIf (cfg.secretFile != null) cfg.secretFile;
    };
  };
}
