#!/usr/bin/env bash
ROOT=$PWD
. "$ROOT/tests/lib.sh"
T=$(mktemp -d /tmp/fm-live.XXXXXX)
TA=$(command -v tasks-axi)
mk(){ h=$T/$1; mkdir -p $h/data $h/state $h/config $h/projects; cp $ROOT/.tasks.toml $h/.tasks.toml
 printf '## In flight\n\n## Queued\n\n## Done\n' > $h/data/backlog.md
 fb=$(fm_fakebin $h); fm_fake_exit0 $fb tmux treehouse no-mistakes gh gh-axi; echo $h; }
run(){ h=$1; shift; PATH="$h/fakebin:$PATH" REAL_TASKS_AXI="$TA" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" FM_CONFIG_OVERRIDE="$h/config" "$@"; }
x(){ echo "\$ $*" | sed "s#$T#\$HOME_FX#g"; run "$@"; echo "[exit $?]"; }
hold(){ run $1 $ROOT/bin/fm-captain-hold.sh hold $2 --title "t $2" --repo sample --reason "pending" >/dev/null; }
ans(){ echo "$3" > $1/a-$2.txt; x $1 $ROOT/bin/fm-captain-hold.sh answer $2 --decision-file $1/a-$2.txt; }
A=$ROOT/bin/fm-ask.sh
echo "=== S1 ==="; h=$(mk s1); for i in a b c; do hold $h id-$i; done
x $h $A round-start; x $h $A present id-a id-b; ans $h id-a North; ans $h id-b East
x $h $A inventory; x $h $A present id-c
echo "=== S2 ==="; h=$(mk s2); for i in a b; do hold $h id-$i; done
x $h $A round-start; x $h $A present id-a; x $h $A present id-b
echo "=== S3 ==="; h=$(mk s3); for i in 1 2 3 4 5; do hold $h id-$i; done
x $h $A round-start; x $h $A present id-1 id-2 id-3 id-4
h=$(mk s3b); for i in 1 2 3 4 5; do hold $h id-$i; done
x $h $A round-start; x $h $A present id-1 id-2 id-3 id-4 id-5; cat $h/state/.ask-presented 2>/dev/null | wc -l
rm -rf $T
