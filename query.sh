#!/usr/bin/env bash

# Enable colorized output when supported.
COLOR_RESET=""
COLOR_INFO=""
COLOR_EMPH=""
COLOR_ERROR=""

if [[ -t 1 || -t 2 ]]; then
  COLOR_RESET=$'\033[0m'
fi

if [[ -t 1 ]]; then
  COLOR_INFO=$'\033[36m'
  COLOR_EMPH=$'\033[33m'
fi

if [[ -t 2 ]]; then
  COLOR_ERROR=$'\033[31m'
fi

print_error() {
  printf '%s\n' "${COLOR_ERROR}$*${COLOR_RESET}" >&2
}

print_label_value() {
  local label=$1
  local value=$2
  printf '%s%s:%s %s%s%s\n' "${COLOR_INFO}" "$label" "${COLOR_RESET}" "${COLOR_EMPH}" "$value" "${COLOR_RESET}"
}

open_map_url() {
  local lat=$1
  local lon=$2
  local url="http://www.google.com/maps/place/${lat},${lon}"
  print_label_value "Opening Maps" "$url"
  open "$url" >/dev/null 2>&1 || true
}

usage() {
  cat <<'EOF'
Usage: apple_bssid_locator.sh [-m|--map] [-a|--all] <bssid>
  -h, --help  Show this help message
  -a, --all   Print every BSSID Apple returns instead of just the requested one
  -m, --map   Open the resolved coordinate(s) in Google Maps (macOS "open")
EOF
}
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    print_error "Error: missing required command '$1'"
    exit 1
  fi
}

normalize_bssid() {
  local raw=${1//-/:}
  raw=$(printf '%s' "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  IFS=':' read -r p0 p1 p2 p3 p4 p5 <<<"$raw"
  local parts=("$p0" "$p1" "$p2" "$p3" "$p4" "$p5")
  local normalized=""

  for part in "${parts[@]}"; do
    if [[ -z "$part" || ! "$part" =~ ^[0-9a-f]{1,2}$ ]]; then
      return 1
    fi
    if ((${#part} == 1)); then
      part="0$part"
    fi
    if [[ -z "$normalized" ]]; then
      normalized="$part"
    else
      normalized="$normalized:$part"
    fi
  done

  printf '%s' "$normalized"
}

# Serialize an integer as a protobuf varint into stdout.
write_varint() {
  local value=$1
  while :; do
    local byte=$(( value & 0x7F ))
    value=$(( value >> 7 ))
    if (( value > 0 )); then
      byte=$(( byte | 0x80 ))
    fi
    printf "\\$(printf '%03o' "$byte")"
    (( value == 0 )) && break
  done
}

TWO_63=""
TWO_64=""
BYTES=()
BYTES_COUNT=0
INDEX=0
LOCATION_LAT=""
LOCATION_LON=""
VARINT_RESULT=""
STRING_RESULT=""

init_varint_limits() {
  if [[ -n "$TWO_63" && -n "$TWO_64" ]]; then
    return
  fi
  TWO_63=$(echo '2^63' | bc)
  TWO_64=$(echo '2^64' | bc)
}

# Decode a protobuf varint from BYTES into VARINT_RESULT.
read_varint() {
  local result="0"
  local multiplier="1"
  local byte low
  while :; do
    if (( INDEX >= BYTES_COUNT )); then
      VARINT_RESULT="$result"
      return 0
    fi
    byte=${BYTES[INDEX]}
    INDEX=$((INDEX + 1))
    low=$(( byte & 0x7F ))
    if (( low != 0 )); then
      result=$(echo "$result + $low * $multiplier" | bc)
    fi
    if (( (byte & 0x80) == 0 )); then
      VARINT_RESULT="$result"
      return 0
    fi
    multiplier=$(echo "$multiplier * 128" | bc)
  done
}

skip_value() {
  local wire=$1
  case $wire in
    0)
      read_varint
      ;;
    1)
      INDEX=$((INDEX + 8))
      ;;
    2)
      local len
      read_varint
      len=$((VARINT_RESULT))
      if (( INDEX + len > BYTES_COUNT )); then
        INDEX=$BYTES_COUNT
      else
        INDEX=$((INDEX + len))
      fi
      ;;
    5)
      INDEX=$((INDEX + 4))
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

read_bytes_as_string() {
  local len=$1
  local str=""
  local i byte char
  local -a bytes=()
  for ((i=0; i<len && INDEX < BYTES_COUNT; i++)); do
    byte=${BYTES[INDEX]}
    INDEX=$((INDEX + 1))
    char=$(printf '%b' "\\$(printf '%03o' "$byte")")
    str+="$char"
    bytes+=("$byte")
  done
  
  # Prefer printable colon-delimited MACs when present, otherwise format raw bytes.
  if [[ $str == *:* ]] && [[ $str =~ ^[0-9A-Fa-f:]+$ ]]; then
    STRING_RESULT="$str"
    return
  fi

  local formatted=""
  for byte in "${bytes[@]}"; do
    printf -v part '%02x' "$byte"
    if [[ -z "$formatted" ]]; then
      formatted="$part"
    else
      formatted+=":$part"
    fi
  done
  STRING_RESULT="$formatted"
}

varint_to_signed() {
  local value=$1
  init_varint_limits
  if [[ -z "$value" ]]; then
    printf '%s' "0"
    return
  fi
  local cmp
  cmp=$(echo "$value >= $TWO_63" | bc)
  if [[ "$cmp" -eq 1 ]]; then
    value=$(echo "$value - $TWO_64" | bc)
  fi
  printf '%s' "$value"
}

format_coordinate() {
  local raw=$1
  local scaled
  scaled=$(echo "scale=8; $raw / 100000000" | bc)
  if [[ $scaled == .* ]]; then
    scaled="0$scaled"
  elif [[ $scaled == -* ]]; then
    local trimmed=${scaled#-}
    if [[ $trimmed == .* ]]; then
      scaled="-0$trimmed"
    fi
  fi
  printf '%s' "$scaled"
}

parse_location() {
  local loc_end=$1
  local lat=""
  local lon=""
  while (( INDEX < loc_end )); do
    local key=${BYTES[INDEX]}
    INDEX=$((INDEX + 1))
    local field=$(( key >> 3 ))
    local wire=$(( key & 0x07 ))
    case $field in
      1)
        read_varint
        lat=$(varint_to_signed "$VARINT_RESULT")
        ;;
      2)
        read_varint
        lon=$(varint_to_signed "$VARINT_RESULT")
        ;;
      *)
        skip_value "$wire" || { INDEX=$loc_end; break; }
        ;;
    esac
  done
  LOCATION_LAT="$lat"
  LOCATION_LON="$lon"
}

RESULT_MACS=()
RESULT_LATS=()
RESULT_LONS=()

# Extract a wifi device block and append coordinates if valid.
parse_wifi_device() {
  local device_end=$1
  local device_bssid=""
  local lat=""
  local lon=""
  while (( INDEX < device_end )); do
    local key=${BYTES[INDEX]}
    INDEX=$((INDEX + 1))
    local field=$(( key >> 3 ))
    local wire=$(( key & 0x07 ))
    case $field in
      1)
        local len
        read_varint
        len=$((VARINT_RESULT))
        read_bytes_as_string "$len"
        if [[ -z "$device_bssid" ]]; then
          device_bssid="$STRING_RESULT"
        fi
        ;;
      2)
        local len
        read_varint
        len=$((VARINT_RESULT))
        local loc_end=$((INDEX + len))
        if (( loc_end > BYTES_COUNT )); then
          loc_end=$BYTES_COUNT
        fi
        parse_location "$loc_end"
        INDEX=$loc_end
        lat=$LOCATION_LAT
        lon=$LOCATION_LON
        ;;
      *)
        skip_value "$wire" || { INDEX=$device_end; break; }
        ;;
    esac
  done

  if [[ -n "$device_bssid" && -n "$lat" && -n "$lon" ]]; then
    if [[ "$lat" == "-18000000000" && "$lon" == "-18000000000" ]]; then
      return
    fi
    local normalized
    if normalized=$(normalize_bssid "$device_bssid"); then
      local lat_dec lon_dec
      lat_dec=$(format_coordinate "$lat")
      lon_dec=$(format_coordinate "$lon")
      RESULT_MACS+=("$normalized")
      RESULT_LATS+=("$lat_dec")
      RESULT_LONS+=("$lon_dec")
    fi
  fi
}

# Walk the AppleWLoc message and visit each wifi device.
parse_response() {
  local file=$1
  BYTES=()
  while IFS= read -r byte; do
    [[ -z "$byte" ]] && continue
    BYTES+=("$byte")
  done < <(od -An -t u1 -v "$file" | awk '{for(i=1;i<=NF;i++) print $i}')

  BYTES_COUNT=${#BYTES[@]}
  INDEX=0

  while (( INDEX < BYTES_COUNT )); do
    local key=${BYTES[INDEX]}
    INDEX=$((INDEX + 1))
    local field=$(( key >> 3 ))
    local wire=$(( key & 0x07 ))
    case $field in
      2)
        local len
        read_varint
        len=$((VARINT_RESULT))
        local device_end=$((INDEX + len))
        if (( device_end > BYTES_COUNT )); then
          device_end=$BYTES_COUNT
        fi
        parse_wifi_device "$device_end"
        INDEX=$device_end
        ;;
      *)
        skip_value "$wire" || break
        ;;
    esac
  done
}

MAP_FLAG=0
ALL_FLAG=0
MAP_OPENED=0
BSSID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--all)
      ALL_FLAG=1
      shift
      ;;
    -m|--map)
      MAP_FLAG=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      print_error "Error: unknown option '$1'"
      usage
      exit 1
      ;;
    *)
      if [[ -n "$BSSID" ]]; then
        print_error "Error: multiple BSSIDs provided"
        usage
        exit 1
      fi
      BSSID="$1"
      shift
      ;;
  esac
done

if [[ -z "$BSSID" ]]; then
  print_error "Error: missing required BSSID argument"
  usage
  exit 1
fi

if ! formatted_input=$(normalize_bssid "$BSSID"); then
  print_error "Error: invalid BSSID '$BSSID'"
  exit 1
fi

require_cmd curl
require_cmd awk
require_cmd tail
require_cmd tr
require_cmd od
require_cmd bc

req_tmp=$(mktemp)
body_tmp=$(mktemp)
device_tmp=$(mktemp)
resp_tmp=$(mktemp)
resp_body_tmp=$(mktemp)
trap 'rm -f "$req_tmp" "$body_tmp" "$device_tmp" "$resp_tmp" "$resp_body_tmp"' EXIT

bssid_len=${#formatted_input}

{
  printf '\x0a'
  write_varint "$bssid_len"
  printf '%s' "$formatted_input"
} > "$device_tmp"

device_len=$(wc -c < "$device_tmp")

{
  printf '\x12'
  write_varint "$device_len"
  cat "$device_tmp"
  printf '\x18\x00'
  printf '\x20\x01'
} > "$body_tmp"

body_len=$(wc -c < "$body_tmp")
if (( body_len <= 0 || body_len > 255 )); then
  print_error "Error: unexpected request length $body_len (expected 1-255)"
  exit 1
fi

{
  printf '\x00\x01\x00\x05en_US\x00\x13com.apple.locationd\x00\x0a8.1.12B411\x00\x00\x00\x01\x00\x00\x00'
  printf "\\$(printf '%03o' "$body_len")"
  cat "$body_tmp"
} > "$req_tmp"

print_label_value "Searching for location of BSSID" "$BSSID"
curl -sS --fail \
  -H 'User-Agent: locationd/1753.17 CFNetwork/889.9 Darwin/17.2.0' \
  --data-binary @"$req_tmp" \
  https://gs-loc.apple.com/clls/wloc \
  -o "$resp_tmp"

if [[ ! -s "$resp_tmp" ]]; then
  print_error "Error: empty response from Apple WLOC endpoint"
  exit 1
fi

tail -c +11 "$resp_tmp" > "$resp_body_tmp"

RESULT_MACS=()
RESULT_LATS=()
RESULT_LONS=()
parse_response "$resp_body_tmp"

result_count=${#RESULT_MACS[@]}
if (( result_count == 0 )); then
  print_error "The BSSID was not found."
  exit 1
fi

if (( ALL_FLAG )); then
  for ((i=0; i<result_count; i++)); do
    mac=${RESULT_MACS[i]}
    lat=${RESULT_LATS[i]}
    lon=${RESULT_LONS[i]}
    print_label_value "BSSID" "$mac"
    print_label_value "Latitude" "$lat"
    print_label_value "Longitude" "$lon"
    if (( MAP_FLAG && MAP_OPENED == 0 )); then
      open_map_url "$lat" "$lon"
      MAP_OPENED=1
    fi
    if (( i < result_count - 1 )); then
      printf '\n'
    fi
  done
else
  target=$(normalize_bssid "$BSSID")
  found=0
  for ((i=0; i<result_count; i++)); do
    mac=${RESULT_MACS[i]}
    lat=${RESULT_LATS[i]}
    lon=${RESULT_LONS[i]}
    if [[ "$mac" == "$target" ]]; then
      print_label_value "BSSID" "$mac"
      print_label_value "Latitude" "$lat"
      print_label_value "Longitude" "$lon"
      if (( MAP_FLAG )); then
        open_map_url "$lat" "$lon"
      fi
      found=1
      break
    fi
  done
  if (( ! found )); then
    printf '%sThe BSSID was not found.%s\n' "${COLOR_ERROR}" "${COLOR_RESET}"
    exit 1
  fi
fi