#!/usr/bin/env bash
# Shared stand-in agent process for tests that need a live process whose
# executable name is an agent name. Sourced by the tests that need it.

# fm_fake_agent_link <path>
# Make <path> a stand-in agent binary whose executable name is its own basename.
# It is a SYMLINK to bash, never a copy (a copied platform binary fails code
# signing on macOS) and never a link to `sleep`: coreutils builds that ship one
# multicall binary refuse to run under a name that is not one of their utilities.
# bash runs under any name, so the kernel's recorded executable identity is the
# agent name. Run it with `<path> -c "$FM_FAKE_AGENT_HOLD"` so it stays alive.
# The hold blocks in bash's own `read` on a private FIFO opened read-write, so
# the fake never has a child process: killing it ends its whole process tree.
# A `sleep` child would survive its parent and keep the test's output pipe open
# until it expired, so a runner waiting for end-of-output would stall.
# shellcheck disable=SC2016 # the hold is a script for the fake's own bash, expanded there
export FM_FAKE_AGENT_HOLD='f=$(mktemp -u); mkfifo "$f"; exec 9<>"$f"; rm -f "$f"; read -r -t 900 -u 9 _; :'
fm_fake_agent_link() {
  local bash_bin
  bash_bin=$(command -v bash) || return 1
  ln -sf "$bash_bin" "$1"
}
