#!/usr/bin/env bash
# The one definition of the prefix on the key of the queue wait bin/fm-build-lock.sh
# logs into a worker's status file. The lock builds its key from it and
# bin/fm-classify-lib.sh recognises the lock's own wait by it, so the two cannot
# drift. Kept apart from both so neither has to load the other to read it.
FM_BUILD_LOCK_WAIT_KEY_PREFIX='build-lock-'
