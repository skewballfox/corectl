# Variables
pki_dir := "/etc/pki/containers"
primary_ctx := pki_dir + "/primary.ctx"
sign_ctx := pki_dir + "/tpm_sign.ctx"
container-store := "/var/lib/container-stores"

create-container-cache user:
    {{ auth }} mkdir -m 750 -p {{ container-store }}/{{ user }}
    chown -R secure-build:{{ user }} {{ container-store }}/{{ user }}