#!/bin/sh
# Render the OCUDU 5G SA config set into a directory, replacing the placeholder
# with a real path:
#   @LOGDIR@   where the gNB and UE pcap files go
# gnb.yml lands in <OUTDIR>/ocudu-5gsa/, ue.conf in <OUTDIR>/srsue/, which is
# the layout run-5gsa-ocudu-ue.sh expects under CONFDIR. The scripts take their
# paths from the environment and are not rendered.
#
# Usage: config/render.sh <LOGDIR> <OUTDIR>
set -eu
[ $# -eq 2 ] || { sed -n '2,10p' "$0"; exit 1; }
logdir="$1"; out="$2"
src="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$out/ocudu-5gsa" "$out/srsue" "$logdir"
sed "s|@LOGDIR@|$logdir|g" "$src/gnb.yml" > "$out/ocudu-5gsa/gnb.yml"
sed "s|@LOGDIR@|$logdir|g" "$src/srsue/ue.conf" > "$out/srsue/ue.conf"
echo "rendered into $out"
grep -l "@LOGDIR@" "$out"/ocudu-5gsa/gnb.yml "$out"/srsue/ue.conf 2>/dev/null && { echo "placeholders left, check the files above"; exit 1; } || true
