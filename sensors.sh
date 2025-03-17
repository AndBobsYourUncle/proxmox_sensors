#!/bin/bash
# This script extracts sensor readings from the `sensors` command and system metadata,
# then publishes MQTT discovery/configuration messages for each sensor (with friendly names)
# and an aggregated state message for the device.
#
# Each sensor’s configuration payload is published to:
#   homeassistant/sensor/<dev_ids>/<component_id>/config
#
# In the configuration payload, the "~" key is set to the aggregated state topic,
# e.g. "proxmox_sensors/<dev_ids>", and "stat_t" is set to "~/telemetry".
#
# All sensor states are aggregated and published to:
#   proxmox_sensors/<dev_ids>/telemetry
#
# MQTT connection parameters are set below.

###########################
# MQTT CONFIGURATION
###########################
mqtt_host="mqtt.local" # Your MQTT broker host
mqtt_user="" # Optional: your MQTT username
mqtt_pass="" # Optional: your MQTT password
qos=2

# Build mosquitto_pub options.
mqtt_opts="-h ${mqtt_host}"
[ -n "$mqtt_user" ] && mqtt_opts="${mqtt_opts} -u ${mqtt_user}"
[ -n "$mqtt_pass" ] && mqtt_opts="${mqtt_opts} -P ${mqtt_pass}"

###########################
# EXTRACTION PHASE
###########################
declare -A device_adapter    # Maps device -> adapter type
declare -A device_reading    # Maps composite key "device:sensor" -> reading
declare -a sensor_keys       # Preserve sensor keys in order
devices=()                   # Preserve device order

# Global CPU core counter (per coretemp device)
cpu_core_counter=0

sensor_output=$(sensors)

# Regex for sensor reading lines:
#   ^[[:space:]]*                : optional leading whitespace
#   ([[:alnum:]_. -]+):           : sensor label ending with a colon
#   [[:space:]]+                 : one or more whitespace characters
#   (\+?[0-9]+(\.[0-9]+)?|N/A)    : numeric reading (optionally with a plus sign and decimal) or "N/A"
#   ([[:space:]]*C)?             : optional trailing whitespace and the letter "C"
regex_sensor='^[[:space:]]*([[:alnum:]_. -]+):[[:space:]]+(\+?[0-9]+(\.[0-9]+)?|N/A)([[:space:]]*C)?'

current_device=""
current_adapter=""

while IFS= read -r line; do
  trimmed=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ -z "$trimmed" ]; then
    current_device=""
    current_adapter=""
    continue
  fi
  # If the line is a device name (no colon, allowed characters)
  if [[ "$trimmed" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    current_device="$trimmed"
    devices+=("$current_device")
    # If this is a CPU sensor device, reset our CPU core counter.
    if [[ "$current_device" =~ coretemp-isa- ]]; then
       cpu_core_counter=1
    fi
    continue
  fi
  # Adapter extraction.
  if [[ "$trimmed" =~ ^Adapter:[[:space:]]*(.*) ]]; then
    current_adapter="${BASH_REMATCH[1]}"
    [ -n "$current_device" ] && device_adapter["$current_device"]="$current_adapter"
    continue
  fi
  # Sensor reading extraction.
  if [[ "$line" =~ $regex_sensor ]]; then
    sensor_label="${BASH_REMATCH[1]}"
    sensor_value="${BASH_REMATCH[2]}"
    sensor_value="${sensor_value#+}"  # Remove any leading '+'
    sensor_value=$(echo "$sensor_value" | tr -d '\n')
    # If this is a CPU sensor and the label begins with "Core", replace with our own counter.
    if [[ "$current_device" =~ coretemp-isa- ]] && [[ "$sensor_label" =~ ^[Cc]ore ]]; then
       sensor_label="Core ${cpu_core_counter}"
       cpu_core_counter=$((cpu_core_counter+1))
    fi
    key="${current_device}:${sensor_label}"
    device_reading["$key"]="$sensor_value"
    sensor_keys+=("$key")
  fi
done <<< "$sensor_output"

###########################
# SYSTEM INFO EXTRACTION
###########################
[ -f /etc/machine-id ] && dev_ids=$(cat /etc/machine-id) || dev_ids="unknown"
dev_name=$(hostname 2>/dev/null || echo "unknown")
[ -f /sys/class/dmi/id/sys_vendor ] && dev_mf=$(cat /sys/class/dmi/id/sys_vendor) || dev_mf="Unknown"
[ -f /sys/class/dmi/id/product_name ] && dev_mdl=$(cat /sys/class/dmi/id/product_name) || dev_mdl="Unknown"
dev_sw=$(uname -r)
if [ -r /sys/class/dmi/id/product_serial ] && [ -s /sys/class/dmi/id/product_serial ]; then
  dev_sn=$(cat /sys/class/dmi/id/product_serial)
else
  [ -f /etc/machine-id ] && dev_sn=$(cat /etc/machine-id) || dev_sn="Unknown"
fi
[ -f /sys/class/dmi/id/board_version ] && dev_hw=$(cat /sys/class/dmi/id/board_version) || dev_hw="Unknown"

###########################
# TOPIC PREFIX SETUP
###########################
# Configuration topics will be under:
#   homeassistant/sensor/<dev_ids>/<component_id>/config
config_topic_prefix="homeassistant/sensor/${dev_ids}"
# Aggregated device state topic:
device_state_topic="proxmox_sensors/${dev_ids}"

###########################
# DEVICE INFO FOR MQTT DISCOVERY
###########################
dev_json=$(cat <<EOF
{
  "ids": ["$dev_ids"],
  "name": "$dev_name",
  "sa": "Proxmox",
  "sw": "$dev_sw",
  "mf": "$dev_mf"
}
EOF
)

###########################
# FRIENDLY NAME MAPPING FUNCTION
###########################
# For CPU sensors, we simply extract the socket number from the device and use the already
# extracted sensor label (which is now "Core X"). For NVMe sensors, we extract the NVMe device
# number from the component id.
get_friendly_name() {
  local device="$1"    # e.g., coretemp-isa-0000, acpitz-acpi-0, iwlwifi_1-virtual-0
  local cid="$2"       # sanitized composite key
  local fallback="$3"  # fallback sensor label from extraction

  # CPU sensor logic
  if [[ "$device" =~ coretemp-isa-([0-9]{4}) ]]; then
    local socket_raw="${BASH_REMATCH[1]}"
    local socket_num=$((10#$socket_raw + 1))
    if [[ "$fallback" =~ [Pp]ackage ]]; then
      echo "CPU${socket_num} Pkg"
      return
    fi
    if [[ "$fallback" =~ ^[Cc]ore ]]; then
      # Assume the label is already renumbered in the extraction phase (e.g. "Core 1")
      echo "CPU${socket_num} ${fallback}"
      return
    fi
  fi

  # NVMe sensor logic
  local lc_cid=$(echo "$cid" | tr '[:upper:]' '[:lower:]')
  if [[ "$lc_cid" =~ nvme_pci_([0-9]{4}) ]]; then
    local raw_nvme="${BASH_REMATCH[1]}"
    local nvme_num=$((10#$raw_nvme / 100))
    if [[ "$fallback" =~ [Cc]omposite ]]; then
      echo "NVMe${nvme_num} Comp"
      return
    fi
    if [[ "$fallback" =~ ^[Ss]ensor ]]; then
      echo "NVMe${nvme_num} ${fallback}"
      return
    fi
    echo "NVMe${nvme_num}"
    return
  fi

  # ACPI sensor logic
  if [[ "$device" =~ acpitz-acpi-0 ]]; then
    # For ACPI sensors, typically the fallback is something like "temp1".
    echo "ACPI Temp"
    return
  fi

  # WiFi sensor logic
  if [[ "$device" =~ iwlwifi_.* ]]; then
    echo "WiFi Temp"
    return
  fi

  # Fallback: use the original sensor label.
  echo "$fallback"
}


###########################
# PUBLISH PER SENSOR
###########################
aggregated_state_payload="{"
first=1

for key in "${sensor_keys[@]}"; do
  # Composite key is "device:sensor_label"
  device_part=$(echo "$key" | cut -d: -f1)
  fallback_label=$(echo "$key" | cut -d: -f2-)
  component_id=$(echo "$key" | sed 's/[^a-zA-Z0-9]/_/g')
  sensor_value="${device_reading[$key]}"

  friendly_name=$(get_friendly_name "$device_part" "$component_id" "$fallback_label")

  config_payload=$(cat <<EOF
{
  "dev": $dev_json,
  "~": "$device_state_topic",
  "name": "$friendly_name",
  "uniq_id": "${dev_ids}_${component_id}",
  "avty_t": "~/status",
  "stat_t": "~/telemetry",
  "value_template": "{{ value_json.${component_id} }}",
  "entity_category": "diagnostic",
  "unit_of_meas": "°C"
}
EOF
)

  sensor_config_topic="${config_topic_prefix}/${component_id}/config"
  config_payload_oneline=$(echo "$config_payload" | tr -d '\n')
  mosquitto_pub $mqtt_opts -t "${sensor_config_topic}" -m "$config_payload_oneline" -q $qos

  if [ $first -eq 1 ]; then
    first=0
  else
    aggregated_state_payload="${aggregated_state_payload},"
  fi
  aggregated_state_payload="${aggregated_state_payload}\"${component_id}\":\"${sensor_value}\""

  echo "Published config to ${sensor_config_topic}:"
  echo "$config_payload" | jq .
  echo "--------------------------------"
done

aggregated_state_payload="${aggregated_state_payload}}"

state_payload_oneline=$(echo "$aggregated_state_payload" | tr -d '\n')
mosquitto_pub $mqtt_opts -t "${device_state_topic}/telemetry" -m "$state_payload_oneline" -q $qos
mosquitto_pub $mqtt_opts -t "${device_state_topic}/status" -m "online" -q $qos

echo "Published aggregated state to ${device_state_topic}/telemetry:"
echo "$aggregated_state_payload" | jq .
