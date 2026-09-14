{
  description = "GuiAssert-Synthesia - Synthesia talking-head plugin for GuiAssert";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/devops-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, system, ... }:
        {
          devShells.default = pkgs.mkShell {
            # Synthesia is a commercial HTTP API, so this plugin has
            # no Python / no model weights / no GPU toolchain — just a
            # pure-Nim HTTP client plus the supporting bits the tests
            # use to synthesise audio + verify rendered MP4s.
            packages = with pkgs; [
              nim
              nimble
              just
              git
              curl
              ffmpeg-full
              openssl
              cacert
            ];
            shellHook = ''
              # Make Nim's httpclient pick up the system CA bundle so
              # TLS to api.synthesia.io works without user setup.
              export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              echo "GuiAssert-Synthesia dev shell ready."
              echo "  nim:      $(nim --version | head -1)"
              echo "  ffmpeg:   $(ffmpeg -version | head -1)"
              echo "  openssl:  $(openssl version)"
              echo
              if [ -z "$SYNTHESIA_API_KEY" ]; then
                echo "NOTE: SYNTHESIA_API_KEY is not set."
                echo "      Pure tests + mock-server tests work without it."
                echo "      The -d:synthesiaLive test requires it (set via: export SYNTHESIA_API_KEY=...)."
                echo "      Synthesia API access typically requires the Creator+ plan ($89/mo)."
              else
                echo "  SYNTHESIA_API_KEY: set (length=$${#SYNTHESIA_API_KEY})"
              fi
              echo
              echo "Next steps:"
              echo "  just test        # pure + mock-server tests"
              echo "  just test-live   # live render against api.synthesia.io (requires SYNTHESIA_API_KEY)"
            '';
          };
        };
    };
}
