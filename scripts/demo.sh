#!/bin/bash
# Remote control for the simulator demo.
#   demo.sh start                 fresh install state with a demo Goa trip
#   demo.sh say "text"            types the text into the agent box and sends it
#   demo.sh apply|ignore|undo|check
#   demo.sh map|chat|home
#   demo.sh scroll top|agent|days|live|feed
#   demo.sh goto <place>|clear     move the simulator's GPS (see goto.sh list)
SIM=${SIM:-booted}
BUNDLE=com.advaitandhale.travelagent
url() { xcrun simctl openurl "$SIM" "travelagent://$1"; }
case "$1" in
  start) xcrun simctl launch --terminate-running-process "$SIM" $BUNDLE -resetData -demoTrip >/dev/null ;;
  say) url "say?text=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$2")" ;;
  map|chat) url close; sleep 0.4; url "$1" ;;
  home) url close ;;
  scroll) url close; sleep 0.3; url "scroll?to=$2" ;;
  goto)
    if [ "$2" = clear ]; then xcrun simctl location "$SIM" clear; exit; fi
    line=$(grep -E "^ *$2\)" "$(dirname "$0")/goto.sh")
    lat=$(echo "$line" | sed -nE 's/.*LAT=([0-9.]+).*/\1/p'); lon=$(echo "$line" | sed -nE 's/.*LON=([0-9.]+).*/\1/p')
    [ -z "$lat" ] && { echo "Unknown place: $2"; exit 1; }
    xcrun simctl location "$SIM" set "$lat,$lon" ;;
  *) url "$1" ;;
esac
