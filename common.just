set unstable
set lists

os_id := shell('grep -E "^(ID|VARIANT_ID)=" /etc/os-release 2>/dev/null | tr "\n" " "')
# Auth will be run0 on secureblue (server) and sudo otherwise
auth := if os_id=~"secureblue" { "run0 --via-shell" } else { "sudo" }

# directory for the signing key for locally built containers
pki_dir := "/var/lib/secure-build/pki"
# the top-level directory for builds by the secure-build user
container-store := "/var/lib/secure-build/containers"

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


# standard location for container related pub keys
containers_pki_dir := "/etc/pki/containers"

# exported PEM for podman policy.json
sign_pem_link    := containers_pki_dir + "/secure-build.pem"  # exported PEM for policy.json

# podman's container policy
policy_path := "/etc/containers/policy.json"
# the location for configuration for the system users running quadlets
user_storage := ".config/containers/storage.conf"

# Private helper recipe to restore SELinux context safely
_restore-selinux USER:
    #!/usr/bin/env bash
    targetdir=$(getent passwd "{{ USER }}" | cut -d: -f6 || true)
    if [ -d "$targetdir" ] && command -v restorecon >/dev/null 2>&1; then
        echo "Applying SELinux security context to $targetdir..."
        {{ auth }} restorecon -R "$target_dir"
    fi
_setup-quadlet quadlet USER:
    #!/usr/bin/env bash
    if [ "{{ quadlet }}" == "true" ] && [ -d "/var/home/{{ USER }}" ]; then
        echo "Configuring quadlet service: {{ USER }}..."
        id -u secure-build >/dev/null 2>&1 || ( echo "run just builder::setup first" && exit 0)
        just create-container-cache {{ USER }}
        {{ auth }} loginctl enable-linger {{ USER }}
    fi
[arg('groups', multiple, short="g", long="group")]
[arg('homedir', short="d", long="create-homedir", value="true")]
[arg('quadlet', short="q", long="enable-quadlets", value="true")]
create-sys-user USER groups=[] homedir="" quadlet="" : 
    #!/usr/bin/env bash
    # Convert space-separated group string to comma-separated list for useradd/usermod
    GROUP_LIST=$(echo "{{ groups }}" | tr ' ' ',')

    
    # Check if the user already exists
    if id -u "{{ USER }}" >/dev/null 2>&1; then
        echo "User '{{ USER }}' already exists."
        # Ensure existing user has all required supplementary groups appended
        if [ -n "$GROUP_LIST" ]; then
            echo "Updating supplementary groups for '{{ USER }}' ($GROUP_LIST)..."
            {{ auth }} usermod -aG "$GROUP_LIST" "{{ USER }}"
        fi
        # Ensure home dir exists if user existed but home was missing
        if [ "{{ homedir }}" = "true" ] && [ -d "/var/home/{{ USER }}" ]; then
            echo "Creating missing home directory /var/home/{{ USER }}..."
            {{ auth }} mkdir -p "/var/home/{{ USER }}"
            {{ auth }} chown -R "{{ USER }}:{{ USER }}" "/var/home/{{ USER }}"
            just _restore-selinux {{ USER }}
            
        fi
        [ "{{ homedir }}" = "true" ] && just _setup-quadlet {{ quadlet }} {{ USER }} || true
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