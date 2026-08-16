import? '../common.just'
import 'gpg.just'

# Generate the persistent primary key handle only if it doesn't already exist
[private]
ensure-primary primary_handle:
    #!/usr/bin/env bash
    set -euo pipefail
    if tpm2_getcap handles-persistent | grep -qi "{{primary_handle}}"; then
        echo "Persistent primary already exists at {{primary_handle}}."
    else
        echo "Persistent primary not found. Generating..."
        TMP_CTX=$(mktemp)
        tpm2_createprimary -C o -c "$TMP_CTX"
        {{ auth }} tpm2_evictcontrol -C o -c "$TMP_CTX" "{{primary_handle}}"
        rm -f "$TMP_CTX"
    fi

generate-key primary_handle=primary_handle sign_ctx_path=sign_ctx sign_pub_path=sign_pub sign_priv_path=sign_priv sign_pem_path=sign_pem: (ensure-primary primary_handle) (require-user "root")
    #!/usr/bin/env bash
    if [ ! -f "{{sign_ctx_path}}" ]; then \
        echo "Generating ECC signing key..."; \
        tpm2_create -C "{{primary_handle}}" \
            -G ecc256:null \
            -a "fixedtpm|fixedparent|sensitivedataorigin|userwithauth|sign" \
            -u "{{sign_pub_path}}" -r "{{sign_priv_path}}"; \
        tpm2_load -C "{{primary_handle}}" -u "{{sign_pub_path}}" -r "{{sign_priv_path}}" -c "{{sign_ctx_path}}";
    else \
        echo "Signing key context already exists at {{sign_ctx_path}}."; \
    fi
    {{ auth }} chmod 440  "{{ sign_pub_path }}" "{{ sign_priv_path }}"
    {{ auth }} chown root:secure-build "{{ sign_pub_path }}" "{{ sign_priv_path }}"

enroll-key sign_ctx_path=sign_ctx sign_pem_path=sign_pem sign_pem_link_path=sign_pem_link:
    #!/usr/bin/env bash
    set -euo pipefail
    POLICY_TMP=$(mktemp)
    
    echo "Exporting public key from TPM context..."
    tpm2_readpublic -c "{{ sign_ctx_path }}" -f pem -o "{{ sign_pem_path }}"
    {{ auth }} chmod 644 "{{ sign_pem_path }}"

    echo "Linking into {{ containers_pki_dir }}..."
    {{ auth }} ln -sf "{{ sign_pem_path }}" "{{ sign_pem_link_path }}"

    echo "Updating {{ policy_path }}..."
    [ -f "{{ policy_path }}" ] || echo '{}' | {{ auth }} tee "{{ policy_path }}" > /dev/null

    jq \
        --arg keypath "{{ sign_pem_path }}" \
        '.default //= [{"type": "reject"}]
         | .transports["containers-storage"][""] = [{"type": "sigstoreSigned", "keyPath": $keypath}]' \
        "{{ policy_path }}" > "$POLICY_TMP"
    {{ auth }} mv "$POLICY_TMP" "{{ policy_path }}"

    echo "Key enrolled at {{ sign_pem_path }}; containers-storage now requires sigstoreSigned verification."



# Remove the currently-enrolled signing key from the containers-storage
# trust policy, falling back to reject for that scope.
[private]
revoke-key:
    #!/usr/bin/env bash
    set -euo pipefail
    POLICY_TMP=$(mktemp)

    if [ -f "{{ policy_path }}" ]; then
        echo "Revoking current signing key from {{ policy_path }}..."
        jq \
            'if .transports["containers-storage"] then
                 .transports["containers-storage"] |= del(.[""])
             else . end' \
            "{{ policy_path }}" > "$POLICY_TMP"
        {{ auth }} cp "$POLICY_TMP" "{{ policy_path }}"
    else
        echo "No policy.json found; nothing to revoke."
    fi

[private]
setup-pkcs11-token sign_pub_path=sign_pub sign_priv_path=sign_priv pin_path=pkcs11_pin store_path=pkcs11_store:
    #!/usr/bin/env bash
    set -euo pipefail

    {{ auth }} mkdir -m 700 -p "{{ store_path }}"

    if [ ! -f "{{ pin_path }}" ]; then
        echo "Generating PKCS11 token PINs..."
        USERPIN=$(openssl rand -hex 16)
        SOPIN=$(openssl rand -hex 16)
        printf 'USERPIN=%s\nSOPIN=%s\n' "$USERPIN" "$SOPIN" | {{ auth }} tee "{{ pin_path }}" > /dev/null
        
    fi
    {{ auth }} chmod 440 "{{ pin_path }}" 
    {{ auth }} chown root:secure-build "{{ pin_path }}"
    source <(cat "{{ pin_path }}")

    export TPM2_PKCS11_STORE="{{ store_path }}"

    if [ ! -f "{{ store_path }}/tpm2_pkcs11.sqlite3" ]; then
        INIT_OUTPUT=$(just builder::build_cmd -p "{{ pin_path }}" -- tpm2_ptool init --path="{{ store_path }}")
        echo "$INIT_OUTPUT"

        PID=$(awk -F": " '/^id:/ {print $2}' <<< "$INIT_OUTPUT")
        
        if [ -z "$PID" ]; then
            echo "failed to parse primary id from tpm2_ptool init output:" >&2
            echo "$INIT_OUTPUT" >&2
            exit 1
        fi
        just builder::build_cmd -p "{{ pin_path }}" -- tpm2_ptool addtoken --pid="$PID" --sopin="$SOPIN" --userpin="$USERPIN" --label=secure-build --path="{{ store_path }}"
    else
        echo "store/token already initialized"
    fi

    just builder::build_cmd -p {{pin_path}} -- tpm2_ptool addkey \
        --label=secure-build \
        --userpin="$USERPIN" \
        --key-label=secure-build-signing \
        --algorithm=rsa2048 \
        --path="{{ store_path }}" \
        # "{{ sign_pub_path }}" "{{ sign_priv_path }}"


# Stops running daemons and removes all TPM contexts, PKCS11 tokens, certs,
# and GnuPG keyring state so regeneration can start from a clean slate.
[private]
clean-state primary_handle=primary_handle sign_ctx_path=sign_ctx sign_pub_path=sign_pub sign_priv_path=sign_priv sign_pem_path=sign_pem sign_pem_link_path=sign_pem_link store_path=pkcs11_store pin_path=pkcs11_pin cert_path=sign_cert gnupg_home=gnupg_home sign_keyring=sign_keyring key_id_path=signing_key_id_path hash_path=signing_key_hash_path: revoke-key
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Stopping GnuPG daemons for secure-build user..."
    {{ auth }} pkill -u secure-build -f gpg-agent 2>/dev/null || true
    {{ auth }} pkill -u secure-build -f gnupg-pkcs11-scd 2>/dev/null || true

    echo "Evicting persistent primary handle {{ primary_handle }} (if present)..."
    {{ auth }} tpm2_evictcontrol -C o -c {{ primary_handle }} 2>/dev/null || echo "No persistent primary to evict."

    echo "Cleaning up TPM context, key files, and PKCS11 store..."
    rm -f "{{ sign_ctx_path }}" "{{ sign_pub_path }}" "{{ sign_priv_path }}" "{{ sign_pem_path }}"
    {{ auth }} rm -f "{{ sign_pem_link_path }}"
    {{ auth }} rm -f "{{ store_path }}"/tpm2_pkcs11.sqlite3 "{{ pin_path }}" "{{ cert_path }}"

    echo "Cleaning up GnuPG keyring and state..."
    {{ auth }} rm -rf "{{ gnupg_home }}"
    rm -f "{{ sign_keyring }}" "{{ key_id_path }}" "{{ hash_path }}"


# Tears down state and regenerates a raw TPM sigstore-style signing identity
regenerate-cosign primary_handle=primary_handle sign_ctx_path=sign_ctx sign_pub_path=sign_pub sign_priv_path=sign_priv sign_pem_path=sign_pem sign_pem_link_path=sign_pem_link: (clean-state primary_handle sign_ctx_path sign_pub_path sign_priv_path sign_pem_path sign_pem_link_path)
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Regenerating Cosign / TPM signing identity..."
    just builder::generate-key "{{ primary_handle }}" "{{ sign_ctx_path }}" "{{ sign_pub_path }}" "{{ sign_priv_path }}"
    just builder::enroll-key "{{ sign_ctx_path }}" "{{ sign_pem_path }}" "{{ sign_pem_link_path }}"


# Tears down state and regenerates a TPM-backed GPG signing identity via PKCS#11
regenerate-gpg sign_ctx_path=sign_ctx sign_pub_path=sign_pub sign_priv_path=sign_priv sign_pem_path=sign_pem sign_pem_link_path=sign_pem_link: (clean-state primary_handle sign_ctx_path sign_pub_path sign_priv_path sign_pem_path sign_pem_link_path)
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Regenerating TPM-backed GPG identity..."
    just builder::setup-pkcs11-token "{{ sign_pub_path }}" "{{ sign_priv_path }}"
    just builder::enroll-cert
    just builder::bind-gpg-key
    just builder::export-gpg-key
    just builder::enroll-gpg-key

setup-user container-storage=container-store:
    #!/usr/bin/env bash
    just create-sys-user secure-build -g tss -d -q
    {{ auth }} mkdir -p {{ pki_dir }}
    {{ auth }} mkdir -p {{ pkcs11_store }}
    {{ auth }} chown root:secure-build {{ pki_dir }}
    {{ auth }} chmod 770 {{ pki_dir }}
    {{ auth }} mkdir -m 700 -p {{ container-storage }}

#setup: setup-user (generate-key) enroll-key setup-pkcs11-setup-pkcs11-token
setup: setup-user setup-pkcs11-token enroll-cert bind-gpg-key export-gpg-key
    @echo "TPM-backed GPG signing identity enrolled; containers-storage now requires signedBy verification."