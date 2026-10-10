#!/bin/bash
# Teleports the connected iPhone to a place on the Goa itinerary (simulated GPS) to test
# location-aware features and geofence arrive/leave triggers.
#   ./scripts/goto.sh baga-beach     ./scripts/goto.sh list     ./scripts/goto.sh clear (back to real GPS)
DEVICE="${DEVICE:-00008030-001A29163C23402E}"

case "$1" in
  calangute)   LAT=15.5439; LON=73.7553 ;;  # Arrive & check in / Calangute Beach
  infantaria)  LAT=15.5447; LON=73.7621 ;;  # Breakfast at Infantaria
  souza-lobo)  LAT=15.5410; LON=73.7570 ;;  # Seafood lunch
  baga-beach)  LAT=15.5553; LON=73.7517 ;;  # Sunset at Baga
  titos)       LAT=15.5557; LON=73.7533 ;;  # Dinner & Tito's Lane
  anjuna)      LAT=15.5770; LON=73.7400 ;;  # Artjuna breakfast
  chapora)     LAT=15.6060; LON=73.7360 ;;  # Chapora Fort
  vagator)     LAT=15.5980; LON=73.7380 ;;  # Vagator Beach
  thalassa)    LAT=15.6007; LON=73.7362 ;;  # Lunch at Thalassa
  ashwem)      LAT=15.6650; LON=73.7110 ;;  # Ashwem chill
  panaji)      LAT=15.4960; LON=73.8270 ;;  # Dinner in Panjim / Café Bhonsle / Viva Panjim
  fontainhas)  LAT=15.4980; LON=73.8320 ;;  # Fontainhas walk
  old-goa)     LAT=15.5009; LON=73.9116 ;;  # Basilica of Bom Jesus
  miramar)     LAT=15.4800; LON=73.8070 ;;  # Miramar Beach
  mapusa)      LAT=15.5900; LON=73.8100 ;;  # Mapusa Market
  clear)
    xcrun devicectl device simulate location clear --device "$DEVICE"; exit $? ;;
  list|"")
    grep -E '^ +[a-z-]+\).*# ' "$0" | sed -E 's/^ +([a-z-]+)\).*# (.*)/  \1 — \2/'; exit 0 ;;
  *) echo "Unknown place '$1'. Try: $0 list"; exit 1 ;;
esac

xcrun devicectl device simulate location coordinate --device "$DEVICE" --latitude "$LAT" --longitude "$LON"
