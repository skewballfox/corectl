
set dotenv-load := true
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

import 'common.just'

# Service Modules
mod builder 'secure-build/builder.just'
mod wolf 'Wolf/wolf.just'

setup-builder: builder::setup
setup-wolf: wolf::setup