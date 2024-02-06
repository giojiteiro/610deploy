#! /usr/bin/env bash

# Documentation
read -r -d '' usage_text << EOM
Usage: 610overlay.sh --config <configuration file> --overlay <environment name>
Overlays the configuration for the specific environment to the component.

Requires a folder called 'overlays' that can contain one folder per environment.

Each 'overlay/environment' folder should contain a file matching 'configuration file'
and this overlay file should contain the configuration values specific for that
environment.

Example:
Having the following files:
  ├── service-config.yml
  ├── overlays 
  │   ├── dev
  │   │   ├── service-config.yml
  │   ├── staging
  │   │   ├── service-config.yml
  │   ├── prod
  │   │   ├── service-config.yml

Running the command:
  610overlay.sh --config service-config.yml --overlay dev

Will take the configuration values from 'overlays/dev/service-config.yml' . to 
replace the matching configuration values from service-config.yml and output the
resulting file.

EOM

function log {
    MESSAGE=$1
    >&2 echo "$MESSAGE"
}

while [[ "$1" =~ ^- && ! "$1" == "--" ]]; do case $1 in
  -h | --help )
    echo "$usage_text"
    exit
    ;;
  -c | --config )
    shift; config=$1
    ;;
  -o | --overlay )
    shift; overlay=$1
    ;;
  -v | --verbose)
    verbose=1
    ;;
esac; shift; done
if [[ "$1" == '--' ]]; then shift; fi


if [[ ! -e "$config" ]]; then
  log "ERROR: Config file ${config} not found."
  exit 1
fi

config_name=${config##*/}
config_location=${config%$config_name}
overlay_file="${config_location}overlays/${overlay}/${config_name}"

if [[ "${verbose}" == 1 ]]; then
  log "Will overlay ${overlay_file} with config ${config}"
fi

if [[ ! -e "$overlay_file" ]]; then
    if [[ "${verbose}" == 1 ]]; then
      log "ERROR: Overlay file ${overlay_file} not found."
    fi
  cat ${config}
  exit
fi

yq eval-all '. as $item ireduce ({}; . * $item)' ${config} ${overlay_file}