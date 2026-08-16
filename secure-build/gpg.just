import? '../common.just'
set positional-arguments

[no-cd]
[arg('store_path', short="s", long="store-path")]
[arg('pin_path', short="p", long="pin-path")]
[arg('cert_path', short="c", long="cert-path")]
[arg('pki_dir', short="k", long="pki-dir")]
[arg('gpg_home', short="g", long="gpg-home")]
build_cmd store_path=pkcs11_store pin_path=pkcs11_pin cert_path=sign_cert pki_dir=pki_dir gpg_home=gnupg_home *cmd:
    #!/usr/bin/env bash
    set -euo pipefail
    source <(cat "{{pin_path}}")
    {{ auth_as("secure-build") }} env  GNUPGHOME="{{ gpg_home }}" \
            TPM2_PKCS11_TCTI="device:/dev/tpmrm0" \
            TPM2_PKCS11_BACKEND="esysdb" \
            TPM2_PKCS11_LOG_LEVEL=2 \
            GNUTLS_PIN="$USERPIN" \
            GNUTLS_SO_PIN="$SOPIN" \
            TPM2_PKCS11_STORE="{{store_path}}" \
            "${@:6}"

[private]
[no-cd]
enroll-cert store_path=pkcs11_store pin_path=pkcs11_pin cert_path=sign_cert pki_dir=pki_dir:
    #!/usr/bin/env bash
    set -euo pipefail
    chown -R secure-build:secure-build {{ store_path }} 
    chmod -R 770 {{ store_path }}
    chmod 600 {{ store_path }}/tpm2_pkcs11.sqlite3
    CONF_DIR={{ secure_build_home }}/.config/pkcs11
    MODULES_DIR="$CONF_DIR/modules"
    {{ auth_as("secure-build") }} mkdir -p "$MODULES_DIR"
    
    source <(cat "{{ pin_path }}")
    # Export all TPM2 PKCS11 environment variables for sub-processes
    export TPM2_PKCS11_TCTI="device:/dev/tpmrm0"
    export GNUTLS_PIN="$USERPIN"
    export GNUTLS_SO_PIN="$SOPIN"
    export TPM2_PKCS11_STORE="{{ store_path }}"
    export TPM2_PKCS11_BACKEND="esysdb"
    export TPM2_PKCS11_LOG_LEVEL=2
    ls -la /dev/tpmrm0
    

    MODULE=$(find /usr/lib* /usr/local/lib* -name 'libtpm2_pkcs11.so*' 2>/dev/null | head -n1)
    [ -n "$MODULE" ] || (echo "libtpm2_pkcs11.so not found" && exit 1)

    # Force tpm2-pkcs11 to find the sqlite database directly
    #mkdir -p /etc/tpm2_pkcs11
    #echo "path={{ store_path }}" > /etc/tpm2_pkcs11/tpm2_pkcs11.header
    
    
    TEMPLATE=$(mktemp)
    trap 'rm -f "$TEMPLATE"' EXIT
    sed 's/^ *//' > "$MODULES_DIR/tpm2.module" << EOF
        module: $MODULE
        managed: yes
    EOF
    
    sed 's/^ *//' > "$TEMPLATE" << 'EOF'
        cn = "secure-build-signing"
        expiration_days = 3650
        signing_key
    EOF
    chown -R secure-build:secure-build $CONF_DIR
    chown secure-build:secure-build "$TEMPLATE"
    cat "$TEMPLATE"
    echo cert_path is {{ cert_path }}
    echo store_path is {{ store_path }}
    echo module is "$MODULE"
    if [ ! -f "{{ cert_path }}" ]; then
        echo "Generating self-signed certificate for TPM key..."
        just builder::build_cmd -s {{ store_path }} -p {{ pin_path }} -- certtool --generate-self-signed \
            --load-privkey "pkcs11:token=secure-build;object=secure-build-signing;type=private" \
            --load-pubkey "pkcs11:token=secure-build;object=secure-build-signing;type=public" \
            --template "$TEMPLATE" \
            --outfile "{{ cert_path }}"
        chmod 644 "{{ cert_path }}"
    fi

    echo "Writing certificate onto the PKCS11 token..."
    just builder::build_cmd -s {{ store_path }} -p {{ pin_path }} -- p11tool --login --set-pin="$USERPIN" --write "pkcs11:token=secure-build" \
        --load-certificate "{{ cert_path }}" --label secure-build-signing

# Configures gpg-agent to launch gnupg-pkcs11-scd via /usr/bin/env
[private]
configure-gnupg gnupg_home=gnupg_home store_path=pkcs11_store pki_dir=pki_dir:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -m 700 -p "{{ gnupg_home }}"
    

    MODULE=$(find /usr/lib* /usr/local/lib* -name 'libtpm2_pkcs11.so*' 2>/dev/null | head -n1)
    [ -n "$MODULE" ] || (echo "libtpm2_pkcs11.so not found" && exit 1)

    {{ auth }} tee "{{ gnupg_home }}/gnupg-pkcs11-scd.conf" > /dev/null << EOF
    providers tpm
    provider-tpm-library $MODULE
    EOF

    # Pass store & backend inline using /usr/bin/env
    {{ auth }} tee "{{ gnupg_home }}/gpg-agent.conf" > /dev/null << EOF
    scdaemon-program /usr/bin/gnupg-pkcs11-scd
    pinentry-program /usr/bin/pinentry
    allow-loopback-pinentry
    EOF

    chown -R secure-build:secure-build "{{ gnupg_home }}"

# Discovers the PKCS11 object's card-key hash via GnuPG's own stable
# card-status interface (rather than parsing raw scdaemon protocol lines)
# and writes it into gnupg-pkcs11-scd.conf as the "signature" role, so
# `--quick-generate-key ... card` has something to build a signing subkey
# from. CAVEAT: confirm the "grp:" record still holds the keygrip in the
# last field on your gnupg-pkcs11-scd version — run `gpg --card-status
# --with-colons` directly if this comes back empty.
[private]
map-card-key gnupg_home=gnupg_home store_path=pkcs11_store hash_path=signing_key_hash_path pin_path=pkcs11_pin cert_path=sign_cert pki_dir=pki_dir: (configure-gnupg)
    #!/usr/bin/env bash
    set -euo pipefail
    
    export GNUPGHOME="{{ gnupg_home }}"
    
    export XDG_DATA_HOME="{{ pki_dir }}"
    
    {{ auth }} pkill -u secure-build -f gpg-agent || true
    {{ auth }} pkill -u secure-build -f gnupg-pkcs11-scd || true
    echo $GNUPGHOME
    just builder::build_cmd -s {{ store_path }} -p {{ pin_path }} -g {{ gnupg_home }} -- systemctl --user set-environment TPM2_PKCS11_STORE="{{ store_path }}" TPM2_PKCS11_BACKEND="esysdb"
    just builder::build_cmd -s {{ store_path }} -p {{ pin_path }} -g {{ gnupg_home }} -- systemctl --user restart gpg-agent
    just builder::build_cmd -s {{ store_path }} -p {{ pin_path }} -g {{ gnupg_home }} -- gpg-connect-agent /bye

    STATUS=$(just builder::build_cmd -s {{ store_path }} -p {{ pin_path }} -g {{ gnupg_home }} -- gpg --card-status --with-colons 2>/dev/null || true)
    echo $STATUS
    # Extract 40-character hex keygrip directly from grp lines
    # Query scdaemon directly for KEYPAIRINFO records returned by gnupg-pkcs11-scd
    HASH=$(just builder::build_cmd -s {{ store_path }} -p {{ pin_path }} -g {{ gnupg_home }} -- \
        gpg-connect-agent 'SCD LEARN --force' /bye 2>/dev/null \
        | awk '/S KEYPAIRINFO/ {print $3; exit}')

    [ -n "$HASH" ] || (echo "could not read keygrip from scdaemon — check gnupg-pkcs11-scd logs" && exit 1)


    if ! grep -q "^openpgp-sign $HASH" "{{ gnupg_home }}/gnupg-pkcs11-scd.conf" 2>/dev/null; then
        echo "openpgp-sign $HASH" |  tee -a "{{ gnupg_home }}/gnupg-pkcs11-scd.conf" > /dev/null
    fi
    {{ auth }} pkill -u secure-build -f gpg-agent || true
    {{ auth }} pkill -u secure-build -f gnupg-pkcs11-scd || true

bind-gpg-key gnupg_home=gnupg_home store_path=pkcs11_store  pin_path=pkcs11_pin: (map-card-key)
    #!/usr/bin/env bash
    set -euo pipefail
    source <({{ auth }} cat "{{ pin_path }}")

    if just builder::build_cmd -p {{ pin_path }} -- gpg --batch --with-colons --list-secret-keys 2>/dev/null | grep -q '^sec'; then
        echo "Secret key already bound; nothing to do."
        exit 0
    fi
    
    HASH=$(just builder::build_cmd -s {{ store_path }} -p {{ pin_path }} -g {{ gnupg_home }} -- \
        gpg-connect-agent 'SCD LEARN --force' /bye 2>/dev/null \
        | awk '/S KEYPAIRINFO/ {print $3; exit}')
    echo HASH IS $HASH
    [ -n "$HASH" ] || (echo "could not read keygrip from scdaemon — check gnupg-pkcs11-scd logs" && exit 1)

    UID_STR=$(openssl x509 -in "{{ sign_cert }}" -noout -subject \
    | sed -n 's/.*CN\s*=\s*\([^,/]*\).*/\1/p')
    echo UID IS $UID_STR
    echo "Generating OpenPGP identity from card key..."
    BATCH_FILE=$(mktemp)
    trap 'rm -f "$BATCH_FILE"' EXIT
    sed 's/^ *//' > "$BATCH_FILE" << EOF
        %echo Generating OpenPGP identity from card key
        Key-Type: RSA
        Key-Grip: $HASH
        Key-Usage: sign
        Name-Real: $UID_STR
        Expire-Date: 0
        %commit
        %echo done
    EOF
    {{ auth }} chown secure-build:secure-build $BATCH_FILE
    printf '%s' "$USERPIN" | just builder::build_cmd -p {{ pin_path }} -g {{ gnupg_home }} -- \
        gpg --batch --generate-key --pinentry-mode loopback --passphrase-fd 0  "$BATCH_FILE"    
    

# Exports the bound GPG key and rewrites policy.json to use signedBy/GPGKeys
# instead of sigstoreSigned. Run after bind-gpg-key has produced a secret key.
export-gpg-key gnupg_home=gnupg_home sign_link_path=sign_pem_link keyring_path=sign_keyring key_id_path=signing_key_id_path:
    #!/usr/bin/env bash
    set -euo pipefail
    
    # Obtain Key ID from the card / scdaemon state
     KEYID=$(just builder::build_cmd -- gpg --card-status | awk '/Key attribute/ {print $NF}' | head -n1)
    [ -n "$KEYID" ] || (echo "Failed to locate GPG Key ID from TPM card status" && exit 1)

    # Save the key ID for sign-gpg
    echo "$KEYID" > "{{ key_id_path }}"

    # Export public key ring for verification
    just builder::build_cmd -- gpg --batch --yes --export "$KEYID" | {{ auth }} tee "{{ keyring_path }}" > /dev/null
    
    {{ auth }} chmod 644 "{{ keyring_path }}"

    echo "Linking into {{ containers_pki_dir }}..."
    {{ auth }} ln -sf "{{ keyring_path }}" {{ sign_link_path }}

    echo "Updating {{ policy_path }}..."
    POLICY_TMP=$(mktemp)
    [ -f "{{ policy_path }}" ] || echo '{}' | {{ auth }} tee "{{ policy_path }}" > /dev/null
    jq \
        --arg keypath "{{ sign_link_path }}" \
        '.default //= [{"type": "reject"}]
         | .transports["containers-storage"][""] = [{"type": "signedBy", "keyType": "GPGKeys", "keyPath": $keypath}]' \
        "{{ policy_path }}" > "$POLICY_TMP"
    {{ auth }} mv "$POLICY_TMP" "{{ policy_path }}"

    echo "$KEYID" | {{ auth }} tee "{{ key_id_path }}" > /dev/null
    echo "GPG key $KEYID enrolled; containers-storage now requires signedBy verification."

[private]
enroll-gpg-key key_pub_path=sign_keyring gpg_pub_link_path=gpg_pub_link_path policy_path=policy_path:
    #!/usr/bin/env bash
    set -euo pipefail
    POLICY_TMP=$(mktemp)

    echo "Linking GPG public key into {{ containers_pki_dir }}..."
    {{ auth }} mkdir -p "{{ containers_pki_dir }}"
    {{ auth }} ln -sf "{{ key_pub_path }}" "{{ gpg_pub_link_path }}"

    echo "Updating {{ policy_path }} for GPG verification..."
    [ -f "{{ policy_path }}" ] || echo '{}' | {{ auth }} tee "{{ policy_path }}" > /dev/null

    jq \
        --arg keypath "{{ gpg_pub_link_path }}" \
        '.default //= [{"type": "reject"}]
         | .transports["containers-storage"][""] = [{
             "type": "signedBy",
             "keyType": "GPGKeys",
             "keyFiles": [$keypath]
           }]' \
        "{{ policy_path }}" > "$POLICY_TMP"
    {{ auth }} mv "$POLICY_TMP" "{{ policy_path }}"

    echo "GPG key enrolled at {{ gpg_pub_link_path }}; containers-storage now requires GPG signature verification."

debug-cert store_path=pkcs11_store pin_path=pkcs11_pin cert_path=sign_cert pki_dir=pki_dir:
    #!/usr/bin/env bash
    source <(cat "{{ pin_path }}")
    #export TPM2_PKCS11_TCTI="device:/dev/tpmrm0"
    CONF_DIR="{{ pki_dir }}/p11-config"
    MODULES_DIR="$CONF_DIR/pkcs11/modules"
    export GNUTLS_PIN="$USERPIN"
    export GNUTLS_SO_PIN="$SOPIN"
    export TPM2_PKCS11_STORE="{{ store_path }}"
    export TPM2_PKCS11_BACKEND="esys"
    export XDG_DATA_HOME="{{ pki_dir }}"
    export TPM2_PKCS11_LOG_LEVEL=2
    export TPM2_PKCS11_TCTI="device:/dev/tpmrm0"
    MODULES_DIR="{{ pki_dir }}/pkcs11-modules"
    export P11_KIT_USER_CONFIG_DIR="$CONF_DIR"
    export P11_KIT_USER_CONFIG_DIR="$MODULES_DIR"
    export P11_KIT_DEBUG=all
    P11_KIT_DEBUG=all p11tool --list-tokens
