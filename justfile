
set dotenv-load := true
set allow-duplicate-variables

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

import? 'common.just'

# Service Modules
mod builder 'secure-build/builder.just'
mod wolf 'Wolf/wolf.just'
mod moonshine 'Wolf/moonshine.just'

setup-builder: builder::setup
setup-wolf: wolf::setup
setup-moonshine: moonshine::setup
