# The shell stack builds in on NixOS (stack.yaml: nix.shell-file).
#
# Stack can generate this itself from nix.packages, and this is that
# expression (src/Stack/Nix.hs) with one difference: it says
# `stdenv.hostPlatform.isLinux` where stack's says `stdenv.isLinux`, which
# nixpkgs has deprecated, so every `stack exec` printed a deprecation
# warning.  The same file as the backend's, with contrib's inputs.
#
# `ghc` is the compiler stack's resolver asks for; stack supplies both.
{ ghc, ghcVersion ? null }:
with (import <nixpkgs> { });
let
  # cairo and pango are what the cairo and pango Haskell packages bind, for
  # the decorations and prompts contrib draws itself; libxkbcommon and zlib
  # are the backend's, built here as a project package.
  #
  # The second group is what cairo's, pango's and glib's .pc files list under
  # Requires.private and nixpkgs does not propagate.  Cabal 3.12 asks
  # pkg-config for `--libs --static`, which resolves those too, and the first
  # missing one -- sysprof-capture-4, then xdmcp -- failed configuring the
  # cairo and glib bindings on NixOS.  The set is the minimal one that
  # resolves every module statically against the pinned nixpkgs' x86_64-linux
  # outputs (glib-2.0, gobject-2.0, cairo, pango, pangocairo, xkbcommon,
  # zlib); libxau is added alongside libxdmcp because xcb requires both and
  # only one happened to be propagated.
  #
  # The rest is what stack always adds.
  inputs = [
    cairo pango libxkbcommon zlib
    libsysprof-capture pcre2 util-linux libselinux libsepol
    libxdmcp libxau fribidi libthai libdatrie
    pkg-config ghc git gcc gmp cacert
  ];
in
runCommand "xmonad-contrib-river-stack-shell" {
  # glibcLocales, so GHC can set a locale.
  buildInputs = lib.optional stdenv.hostPlatform.isLinux glibcLocales ++ inputs;
  STACK_PLATFORM_VARIANT = "nix";
  STACK_IN_NIX_SHELL = 1;
  # Template Haskell still needs the libraries on the loader path.
  LD_LIBRARY_PATH = lib.makeLibraryPath inputs;
  STACK_IN_NIX_EXTRA_ARGS = lib.concatMap (pkg: [
    "--extra-lib-dirs=${lib.getLib pkg}/lib"
    "--extra-include-dirs=${lib.getDev pkg}/include"
  ]) inputs;
  # Unicode output from base works whether or not the system has en_US.UTF-8.
  LANG = "C.UTF-8";
} ""
