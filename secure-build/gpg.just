import? '../common.just'




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
        just build_cmd -s {{ store_path }} -p {{ pin_path }} -- certtool --generate-self-signed \
            --load-privkey "pkcs11:token=secure-build;object=secure-build-signing;type=private" \
            --load-pubkey "pkcs11:token=secure-build;object=secure-build-signing;type=public" \
            --template "$TEMPLATE" \
            --outfile "{{ cert_path }}"
        chmod 644 "{{ cert_path }}"
    fi

    # Write it once only: pkcs11-helper treats a cert as a CA if any *other* cert
    # on the token was issued by it, so duplicate copies of this self-signed cert
    # all become CAs, leaving gnupg-pkcs11-scd no user cert for the key (KEYINFO
    # then reports "not found" and gpg-agent loops forever).
    if just build_cmd -s {{ store_path }} -p {{ pin_path }} -- p11tool --list-all-certs \
        "pkcs11:token=secure-build;object=secure-build-signing" 2>/dev/null | grep -q 'X.509 Certificate'; then
        echo "Certificate already on the PKCS11 token."
    else
        echo "Writing certificate onto the PKCS11 token..."
        just build_cmd -s {{ store_path }} -p {{ pin_path }} -- p11tool --login --set-pin="$USERPIN" --write "pkcs11:token=secure-build" \
            --load-certificate "{{ cert_path }}" --label secure-build-signing
    fi

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

# Has gpg-agent learn the token's key and write its card stub
# (private-keys-v1.d/<keygrip>.key), which bind-gpg-key's `Key-Grip:` needs.
# No openpgp-sign/encr/auth lines in gnupg-pkcs11-scd.conf: those switch it to
# gnupg-2.0 emulation, where it ignores the keyref gpg-agent 2.4 passes to
# READKEY, so the agent's LEARN fails and no stub gets written.
[private]
map-card-key gnupg_home=gnupg_home store_path=pkcs11_store hash_path=signing_key_hash_path pin_path=pkcs11_pin cert_path=sign_cert pki_dir=pki_dir: (configure-gnupg)
    #!/usr/bin/env bash
    set -euo pipefail
    
    export GNUPGHOME="{{ gnupg_home }}"
    
    export XDG_DATA_HOME="{{ pki_dir }}"
    
    {{ auth }} pkill -u secure-build -f gpg-agent || true
    {{ auth }} pkill -u secure-build -f gnupg-pkcs11-scd || true
    echo $GNUPGHOME
    just build_cmd -s {{ store_path }} -p {{ pin_path }} -g {{ gnupg_home }} -- systemctl --user set-environment TPM2_PKCS11_STORE="{{ store_path }}" TPM2_PKCS11_BACKEND="esysdb"
    just build_cmd -s {{ store_path }} -p {{ pin_path }} -g {{ gnupg_home }} -- systemctl --user restart gpg-agent
    just build_cmd -s {{ store_path }} -p {{ pin_path }} -g {{ gnupg_home }} -- gpg-connect-agent /bye

    HASH=$(just build_cmd -s {{ store_path }} -p {{ pin_path }} -g {{ gnupg_home }} -- \
        gpg-connect-agent 'SCD LEARN --force' /bye 2>/dev/null \
        | awk '/^S KEYPAIRINFO/ {print $3; exit}')
    [[ "$HASH" =~ ^[0-9A-F]{40}$ ]] \
        || (echo "no KEYPAIRINFO from scdaemon — check the token holds exactly one secure-build-signing cert" && exit 1)

    # The agent's own LEARN (not "SCD LEARN") READKEYs each key and writes stubs
    just build_cmd -s {{ store_path }} -p {{ pin_path }} -g {{ gnupg_home }} -- \
        gpg-connect-agent 'LEARN --force' /bye
    # "S KEYINFO <keygrip> T ..." — T marks a key stored on a card
    just build_cmd -s {{ store_path }} -p {{ pin_path }} -g {{ gnupg_home }} -- \
        gpg-connect-agent "KEYINFO $HASH" /bye | grep -q "^S KEYINFO $HASH T " \
        || (echo "gpg-agent wrote no card stub for $HASH — check journalctl for gpg-agent/gnupg-pkcs11-scd" && exit 1)
    echo "Card key $HASH registered with gpg-agent"

    {{ auth }} pkill -u secure-build -f gpg-agent || true
    {{ auth }} pkill -u secure-build -f gnupg-pkcs11-scd || true

bind-gpg-key gnupg_home=gnupg_home store_path=pkcs11_store  pin_path=pkcs11_pin: (map-card-key)
    #!/usr/bin/env bash
    set -euo pipefail
    source <({{ auth }} cat "{{ pin_path }}")

    if just build_cmd -p {{ pin_path }} -- gpg --batch --with-colons --list-secret-keys 2>/dev/null | grep -q '^sec'; then
        echo "Secret key already bound; nothing to do."
        exit 0
    fi
    
    # Keygrip from LEARN's "S KEYPAIRINFO <keygrip> <keyref>". KEYPAIRINFO only
    # appears for a cert paired with its private key; it goes missing if
    # duplicate certs on the token get classed as CAs (CERTINFO 102).
    HASH=$(just build_cmd -s {{ store_path }} -p {{ pin_path }} -g {{ gnupg_home }} -- \
        gpg-connect-agent 'SCD LEARN --force' /bye 2>/dev/null \
        | awk '/^S KEYPAIRINFO/ {print $3; exit}')
    echo HASH IS $HASH
    [[ "$HASH" =~ ^[0-9A-F]{40}$ ]] \
        || (echo "no KEYPAIRINFO from scdaemon — check the token holds exactly one secure-build-signing cert" && exit 1)

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
    printf '%s' "$USERPIN" | just build_cmd -p {{ pin_path }} -g {{ gnupg_home }} -- \
        gpg --batch --generate-key --pinentry-mode loopback --passphrase-fd 0  "$BATCH_FILE"    
    

# Exports the bound GPG key to a keyring and records its fingerprint for
# sign-gpg, then hands off to enroll-gpg-key to install it and point
# policy.json at it. Run after bind-gpg-key has produced a secret key.
export-gpg-key gnupg_home=gnupg_home keyring_path=sign_keyring key_id_path=signing_key_id_path: && (enroll-gpg-key keyring_path)
    #!/usr/bin/env bash
    set -euo pipefail

    # Fingerprint of the card-bound key
    KEYID=$(just build_cmd -- gpg --batch --with-colons --list-secret-keys \
        | awk -F: '/^fpr:/ {print $10; exit}')
    [ -n "$KEYID" ] || (echo "Failed to locate the bound GPG secret key — run bind-gpg-key first" && exit 1)

    # Export public key ring for verification
    just build_cmd -- gpg --batch --yes --export "$KEYID" | {{ auth }} tee "{{ keyring_path }}" > /dev/null
    # gpg exits 0 with "nothing exported" on an unknown key, leaving an empty keyring
    {{ auth }} test -s "{{ keyring_path }}" || (echo "gpg exported nothing for $KEYID" && exit 1)
    {{ auth }} chmod 644 "{{ keyring_path }}"

    # Save the key ID for sign-gpg
    echo "$KEYID" | {{ auth }} tee "{{ key_id_path }}" > /dev/null
    echo "Exported GPG key $KEYID to {{ keyring_path }}"

# Installs a GPG public keyring where podman/skopeo read it and requires
# signedBy verification against it for containers-storage. Runs after
# export-gpg-key; call it directly to re-enroll an existing keyring.
[private]
enroll-gpg-key key_pub_path=sign_keyring gpg_pub_link_path=gpg_pub_link_path policy_path=policy_path:
    #!/usr/bin/env bash
    set -euo pipefail
    POLICY_TMP=$(mktemp)

    # Copy rather than symlink: pki_dir isn't traversable by the users whose
    # podman/skopeo read this key through policy.json.
    echo "Installing GPG public key into {{ containers_pki_dir }}..."
    {{ auth }} mkdir -p "{{ containers_pki_dir }}"
    {{ auth }} test -s "{{ key_pub_path }}" || (echo "{{ key_pub_path }} is empty — run export-gpg-key first" && exit 1)
    {{ auth }} install -m 644 -o root -g root -T "{{ key_pub_path }}" "{{ gpg_pub_link_path }}"

    echo "Updating {{ policy_path }} for GPG verification..."
    [ -f "{{ policy_path }}" ] || echo '{}' | {{ auth }} tee "{{ policy_path }}" > /dev/null

    jq \
        --arg keypath "{{ gpg_pub_link_path }}" \
        '.default //= [{"type": "reject"}]
         | .transports["containers-storage"][""] = [{
             "type": "signedBy",
             "keyType": "GPGKeys",
             "keyPath": $keypath
           }]' \
        "{{ policy_path }}" > "$POLICY_TMP"
    {{ auth }} cp "$POLICY_TMP" "{{ policy_path }}"

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
