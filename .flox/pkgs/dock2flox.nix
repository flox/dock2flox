{ stdenv, lib, makeWrapper, bash, coreutils, gnugrep, gnused, gawk, python3, python3Packages }:

let
  runtimePath = lib.makeBinPath [
    bash
    coreutils
    gnugrep
    gnused
    gawk
    python3
  ];

  pythonWithPyyaml = python3.withPackages (ps: [ ps.pyyaml ]);
in

stdenv.mkDerivation {
  pname = "dock2flox";
  version = "0.1.0";
  src = ../../.;

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/share/dock2flox

    # Copy the tool tree
    cp -r bin lib data $out/share/dock2flox/
    chmod +x $out/share/dock2flox/bin/dock2flox

    # Create wrapper that sets DOCK2FLOX_ROOT and ensures runtime deps on PATH
    makeWrapper $out/share/dock2flox/bin/dock2flox $out/bin/dock2flox \
      --set DOCK2FLOX_ROOT $out/share/dock2flox \
      --prefix PATH : ${runtimePath} \
      --prefix PATH : ${pythonWithPyyaml}/bin

    runHook postInstall
  '';

  meta = {
    description = "Convert Dockerfiles, Compose files, and devcontainer configs to Flox environments";
    license = lib.licenses.asl20;
    mainProgram = "dock2flox";
  };
}
