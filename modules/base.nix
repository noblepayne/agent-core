# Generic NixOS foundation shared by every agent host.
# Host-shaped bits (hostname, vhosts, VPN mesh, personal users) stay host-side.
{nixpkgs, ...}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.agent-core;
  inherit (lib) mkOption types;
in {
  options.agent-core = {
    workspaceUser = mkOption {
      type = types.str;
      default = "hermes";
      description = "OS user the agent(s) run as. Owns all state dirs.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/hermes";
      description = "Root state directory. Default profile HERMES_HOME is ``<stateDir>/.hermes``.";
    };

    adminKeys = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "SSH public keys with admin access (root + workspaceUser).";
    };

    cacheSubstituters = mkOption {
      type = types.listOf types.str;
      default = ["https://cache.nixos.org"];
      description = "Hosts with a private binary cache add it here (plus its key below).";
    };

    cacheTrustedKeys = mkOption {
      type = types.listOf types.str;
      default = ["cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="];
    };

    # Shared option tree: defined here so agent.nix and llm.nix avoid
    # cross-module option-ordering problems.
    datom.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Run the datom memory service and wire its plugin into every hermes profile.";
    };
  };

  config = {
    zramSwap = {
      enable = true;
      algorithm = "zstd";
      memoryPercent = 40;
    };

    nix = {
      enable = true;
      settings = {
        experimental-features = ["nix-command" "flakes"];
        trusted-users = ["root" cfg.workspaceUser];
        substituters = cfg.cacheSubstituters;
        trusted-substituters = cfg.cacheSubstituters;
        trusted-public-keys = cfg.cacheTrustedKeys;
      };
    };

    services.journald.extraConfig = ''
      Storage=persistent
      SystemMaxUse=500M
      MaxFileSec=7day
    '';

    networking.firewall.enable = true;

    users.users.${cfg.workspaceUser} = {
      isSystemUser = true;
      group = cfg.workspaceUser;
      home = cfg.stateDir;
      createHome = true;
      useDefaultShell = true;
      extraGroups = ["wheel"];
      openssh.authorizedKeys.keys = cfg.adminKeys;
    };
    users.groups.${cfg.workspaceUser} = {};

    users.users.root.openssh.authorizedKeys.keys = cfg.adminKeys;

    # The agent needs passwordless sudo for rebuilds and system administration.
    security.sudo.extraRules = [
      {
        users = [cfg.workspaceUser];
        commands = [
          {
            command = "ALL";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    documentation.nixos.enable = false;
    documentation.man.enable = false;
    documentation.info.enable = false;

    environment.systemPackages = with pkgs; [
      bat
      btop
      curl
      dig
      dust
      duf
      eza
      fd
      ffmpeg
      file
      findutils
      fzf
      git
      gnutar
      gzip
      htop
      httpie
      iotop
      iftop
      jq
      less
      lshw
      lsof
      neovim
      netcat-gnu
      nmap
      parted
      pciutils
      ripgrep
      rsync
      smartmontools
      socat
      strace
      sysstat
      tcpdump
      tmux
      tree
      traceroute
      usbutils
      vim
      wget
      wireshark-cli
      yq-go
      zellij
    ];
  };
}
