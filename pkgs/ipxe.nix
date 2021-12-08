{ src, stdenv, lib, fetchFromGitHub, perl, cdrkit, syslinux, xz, openssl
, gnu-efi, mtools, cdrtools, xorriso, embedScript ? null
, additionalTargets ? { } }:

let
  targets = additionalTargets // lib.optionalAttrs stdenv.isx86_64 {
    "bin-x86_64-efi/ipxe.efi" = null;
    "bin-x86_64-efi/ipxe.efirom" = null;
    "bin-x86_64-efi/ipxe.usb" = "ipxe-efi.usb";
  } // {
    "bin/ipxe.dsk" = null;
    "bin/ipxe.usb" = null;
    "bin/ipxe.iso" = null;
    "bin/ipxe.lkrn" = null;
    "bin/undionly.kpxe" = null;
  };

in stdenv.mkDerivation rec {
  pname = "ipxe";
  version = "586b723733904c0825844582dd19a44c71bc972b";

  nativeBuildInputs =
    [ perl cdrkit cdrtools syslinux xz openssl gnu-efi mtools xorriso ];

  inherit src;

  # not possible due to assembler code
  hardeningDisable = [ "pic" "stackprotector" ];

  NIX_CFLAGS_COMPILE = "-Wno-error";

  makeFlags = [
    "ECHO_E_BIN_ECHO=echo"
    "ECHO_E_BIN_ECHO_E=echo" # No /bin/echo here.
    "LDLINUX_C32=${syslinux}/share/syslinux/ldlinux.c32"
  ] ++ lib.optional (embedScript != null) "EMBEDDED_IMAGE=${embedScript}";

  enabledOptions = [
    "PING_CMD"
    "IMAGE_TRUST_CMD"
    "CONSOLE_SERIAL"
    "CPUID_SETTINGS"
    "DOWNLOAD_PROTO_HTTP"
    "DOWNLOAD_PROTO_HTTPS"
  ];

  configurePhase = ''
    runHook preConfigure
    for opt in $enabledOptions; do echo "#define $opt" >> src/config/general.h; done
    substituteInPlace src/util/genfsimg --replace /usr/lib/syslinux ${syslinux}/share/syslinux
    substituteInPlace src/Makefile.housekeeping --replace /bin/echo echo
    runHook postConfigure
  '';

  preBuild = "cd src";

  buildFlags = lib.attrNames targets;

  installPhase = ''
    mkdir -p $out
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (from: to:
      if to == null then "cp -v ${from} $out" else "cp -v ${from} $out/${to}")
      targets)}

    # Some PXE constellations especially with dnsmasq are looking for the file with .0 ending
    # let's provide it as a symlink to be compatible in this case.
    ln -s undionly.kpxe $out/undionly.kpxe.0
  '';

  enableParallelBuilding = true;

  meta = with lib; {
    description = "Network boot firmware";
    homepage = "https://ipxe.org/";
    license = licenses.gpl2;
    maintainers = with maintainers; [ ehmry ];
    platforms = [ "x86_64-linux" "i686-linux" ];
  };
}