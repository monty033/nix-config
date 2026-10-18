{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.extra-services.caddy-proxy;

  caddyWithPlugins = pkgs.caddy.withPlugins {
    plugins = [
      "github.com/caddy-dns/cloudflare@v0.2.2"
      "github.com/mholt/caddy-l4@v0.0.0-20251201210923-0c96591f5650"
    ];
    hash = "sha256-ClDGyhaHoS8z6Ur40mmYuFPXw1unbkKnpdaR8KPYY+0=";
  };

  cfTls = ''
    tls {
      dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
  '';

  # Generate config based on protocol type
  mkConfig = { protocol, upstream, pathRewrite, extraRoutes }:
    let
      mkRoute = rewrite: ''
        route {
          @rewrite path ${rewrite}*
          redir @rewrite ${rewrite} permanent
          reverse_proxy ${upstream}
        }
      '';
      mkHttp = rewrite:
        if rewrite != null && rewrite != "" then ''
          ${mkRoute rewrite}
        '' else ''
          reverse_proxy ${upstream}
        '';
      mkHttps = rewrite:
        if rewrite != null && rewrite != "" then ''
          ${mkRoute rewrite}
        '' else ''
          reverse_proxy ${upstream} {
            transport http {
              tls
              tls_insecure_skip_verify
            }
          }
        '';
      proxyConfig =
        if protocol == "http" then mkHttp pathRewrite
        else if protocol == "https" then mkHttps pathRewrite
        else throw "Protocol ${protocol} should be handled in layer4, not virtualHosts";
    in ''
      ${cfTls}
      ${if extraRoutes == "" then proxyConfig else ''
        route {
          ${extraRoutes}
          ${proxyConfig}
        }
      ''}
    '';

  # Generate layer4 config for SNI-based services
  mkLayer4SniConfig = domain: { protocol, upstream }: ''
    @${builtins.replaceStrings ["."] ["_"] domain} tls sni ${domain}
    route @${builtins.replaceStrings ["."] ["_"] domain} {
      proxy ${upstream}
    }
  '';

  # Filter HTTP/HTTPS services for virtualHosts
  httpServices = filterAttrs (n: v: v.protocol == "http" || v.protocol == "https") cfg.services;

  # Check if we need layer4
  hasSniServices = cfg.layer4SniServices != {} || cfg.sshUpstream != null;
in
{
  options.extra-services.caddy-proxy = {
    enable = mkEnableOption "Caddy reverse proxy with Cloudflare and L4 plugins";

    cloudflareTokenFile = mkOption {
      type = types.path;
      default = "/var/lib/caddy/cloudflare.env";
      description = "Path to file containing CLOUDFLARE_API_TOKEN=your_token";
    };

    services = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          protocol = mkOption {
            type = types.enum [ "http" "https" ];
            description = "Protocol type for the service";
          };
          upstream = mkOption {
            type = types.str;
            description = "Upstream server address (e.g., host.internal:8080)";
          };
          pathRewrite = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Optional URL prefix to 301-redirect traffic to. When set, requests
              to the bare hostname are permanently redirected to the given
              target, and all other requests are proxied normally.
            '';
          };
          extraRoutes = mkOption {
            type = types.lines;
            default = "";
            description = ''
              Optional Caddy route directives executed before the normal proxy
              inside an ordered route block. TLS remains at site scope.
            '';
          };
        };
      });
      default = {};
      description = "HTTP/HTTPS services to proxy";
      example = literalExpression ''
        {
          "service1.example.com" = { 
            protocol = "https"; 
            upstream = "host1.internal:443"; 
          };
          "service2.example.com" = { 
            protocol = "http"; 
            upstream = "host2.internal:3001"; 
          };
        }
      '';
    };

    layer4SniServices = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          protocol = mkOption {
            type = types.enum [ "tcp" "udp" ];
            description = "Protocol type for the layer4 service";
          };
          upstream = mkOption {
            type = types.str;
            description = "Upstream server address (e.g., host.internal:22)";
          };
        };
      });
      default = {};
      description = "TCP/UDP services accessible via SNI on port 443";
      example = literalExpression ''
        {
          "ssh.example.com" = { 
            protocol = "tcp"; 
            upstream = "host1.internal:22"; 
          };
        }
      '';
    };

    sshUpstream = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "If set, proxy all SSH connections on port 443 to this upstream (e.g. 192.168.86.120:22)";
    };

    extraGlobalConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra configuration to add to Caddy's global config";
    };
  };

  config = mkIf cfg.enable {
    services.caddy = {
      enable = true;
      package = caddyWithPlugins;
      environmentFile = cfg.cloudflareTokenFile;
      
      globalConfig = ''
        ${optionalString hasSniServices ''
          # When using layer4, Caddy's HTTPS needs to listen on alternate port
          https_port 8443

          layer4 {
            :443 {
              ${optionalString (cfg.sshUpstream != null) ''
              @ssh ssh
              route @ssh {
                proxy ${cfg.sshUpstream}
              }
              ''}
              ${concatStringsSep "\n          " (mapAttrsToList mkLayer4SniConfig cfg.layer4SniServices)}

              # Pass all non-matching traffic to Caddy's HTTPS server
              route {
                proxy localhost:8443
              }
            }
          }
        ''}
        ${cfg.extraGlobalConfig}
      '';
      
      virtualHosts = mapAttrs (domain: config: {
        extraConfig = mkConfig { inherit (config) protocol upstream pathRewrite extraRoutes; };
      }) httpServices;
    };

    networking.firewall.allowedTCPPorts = [ 80 443 ];

    systemd.services.caddy.preStart = ''
      if [ ! -f ${cfg.cloudflareTokenFile} ]; then
        echo "Warning: ${cfg.cloudflareTokenFile} not found!"
        echo "Create it with: echo 'CLOUDFLARE_API_TOKEN=your_token' > ${cfg.cloudflareTokenFile}"
      fi
    '';
  };
}
