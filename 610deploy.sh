#! /usr/bin/env bash

# Documentation
read -r -d '' USAGE_TEXT << EOM

Usage: 610deploy.sh <config file> [<options>]

Uses a specially formatted YAML config file to construct a 'gcloud <RESOURCE TYPE> <VERB>' command
with resource deployment parameters taken from the same config file.

NOTE: This script depends on the 'yq' tool installed locally.
      For instructions on how to install it please check: https://github.com/mikefarah/yq/#install

Availabe options:
  -h | --help: Shows this usage text
  -d | --dry-run: Do not run final gcloud command, only show it.
  -v | --verbose: Verbose output

EOM

set -eo pipefail

# Print message on stderr so stdout can be used as input to other commands.
function log {
    MESSAGE=$1
    >&2 echo "$MESSAGE"
}

# Print error message and exit program with status code 1
function fail {
    MESSAGE=$1
    log "ERROR: $MESSAGE"
    exit 1
}

# Return a key=value pair from the yaml config formatted as a parameter for command
function to_param() {
  local PREFIX=$1
  local CF_VALUE=${2%$'\n'}

  CF_VALUE="${CF_VALUE/: /=}"

  # 'description' flag needs its value quoted to allow space-separated words
  if [[ ${CF_VALUE} =~ ^description || ${CF_VALUE} =~ ^schedule || ${CF_VALUE} =~ ^message-body ]]; then
    IFS='=' read -ra desc <<< "$CF_VALUE"
    CF_VALUE="${desc[0]}='${desc[1]}'"    
  fi

  # If config value is in the form 'key: true' make it just 'key'.
  # Necessary for flags that don't take values
  if [[ "${CF_VALUE}" =~ =true$ ]]; then
    CF_VALUE=${CF_VALUE%=true}
  fi

  echo -n "${PREFIX}$CF_VALUE"
}

# Parses command options that take multiple values as parameter
# Returns the string --option=KEY1=VALUE1,KEY2=VALUE2..
function parse_multivalue() {
  local SECTION=$1
  local FLAG=$2
  export FILTER=".${SECTION}.${FLAG}"
  local STR_MULTIVALUE=''

  readarray MULTIVALUE < <(yq '... comments="" | eval(strenv(FILTER))' $CONFIG_FILE)

  if [[ ! "${MULTIVALUE[*]}" =~ null ]]; then
    VALUES=$(to_param '' "${MULTIVALUE[0]}")

    if [[ ${#MULTIVALUE[@]} -ge 1 ]]; then
      for ((i=1 ;  i < ${#MULTIVALUE[@]} ; i++)); do
        VALUE=$(to_param '' "${MULTIVALUE[$i]}")
        VALUES="${VALUES},${VALUE}"
      done
    fi
    STR_MULTIVALUE="--${FLAG}=${VALUES}"
  else
    if [[ "$VERBOSE" == "true" ]]; then
      log "No configuration defined for flag $FLAG in section $SECTION ($FILTER)"
    fi
  fi
  echo -n "${STR_MULTIVALUE}"
}

# Checks resource existence to return boolean
function resource_exists() {
  if gcloud $G_RESOURCE describe ${RESOURCE_NAME} ${PRV} >/dev/null 2>&1; then
    if [[ "$VERBOSE" == "true" ]]; then
      log "Resource exists"
    fi
    echo 'true'
  else
    if [[ "$VERBOSE" == "true" ]]; then
      log "Resource Does NOT exist"
    fi
    echo 'false'
  fi
}

# Returns the right string for the resource creation/update according to G_RESOURCE
function get_verb() {
  local IDEMPOTENTS=('endpoints' 'functions' 'run' 'workflows')
  local EXISTS=''
  if [[ ${IDEMPOTENTS[@]} =~ "${G_RESOURCE}" ]]; then
    echo "deploy"
    return 0
  fi

  EXISTS=$(resource_exists)

  if [[ ${G_RESOURCE} == 'pubsub schemas' ]]; then
    if [[ ${EXISTS} == 'true' ]]; then
      echo "commit"
    else
      echo "create"
    fi
    return 0
  fi

  if [[ ${EXISTS} == 'true' ]]; then
    echo "update $RESOURCE_SUBTYPE"
  else
    echo "create $RESOURCE_SUBTYPE"
  fi
  return 0
}

# Returns a string with the resorce_type.provider arguments from the config file
function get_provider() {
  local STR_PROVIDER=''

  readarray PRV_ARGS < <(yq "... comments=\"\" | .$RESOURCE_TYPE.provider" $CONFIG_FILE)

  if [[ ! "${PRV_ARGS[*]}" =~ null ]]; then
    for i in "${PRV_ARGS[@]}"; do
      PARAM=$(to_param '--' "$i")
      STR_PROVIDER="$STR_PROVIDER $PARAM"
    done
  fi

  echo "$STR_PROVIDER"
}

# Return a string with the resorce_type.config arguments from the config file
function get_config() {
  local STR_CONFIG=''

  # Get config keys for single flags
  readarray SINGLES < <(yq ".$RESOURCE_TYPE.config" $CONFIG_FILE | yq '. as $d | keys | .[] | select(. as $k | ( $d | .[$k] | select(tag!="!!map")))')

  for flag in "${SINGLES[@]}"; do

    if [[ ${G_RESOURCE} == 'eventarc triggers' && ${VERB} =~ update && ${flag} =~ ^transport-topic ]]; then
      continue
    fi

    export flag=$(echo $flag |tr -d '\n')
    value=$(yq ".$RESOURCE_TYPE.config.[strenv(flag)]" $CONFIG_FILE)

    PARAM=$(to_param '--' "${flag}: $value")
    STR_CONFIG="$STR_CONFIG $PARAM"
  done

  # Multivalue flags need special processing, so get the list of multivalue entries
  readarray MULTIS < <(yq ".$RESOURCE_TYPE.config" $CONFIG_FILE | yq '. as $d | keys | .[] | select(. as $k | ( $d | .[$k] | select(tag=="!!map")))')

  for m_flag in "${MULTIS[@]}"; do
    m_flag=$(echo $m_flag |tr -d '\n')
    PARAM=$(parse_multivalue "${RESOURCE_TYPE}.config" "$m_flag")
    STR_CONFIG="$STR_CONFIG $PARAM"
  done

  echo "$STR_CONFIG"
}

# "main" part of the script
CONFIG_FILE=$1; shift
VERBOSE='false'
NO_RUN='false'

#-- Initial validations
if [[ ! -e $CONFIG_FILE ]]; then
  fail "Config file $CONFIG_FILE not found"
fi

if ! which yq >/dev/null; then
  fail "yq command NOT found."
fi

# To support YAML keys with special characters in yq, the keys need to be formated like ["this works"]
G_RESOURCE=$(yq 'keys | .[]' $CONFIG_FILE)
printf -v RESOURCE_TYPE '["%s"]' "$G_RESOURCE"

# Beginning of command
CMD='gcloud'
VARIANT=$(yq ".$RESOURCE_TYPE.command-variant" $CONFIG_FILE)
if [[ ! "$VARIANT" =~ null ]]; then
  CMD="$CMD $VARIANT"
fi

#Take RESOURCE_TYPE name from config file
RESOURCE_NAME=$(yq ".$RESOURCE_TYPE.name" $CONFIG_FILE )
if [[ "$RESOURCE_NAME" =~ null ]]; then
  fail "Config file MUST define the ${G_RESOURCE} name in the ${G_RESOURCE}.name key in the configuraton file."
fi

RESOURCE_SUBTYPE=$(yq ".$RESOURCE_TYPE.subtype" $CONFIG_FILE )
if [[ "$RESOURCE_SUBTYPE" =~ null ]]; then
  RESOURCE_SUBTYPE=''
fi

while [[ "$1" =~ ^- && ! "$1" == "--" ]]; do case $1 in
  -h | --help )
    echo "$USAGE_TEXT"
    exit 0
    ;;
  -v | --verbose )
    VERBOSE='true'
    ;;
  -d | --dry-run )
    NO_RUN='true'
    ;;
  * )
    fail "Unknown command $1"
    ;;
esac; shift; done
if [[ "$1" == '--' ]]; then shift; fi

if [[ "$VERBOSE" == "true" ]]; then
  log "Handling deployment of Google Cloud ${G_RESOURCE} named '${RESOURCE_NAME}'"
fi

PRV=$(get_provider)

if [[ -z "$VERB" ]]; then
  VERB=$(get_verb)
fi

CFG=$(get_config)

# Some commands use different flags between create and update
# here is were we handle this.
if [[ "$RESOURCE_TYPE" =~ scheduler ]]; then
  if [[ "$VERB" =~ update ]]; then
    if [[ "$CFG" =~ --headers= ]]; then
      CFG=${CFG//--headers=/--update-headers=}
    fi
  fi
fi

CMD="${CMD} ${G_RESOURCE} ${VERB} ${RESOURCE_NAME} ${PRV} ${CFG}"

# Command prepared - show on verbose
if [[ "${VERBOSE}" == "true" || "$NO_RUN" == "true" ]]; then
  echo "About to run:"
  echo "${CMD}"
fi

# Proceed with execution if enabled
if [[ "${NO_RUN}" == "false" ]]; then
  eval "${CMD}"
fi
