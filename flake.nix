{
  description = "Install the standalone hp-rgb-lighting kernel module on NixOS for keyboard backlight";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
  };
  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgbuildLines = lib.strings.splitString "\n" (builtins.readFile ./PKGBUILD);
      versionDefinition = lib.lists.findFirst (
        line: lib.strings.hasPrefix "pkgver=" line
      ) "unknown" pkgbuildLines;
      version = lib.strings.removePrefix "pkgver=" versionDefinition;
      module =
        {
          stdenv,
          lib,
          kernel,
          nix-gitignore,
        }:
        stdenv.mkDerivation (finalAttrs: {
          pname = "hp-rgb-lighting";
          inherit version;
          src = lib.cleanSource (
            nix-gitignore.gitignoreSourcePure [
              ./.gitignore
              "result*"
            ] ./.
          );

          postPatch = ''
            sed -i 's@depmod -a@@g' Makefile
          '';

          nativeBuildInputs = kernel.moduleBuildDependencies;

          makeFlags = [
            "KDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
          ];

          enableParallelBuilding = true;

          installFlags = [ "INSTALL_MOD_PATH=$(out)" ];

          meta = {
            description = "Linux kernel module for HP Laptops (standalone keyboard RGB lighting)";
            homepage = "https://github.com/yunusemreyl/hp-rgb-lighting";
            license = lib.licenses.gpl2;
            maintainers = with lib.maintainers; [ ern775 ];
            platforms = lib.platforms.linux;
          };
        });
    in
    {
      packages.${system} = {
        default = self.packages.${system}.hp-rgb-lighting;
        hp-rgb-lighting = module;
      };

      nixosModules.default = (
        { config, lib, ... }:
        let
          inherit (lib) mkEnableOption mkIf;
          cfg = config.hardware.hp-rgb-lighting;
          callPackage = config.boot.kernelPackages.callPackage;
        in
        {
          options = {
            hardware.hp-rgb-lighting = {
              enable = mkEnableOption "Enable the standalone hp-rgb-lighting kernel module";
            };
          };
          config = mkIf cfg.enable {
            boot.extraModulePackages = [
              (callPackage self.packages.${system}.hp-rgb-lighting { })
            ];
          };
        }
      );
    };
}
