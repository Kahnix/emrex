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

      # Only the package source, so the build doesn't carry assets/demo.gif.
      emrexSrc = builtins.path {
        path = ./.;
        name = "emrex-source";
        filter =
          path: type:
          (type == "directory" && builtins.baseNameOf path != ".git")
          || builtins.baseNameOf path == "emrex.el";
      };

      # Build against whichever Emacs package set the caller uses, so the
      # .elc matches their Emacs.
      mkEmrex =
        epkgs:
        epkgs.trivialBuild {
          pname = "emrex";
          version = "0.1.0";
          src = emrexSrc;
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
        tests = pkgs.runCommand "emrex-tests" { nativeBuildInputs = [ pkgs.emacs ]; } ''
          emacs -Q --batch -L ${emrexSrc} -l ${./emrex-test.el} \
            -f ert-run-tests-batch-and-exit
          touch $out
        '';
      });
    };
}
