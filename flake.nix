{
  description = "Claude Desktop (Chat + Code) for NixOS — unofficial repack of Anthropic's Linux .deb";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      unfreeNames = [
        "claude-desktop"
        "claude-desktop-unwrapped"
      ];
      forAllSystems =
        f:
        lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) unfreeNames;
            }
          )
        );
    in
    {
      overlays.default = final: prev: {
        claude-desktop = final.callPackage ./package.nix { };
      };

      packages = forAllSystems (pkgs: rec {
        claude-desktop = pkgs.callPackage ./package.nix { };
        claude-desktop-cowork = claude-desktop.override { withCowork = true; };
        claude-desktop-unwrapped = claude-desktop.unwrapped;
        default = claude-desktop;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.default;
          meta.description = "Run Claude Desktop";
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            asar
            curl
            dpkg
            gnupg
            nixfmt
          ];
        };
      });

      # nixfmt-rfc-style is now an alias of nixfmt (the RFC 166 formatter)
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);

      checks = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          package = self.packages.${system}.default;
          formatting = pkgs.runCommand "check-formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${./flake.nix} ${./package.nix}
            touch $out
          '';
        }
      );
    };
}
