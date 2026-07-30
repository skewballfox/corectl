# CoreCtl

Just a collection of just recipes and configs for setting up various services on secureblue server

## Services

### secure-build

the goal is to create a dedicated user account for building containers for other system services. The built images would be signed and read only, and the default policy would be to reject unsigned images. I want to try to limit the amount of privilege the accounts and their containers actually need. The service accounts will rely entirely on locally stored images, and updates will be handled via the builder account. 

#### A few recipes

- `generate-key` set up a tpm backed key that is accessible only by root and the builder, totally fine if the key becomes unusable for any reason since it can be regenerated and is only used for local builds. 
- `create-container-cache <user>` create a set of output directories per system-user (eg. wolf, wolf-related quadlets), shared between the builder and the system user, but read only for the system user. 
- `enroll-key` : add the signing key to the list of trusted signatures for podman
- TODO: configure build schedule: still working out how this will look. I'd like the builds for various services (eg. wolf related containers), to be automatic. Perhaps a systemd timer that checks if a remote base image has been updated, then triggers the rebuild? 

### [Wolf](https://github.com/games-on-whales/wolf)

A set of containers for running wolf, a headless server for streaming games from a remote system. TODO: fill out the rest later