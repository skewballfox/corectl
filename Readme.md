# CoreCtl

Just a collection of just recipes and configs for setting up various services on secureblue server

## Dependencies

nonexhaustive atm as I'm still adding and removing packages while I work out how to do this:

- buildah
- gnupg-pkcs11-scd
- tpm2-pkcs11
- tpm2-pkcs11-tools
- tpm2-abrmd (I think)

## Services

### secure-build

the goal is to create a dedicated user account for building containers for other system services. It is a member of the tss group to interact with the tpm, and does require enabling user namespaces in order to build images with buildah. The built images would be signed and read only for the downstream system users, and the default policy would be to reject unsigned images. I want to try to limit the amount of privilege the accounts and their containers actually need. The service accounts will rely entirely on locally stored images, and updates will be handled via the builder account. 

Once I flesh out the build pipeline I'm planning on making something that can work with [materia](https://github.com/stryan/materia). 

the recipes can probably be organized into 3 groups: those that are needed for gpg based image signing, those required for cosign based image signing and those needed for both (which are very few) or are otherwise independent of both paths. Right now, while the cosign path is mostly fleshed out, it's not going to work for my intended use case (signing local images with cosign without a registry isn't really a supported workflow), so I'd recommend sticking with gpg despite any jankiness for now.

#### A few recipes

- `builder::regenerate-key` set up a tpm backed key that is accessible only by root and the builder, totally fine if the key becomes unusable for any reason since it can be regenerated and is only used for local builds. 
- `create-container-cache <user>` create a set of output directories per system-user (eg. wolf, wolf-related quadlets), shared between the builder and the system user, but read only for the system user. 
- `enroll-key` : add the signing key to the list of trusted signatures for podman
- TODO: configure build schedule: still working out how this will look. I'd like the builds for various services (eg. wolf related containers), to be automatic. Perhaps a systemd timer that checks if a remote base image has been updated, then triggers the rebuild? 

### [Wolf](https://github.com/games-on-whales/wolf)

A set of containers for running wolf, a headless server for streaming games from a remote system. there are 3 images/quadlets, 1 for pulse, 1 for the nvidia driver, and one for wolf itself. Each quadlet has only the permissions required for it to function. TODO: fill out the rest later