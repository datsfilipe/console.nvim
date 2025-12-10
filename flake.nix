{
  description = "Neovim/Lua Development Environment";
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
  in {
    devShells.${system}.default =
      let
        wrappedNvim =
          pkgs.writeShellScriptBin "nvim" ''
            exec ${pkgs.neovim}/bin/nvim --clean -u init.lua "$@"
          '';
      in
      pkgs.mkShell {
        packages = [
          pkgs.lua-language-server
          pkgs.stylua
          pkgs.codespell
          wrappedNvim
        ];
      };
  };
}
