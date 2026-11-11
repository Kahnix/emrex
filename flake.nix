{
  description = "emrex: Emacs windows as Rex panes";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Build against whichever Emacs package set the caller uses, so the
      # .elc matches their Emacs.
      mkEmrex =
        epkgs:
        epkgs.trivialBuild {
          pname = "emrex";
          version = "0.1.0";
          src = self;
        };
    in
    {
      lib.mkEmrex = mkEmrex;

      # Adds `emacsPackages.emrex` (and every emacsPackagesFor set's).
      overlays.default = final: prev: {
        emacsPackagesFor =
          emacs: (prev.emacsPackagesFor emacs).overrideScope (efinal: _: { emrex = mkEmrex efinal; });
      };

      packages = forAll (pkgs: {
        default = mkEmrex pkgs.emacsPackages;
      });

      checks = forAll (pkgs: {
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      });
    };
}
