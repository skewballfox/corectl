set unstable
set lists

os_id := shell('grep -E "^(ID|VARIANT_ID)=" /etc/os-release 2>/dev/null | tr "\n" " "')
# Auth will be run0 on secureblue (server) and sudo otherwise
auth := if os_id=~"secureblue" { "run0" } else { "sudo" }
auth_shell := if os_id=~"secureblue" { "run0 --via-shell" } else { "sudo" }

auth_as(target_user) := if auth == "run0" {
    "run0 -u " + target_user 
} else {
    "sudo -u " + target_user
}


# secure-build base dir
secure_build_dir := "/var/lib/secure-build"
secure_build_home := "/var/home/secure-build"

# directory for the signing key for locally built containers
pki_dir := secure_build_dir + "/pki"

pkcs11_store := secure_build_home + "/.tpm2_pkcs11"
pkcs11_pin   := pki_dir + "/pkcs11.pin"
# the top-level directory for builds by the secure-build user
container-store := secure_build_dir + "/containers"

# persistent TPM handle for the primary key (required so tpm2_ptool link
# can trust it as a parent — see [INTEROPERABILITY.md](https://github.com/tpm2-software/tpm2-pkcs11/blob/master/docs/INTEROPERABILITY.md))
primary_handle := "0x81000001"

# primary key context location
primary_ctx := pki_dir + "/primary.ctx"
# signing key context location
sign_ctx := pki_dir + "/tpm_sign.ctx"
# the public key for build signing
sign_pub    := pki_dir + "/secure-build-signing.pem"
# tpm2-tools wrapped private blob (sensitive)
sign_priv   := pki_dir + "/sign.priv"
# exported PEM for podman policy.json
sign_pem    := pki_dir + "/secure-build.pem"  # exported PEM for policy.json

# cosign binary
cosign_exe := '/home/linuxbrew/.linuxbrew/bin/cosign'

# standard location for container related pub keys
containers_pki_dir := "/etc/pki/containers"

# exported PEM for podman policy.json
sign_pem_link    := containers_pki_dir + "/secure-build.pem"  # exported PEM for policy.json

# podman's container policy
policy_path := "/etc/containers/policy.json"
# the location for configuration for the system users running quadlets
user_storage := ".config/containers/storage.conf"

# gnupg home used by the secure-build user for the TPM-backed signing identity
gnupg_home := secure_build_home + "/.gnupg"

key_pub_path := pki_dir + "/secure-build.pub"

gpg_pub_link_path := containers_pki_dir + "/GPG-KEY-secure-build"

# self-signed cert written onto the PKCS11 token (required by gnupg-pkcs11-scd,
# which reads the public key from the certificate, not the raw key object)
sign_cert := pki_dir + "/secure-build-signing-cert.pem"

# exported binary OpenPGP keyring used as policy.json's GPGKeys keyPath
sign_keyring := pki_dir + "/secure-build.gpg"

# file recording the enrolled GPG key id, written by export-gpg-key
signing_key_id_path := pki_dir + "/signing-key-id"

# gnupg-pkcs11-scd needs to be told which PKCS11 object plays the "signature"
# role in its OpenPGP-card emulation. This value is discovered once (it's
# derived from the key on the token, not a secret) and cached to a file so
# later recipes don't need a live SCD LEARN round-trip.
signing_key_hash_path := pki_dir + "/signing-key-hash"


build_env := "TPM2_PKCS11_TCTI=device:/dev/tpmrm0 " + \
           "TPM2_PKCS11_BACKEND=esysdb " + \
           "TPM2_PKCS11_LOG_LEVEL=2"

# Pre-check: Enforce that the current recipe executes as the expected user
[private]
require-user target_user:
    @if [ "$(whoami)" != "{{ target_user }}" ]; then \
        echo "Error: Recipe must be run as '{{ target_user }}' (currently running as: $(whoami))." >&2; \
        exit 1; \
    fi

# Private helper recipe to restore SELinux context safely
_restore-selinux USER:
    #!/usr/bin/env bash
    targetdir=$(getent passwd "{{ USER }}" | cut -d: -f6 || true)
    if [ -d "$targetdir" ] && command -v restorecon >/dev/null 2>&1; then
        echo "Applying SELinux security context to $targetdir..."
        {{ auth }} restorecon -R "$target_dir"
    fi
_setup-linger quadlet USER:
    #!/usr/bin/env bash
    if [ "{{ quadlet }}" == "true" ] && [ -d "/var/home/{{ USER }}" ]; then
        echo "Configuring lingering for: {{ USER }}..."
        id -u secure-build >/dev/null 2>&1 || ( echo "run just builder::setup first" && exit 0)
        just create-container-cache {{ USER }}
        {{ auth }} loginctl enable-linger {{ USER }}
    fi
[arg('groups', multiple, short="g", long="group")]
[arg('homedir', short="d", long="create-homedir", value="true")]
[arg('quadlet', short="q", long="enable-quadlets", value="true")]
create-sys-user USER groups=[] homedir="" quadlet="" : (ensure-groups groups)
    #!/usr/bin/env bash
    # Convert space-separated group string to comma-separated list for useradd/usermod
    GROUP_LIST=$(echo "{{ groups }}" | tr ' ' ',')

    
    # Check if the user already exists
    if id -u "{{ USER }}" >/dev/null 2>&1; then
        echo "User '{{ USER }}' already exists."
        # Ensure existing user has all required supplementary groups appended
        if [ -n "$GROUP_LIST" ]; then
            echo "Updating supplementary groups for '{{ USER }}' ($GROUP_LIST)..."
            {{ auth_shell }} usermod -aG "$GROUP_LIST" "{{ USER }}"
        fi
        echo {{ homedir }}
        # Ensure home dir exists if user existed but home was missing
        if [ "{{ homedir }}" = "true" ] && [ ! -d "/var/home/{{ USER }}" ]; then
            echo "Creating missing home directory /var/home/{{ USER }}..."
            {{ auth }} mkdir -p "/var/home/{{ USER }}"
            {{ auth }} chown -R "{{ USER }}:{{ USER }}" "/var/home/{{ USER }}"
            just _restore-selinux {{ USER }}
            
        fi
        [ "{{ homedir }}" = "true" ] && just _setup-linger {{ quadlet }} {{ USER }} || true
        exit 0
    fi

    # User does not exist, assemble useradd arguments
    echo "Creating system user '{{ USER }}'..."
    args=("-r" "--shell" "/usr/sbin/nologin")
    
    if [ "{{ homedir }}" = "true" ]; then
        args+=("-m" "-d" "/var/home/{{ USER }}")
    fi
    if [ -n "$GROUP_LIST" ]; then
        args+=("-G" "$GROUP_LIST")
    fi
    echo "${args[@]}"
    {{ auth }} useradd "${args[@]}" "{{ USER }}"
    
    
    {{ auth }} systemd-sysusers || true
    # Ensure permissions on /var/home/{{ USER }} are explicitly owned by the user
    if [ "{{ homedir }}" = "true" ]; then
        {{ auth }} chown -R "{{ USER }}:{{ USER }}" "/var/home/{{ USER }}"
        just _create-build-cache {{ quadlet }} {{ USER }}
        just _restore-selinux {{ USER }}
        just _setup-linger {{ quadlet }} {{ USER }}
    fi

    
    
    


# Safely remove a system user, stop lingering systemd sessions, and delete home dir
[arg('remove_home', short="r", long="remove-home", value="true")]
delete-sys-user USER remove_home="true":
    #!/usr/bin/env bash
    if ! id -u "{{ USER }}" >/dev/null 2>&1; then
        echo "User '{{ USER }}' does not exist. Nothing to do."
        exit 0
    fi

    echo "Cleaning up user '{{ USER }}'..."

    # 1. Disable linger if active
    if loginctl show-user "{{ USER }}" >/dev/null 2>&1; then
        echo "Disabling linger for '{{ USER }}'..."
        {{ auth }} loginctl disable-linger "{{ USER }}" || true
    fi

    # 2. Terminate any remaining user processes / systemd --user instance
    echo "Terminating running processes for '{{ USER }}'..."
    {{ auth }} pkill -u "{{ USER }}" || true
    {{ auth }} loginctl terminate-user "{{ USER }}" || true

    # 3. Delete the user
    DEL_ARGS=()
    if [ "{{ remove_home }}" = "true" ]; then
        DEL_ARGS+=("-r")
    fi

    echo "Removing user account '{{ USER }}'..."
    {{ auth }} userdel "${DEL_ARGS[@]}" "{{ USER }}" || true

    # 4. Fallback cleanup for explicitly defined /var/home paths if userdel missed it
    if [ "{{ remove_home }}" = "true" ] && [ -d "/var/home/{{ USER }}" ]; then
        echo "Cleaning up residual home directory /var/home/{{ USER }}..."
        {{ auth }} rm -rf "/var/home/{{ USER }}"
    fi

    echo "User '{{ USER }}' deleted."
# Ensure vendor default groups are copied from /usr/lib/group to /etc/group, or created
[arg('groups', multiple, short="g", long="group")]
ensure-groups groups=[]:
    #!/usr/bin/env bash
    if [ -z "{{ groups }}" ]; then
        echo "No groups specified."
        exit 0
    fi

    for group in {{ groups }}; do
        # 1. Skip if already in /etc/group
        if grep -q "^${group}:" /etc/group 2>/dev/null; then
            echo "Group '${group}' already present in /etc/group."
            continue
        fi

        # 2. Try copying from /usr/lib/group (vendor default)
        if [ -f /usr/lib/group ] && grep -q "^${group}:" /usr/lib/group; then
            echo "Copying group '${group}' from /usr/lib/group to /etc/group..."
            grep "^${group}:" /usr/lib/group | {{ auth }} tee -a /etc/group > /dev/null
        # 3. Otherwise create brand new group
        else
            echo "Group '${group}' not found in /usr/lib/group. Creating with groupadd..."
            {{ auth }} groupadd "${group}"
        fi
    done



[arg('tcp', multiple, short="t", long="tcp-port")]
[arg('udp', multiple, short="u", long="udp-port")]
create-firewall-service NAME desc="Custom Firewall Service" tcp=[] udp=[]:
    #!/usr/bin/env bash
    echo "Configuring firewalld service: {{ NAME }}..."

    # Build XML port entries
    PORT_ENTRIES=""
    for port in {{ tcp }}; do
        PORT_ENTRIES+="  <port protocol=\"tcp\" port=\"${port}\"/>\n"
    done
    for port in {{ udp }}; do
        PORT_ENTRIES+="  <port protocol=\"udp\" port=\"${port}\"/>\n"
    done

    # Create service XML file
    {{ auth }} tee "/etc/firewalld/services/{{ NAME }}.xml" > /dev/null << EOF
    <?xml version="1.0" encoding="utf-8"?>
    <service>
      <short>{{ NAME }}</short>
      <description>{{ desc }}</description>
    $(echo -e "$PORT_ENTRIES")</service>
    EOF

    # Register and activate
    {{ auth }} firewall-cmd --reload
    {{ auth }} firewall-cmd --add-service={{ NAME }} --permanent
    {{ auth }} firewall-cmd --add-service={{ NAME }}

    echo "Service {{ NAME }} active in firewalld!"

create-container-cache user:
    echo "creating container store for {{ user }}"
    {{ auth }} mkdir -m 750 -p {{ container-store }}/{{ user }}
    {{ auth }} chown -R secure-build:{{ user }} {{ container-store }}/{{ user }}


# Stages the built image into an OCI dir and signs it with cosign against
# the PKCS11-backed key. Not shareable with other signing backends: cosign's
# digest handling and bundle format are specific to it.
[private]
[no-cd]
sign-cosign full_tag out-dir tag sign_priv_path=sign_priv:
    #!/usr/bin/env bash
    set -euo pipefail
    BUILD_POLICY=$(mktemp)
    trap 'rm -f "$BUILD_POLICY"' EXIT
    echo '{"default": [{"type": "insecureAcceptAnything"}]}' > "$BUILD_POLICY"

    SAFE_TAG_NAME=$(echo "{{ tag }}" | tr '/:' '_')
    BUNDLE_PATH="{{ out-dir }}/${SAFE_TAG_NAME}.bundle"
    TARGET_OCI_DIR="{{ out-dir }}/{{ tag }}"
    mkdir -p "$(dirname "$TARGET_OCI_DIR")"

    echo "==> Staging image to OCI dir..."
    skopeo copy \
        --policy "$BUILD_POLICY" \
        "containers-storage:{{ full_tag }}" \
        "oci:$TARGET_OCI_DIR"

    RAW_DIGEST=$(podman image inspect "{{ full_tag }}" --format '{{{{.Digest}}}}')
    ABS_TARGET_OCI_DIR=$(realpath "$TARGET_OCI_DIR")
    USERPIN=$(cat "{{ pkcs11_pin }}")

    echo "==> Signing image and producing Cosign bundle..."
    TPM2_PKCS11_STORE="{{ pkcs11_store }}" COSIGN_PASSWORD="$USERPIN" {{ cosign_exe }} sign \
        --yes \
        --key "pkcs11:token=secure-build;object=secure-build-signing;type=private" \
        --bundle "$BUNDLE_PATH" \
        --upload=false \
        "oci:${ABS_TARGET_OCI_DIR}@${RAW_DIGEST}"

    IMAGE_DIGEST=$(echo "$RAW_DIGEST" | tr ':' '=')
    SIG_STORE_DIR="/var/lib/containers/sigstore/@${IMAGE_DIGEST}"
    {{ auth }} mkdir -p "$SIG_STORE_DIR"
    {{ auth }} cp "$BUNDLE_PATH" "$SIG_STORE_DIR/signature-1"

# Stages and signs the built image in one step via skopeo's built-in
# --sign-by, using the TPM-backed GPG key enrolled in export-gpg-key.
# Uses `dir:` (not `oci:`) as the target — it's the transport with the
# well-established local signature-alongside-image behavior for this
# exact "no registry" pattern; verify `signature-1` actually lands next
# to manifest.json on your skopeo version before relying on it, and add
# an explicit registries.d lookaside pointing at this same path if it
# doesn't (registries.d/default.yaml: sigstore: file://{{ out-dir }}).
[private]
[no-cd]
sign-gpg full_tag out-dir tag signing_key_id_path=signing_key_id_path gnupg_home=gnupg_home:
    #!/usr/bin/env bash
    set -euo pipefail
    [ -f "{{ signing_key_id_path }}" ] || (echo "no enrolled GPG signing key found — run 'just enroll-key' or 'just setup' first" && exit 1)
    KEYID=$(cat "{{ signing_key_id_path }}")

    SAFE_TAG_NAME=$(echo "{{ tag }}" | tr '/:' '_')
    TARGET_DIR="{{ out-dir }}/${SAFE_TAG_NAME}"
    mkdir -p "$TARGET_DIR"

    echo "==> Staging and signing image (GPG key $KEYID)..."
    GNUPGHOME="{{ gnupg_home }}" skopeo copy \
        --sign-by "$KEYID" \
        "containers-storage:{{ full_tag }}" \
        "dir:$TARGET_DIR"

    ls "$TARGET_DIR"/signature-* > /dev/null 2>&1 \
        || echo "WARNING: no signature-* file found in $TARGET_DIR — check registries.d lookaside config"

# Modular helper to build and sign any container image with multi-value build-args
[arg('build-args', multiple, short="b", long="build-arg")]
[arg('out-dir', short="o", long="out-dir")]
[arg('dockerfile', short="f", long="dockerfile")]
[private]
[no-cd]
build-and-sign tag dockerfile="Dockerfile" build-args=[] out-dir="" extra_flags="" sign_recipe="sign-gpg":
    #!/usr/bin/env bash
    set -euo pipefail
    [ ! -z "{{ out-dir }}" ] && [ -d "{{ out-dir }}" ] || (echo "create target directory first" && exit 1)
    
    podman_args=()  
    STAGE_DIR=$(mktemp -d)
    BUILD_POLICY=$(mktemp)
    # Normalize tag to have localhost/ prefix to avoid docker.io short-name expansion in cosign
    FULL_TAG="localhost/$(echo "{{ tag }}" | sed -E 's|^localhost/||')"
    # Clean up both temporary files AND temporary staging directory properly
    trap 'rm -f "$BUILD_POLICY"; rm -rf "$STAGE_DIR"' EXIT

    for arg in {{ build-args }}; do
        if [ -n "$arg" ]; then
            podman_args+=("--build-arg" "$arg")
        fi
    done

    # Create transient policy file for build/copy operations
    echo '{"default": [{"type": "insecureAcceptAnything"}]}' > "$BUILD_POLICY"
    chown secure-build:secure-build $BUID_POLICY
    echo "==> Building container: {{ tag }}"
    IIDFILE=$(mktemp)
    chown secure-build:secure-build $IIDFILE
    podman build \
        --signature-policy "$BUILD_POLICY" \
        -f "{{ dockerfile }}" \
        -t "{{ tag }}" \
        "${podman_args[@]}" \
        {{ extra_flags }} \
        --iidfile "$IIDFILE" \
        .

    IMAGE_ID=$(cat "$IIDFILE" | sed 's/^sha256://')
    rm -f "$IIDFILE"

    just  {{ sign_recipe }} "$FULL_TAG" "{{ out-dir }}" "{{ tag }}"