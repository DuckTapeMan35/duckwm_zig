{
  description = "Zig and C client library for duckwm";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      zig = pkgs.zig_0_17;
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          zig
          pkgs.zls_0_17
          pkgs.pkg-config
        ];
        shellHook = ''
          export DUCKWM_SRC=/home/duck/dev/duckwm
        '';
      };

      # libduckwm for C: the libraries, duckwm.h and duckwm.pc. Zig projects
      # use the package directly (zig fetch), not this.
      packages.${system} = {
        libduckwm = pkgs.stdenv.mkDerivation {
          pname = "libduckwm";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ zig.hook ];
          zigBuildFlags = [ "-Doptimize=ReleaseFast" ];
          meta = {
            description = "C client library for duckwm's IPC socket";
            homepage = "https://github.com/DuckTapeMan35/duckwm_zig";
            license = pkgs.lib.licenses.gpl3Plus;
            platforms = pkgs.lib.platforms.linux;
            pkgConfigModules = [ "duckwm" ];
          };
        };
        default = self.packages.${system}.libduckwm;
      };
    };
}
