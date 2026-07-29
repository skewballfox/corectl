import './common.just'
import '../common.just'



[private]
setup-pki-dir:
    #!/usr/bin/env bash
    sudo mkdir -p {{ pki_dir }}
    sudo chmod 755 {{ pki_dir }}

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

generate-key primary_ctx_path=primary_ctx sign_ctx_path=sign_ctx: (ensure-primary primary_ctx_path)
    #!/usr/bin/env bash
    if [ ! -f "{{sign_ctx_path}}" ]; then \
        echo "Generating ECC signing key..."; \
        tpm2_create -C "{{primary_ctx_path}}" \
            -G ecc256:ecdsa-sha256:null \
            -a "fixedtpm|fixedparen|sensitivedataorigin|userwithauth|restricted|sign" \
            -u ecc.pub -r ecc.priv; \
        tpm2_load -C "{{primary_ctx_path}}" -u ecc.pub -r ecc.priv -c "{{sign_ctx_path}}"; \
    else \
        echo "Signing key context already exists at {{sign_ctx_path}}."; \
    fi

# Force regeneration of all keys by deleting existing context files first
regenerate primary_ctx_path=primary_ctx sign_ctx_path=sign_ctx:
    rm -f {{ primary_ctx_path }} {{ sign_ctx_path }} ecc.pub ecc.priv
    just builder::generate-key primary_ctx_path sign_ctx_path

setup-user container-storage=container-store:
    #!/usr/bin/env bash
    just create-sys-user secure-build
    mkdir -p {{ container-storage }}c

setup: setup-user (generate-key)