{ self, ... }:
{
  flake = {
    homeModules = {
      default = {
        # See https://home-manager-options.extranix.com/ for home-manager
        # options used inside these imported modules.
        imports = [
          ./neovim
          ./git.nix
          ./starship.nix
          ./terminal.nix
        ];
      };
    };
  };
}
