import '../common.just'


# Generate the primary context only if it doesn't already exist
[private]
ensure-primary primary_ctx_path:
    #!/usr/bin/env bash
    if [ ! -f "{{primary_ctx_path}}" ]; then \
        echo "Primary key context not found. Generating..."; \
        tpm2_createprimary -C o -c "{{primary_ctx_path}}"; \
    else \
        echo "Primary key context already exists at {{primary_ctx_path}}."; \
    fi

generate-key primary_ctx_path=primary_ctx sign_ctx_path=sign_ctx sign_pub_path=sign_pub sign_priv_path=sign_priv sign_pem_path=sign_pem: (ensure-primary primary_ctx_path)
    #!/usr/bin/env bash
    if [ ! -f "{{sign_ctx_path}}" ]; then \
        echo "Generating ECC signing key..."; \
        tpm2_create -C "{{primary_ctx_path}}" \
            -G ecc256:ecdsa-sha256:null \
            -a "fixedtpm|fixedparent|sensitivedataorigin|userwithauth|restricted|sign" \
            -u "{{sign_pub_path}}" -r "{{sign_priv_path}}"; \
        tpm2_load -C "{{primary_ctx_path}}" -u "{{sign_pub_path}}" -r "{{sign_priv_path}}" -c "{{sign_ctx_path}}";
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

# Force regeneration of all keys: revoke the old key's trust, delete
# existing context/blob files, generate a fresh key, and re-enroll it.
regenerate primary_ctx_path=primary_ctx sign_ctx_path=sign_ctx sign_pub_path=sign_pub sign_priv_path=sign_priv sign_pem_path=sign_pem: revoke-key
    rm -f {{ primary_ctx_path }} {{ sign_ctx_path }} {{ sign_pub_path }} {{ sign_priv_path }} {{ sign_pem_path }}
    just builder::generate-key {{ primary_ctx_path }} {{ sign_ctx_path }} {{ sign_pub_path }} {{ sign_priv_path }}
    just builder::enroll-key {{ sign_ctx_path }} {{ sign_pem_path }}

setup-user container-storage=container-store:
    #!/usr/bin/env bash
    just create-sys-user secure-build
    {{ auth }} mkdir -p {{ pki_dir }}
    {{ auth }} chmod 700 {{ pki_dir }}
    {{ auth }} mkdir -m 700 -p {{ container-storage }}

setup: setup-user (generate-key) enroll-key