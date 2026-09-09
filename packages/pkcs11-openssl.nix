# Shared openssl PKCS#11 provider config function.
#
# A source-able function library (writeTextFile — no shebang, not executable).
# Apps `source` it to get:
#
#   openssl_pkcs11_conf <providerLib> <module> <pin> -> path to an openssl conf
{
  pkgs,
  ...
}:
pkgs.writeTextFile {
  name = "pkcs11-openssl";
  text = ''
    openssl_pkcs11_conf() {
      local providerLib="$1" pkcs11Module="$2" pin="$3"
      local conf pinFile
      conf="$(mktemp)"
      pinFile="$(mktemp)"
      printf '%s' "$pin" > "$pinFile"
      cat > "$conf" <<EOF
    openssl_conf = openssl_init

    [openssl_init]
    providers = provider_sect

    [provider_sect]
    default = default_sect
    pkcs11 = pkcs11_sect

    [default_sect]
    activate = 1

    [pkcs11_sect]
    module = $providerLib
    pkcs11-module-path = $pkcs11Module
    pkcs11-module-token-pin = file:$pinFile
    activate = 1
    EOF
      echo "$conf"
    }
  '';
}
