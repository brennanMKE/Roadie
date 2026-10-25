#!/bin/zsh
# with-timeout.sh — run a command with a time limit; exit 124 if it ran out (GNU timeout's code). macOS has no
# `timeout`, so this uses it when present and perl's alarm otherwise. Used by run-tests-vm.sh --ui (#0200) so a
# prompt blocking the guest shows up as a timeout rather than a hang.
# Usage: scripts/with-timeout.sh SECONDS command [args…]
(( $# >= 2 )) || { print -u2 "usage: scripts/with-timeout.sh SECONDS command [args...]"; exit 2 }
if command -v timeout >/dev/null; then exec timeout "$@"; fi
exec perl -e '
  my $t = shift;
  my $pid = fork // die "fork: $!";
  if ($pid == 0) { setpgrp(0, 0); exec @ARGV or die "exec $ARGV[0]: $!" }
  local $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 5; kill "KILL", -$pid; waitpid $pid, 0; exit 124 };
  alarm $t;
  waitpid $pid, 0;
  exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
' "$@"
