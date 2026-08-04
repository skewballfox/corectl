import '../common.just'


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

generate-key primary_handle=primary_handle sign_ctx_path=sign_ctx sign_pub_path=sign_pub sign_priv_path=sign_priv sign_pem_path=sign_pem: (ensure-primary primary_handle)
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
setup-pkcs11-token primary_handle=primary_handle sign_pub_path=sign_pub sign_priv_path=sign_priv pin_path=pkcs11_pin store_path=pkcs11_store:
    #!/usr/bin/env bash
    set -euo pipefail

    {{ auth }} mkdir -m 750 -p "{{ store_path }}"

    if [ ! -f "{{ pin_path }}" ]; then
        echo "Generating PKCS11 token PINs..."
        USERPIN=$(openssl rand -hex 16)
        SOPIN=$(openssl rand -hex 16)
        printf 'USERPIN=%s\nSOPIN=%s\n' "$USERPIN" "$SOPIN" | {{ auth }} tee "{{ pin_path }}" > /dev/null
        {{ auth }} chmod 600 "{{ pin_path }}"
        {{ auth }} chown root:secure-build "{{ pin_path }}"
    fi

    source <({{ auth }} cat "{{ pin_path }}")

    export TPM2_PKCS11_STORE="{{ store_path }}"

    if [ ! -f "{{ store_path }}/tpm2_pkcs11.sqlite3" ]; then
        PID=$(tpm2_ptool init --primary-handle="{{ primary_handle }}" --path="{{ store_path }}" | awk '/id:/ {print $2}')
        tpm2_ptool addtoken --pid="$PID" --sopin="$SOPIN" --userpin="$USERPIN" --label=secure-build --path="{{ store_path }}"
    else
        echo "store/token already initialized"
    fi

    tpm2_ptool link \
        --label=secure-build \
        --userpin="$USERPIN" \
        --key-label=secure-build-signing \
        --path="{{ store_path }}" \
        "{{ sign_pub_path }}" "{{ sign_priv_path }}"

regenerate primary_handle=primary_handle sign_ctx_path=sign_ctx sign_pub_path=sign_pub sign_priv_path=sign_priv sign_pem_path=sign_pem sign_pem_link_path=sign_pem_link: revoke-key
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Evicting persistent primary at {{ primary_handle }} (if present)..."
    {{ auth }} tpm2_evictcontrol -C o "{{ primary_handle }}" 2>/dev/null || echo "no persistent primary to evict"

    rm -f "{{ sign_ctx_path }}" "{{ sign_pub_path }}" "{{ sign_priv_path }}" "{{ sign_pem_path }}"
    {{ auth }} rm -rf "{{ pkcs11_store }}" "{{ pkcs11_pin }}"
    {{ auth }} rm -f "{{ sign_pem_link_path }}"

    just builder::generate-key "{{ primary_handle }}" "{{ sign_ctx_path }}" "{{ sign_pub_path }}" "{{ sign_priv_path }}"
    just builder::setup-pkcs11-token "{{ primary_handle }}" "{{ sign_pub_path }}" "{{ sign_priv_path }}"
    just builder::enroll-key "{{ sign_ctx_path }}" "{{ sign_pem_path }}" "{{ sign_pem_link_path }}"

setup-user container-storage=container-store:
    #!/usr/bin/env bash
    just create-sys-user secure-build
    {{ auth }} mkdir -p {{ pki_dir }}
    {{ auth }} chmod 700 {{ pki_dir }}
    {{ auth }} mkdir -m 700 -p {{ container-storage }}

setup: setup-user (generate-key) enroll-key setup-pkcs11-token