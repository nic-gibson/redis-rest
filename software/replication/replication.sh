#!/bin/bash

### WARNING: Stopping and starting replication will cause a full resync of the database. 

# This script set up replication between two Redis Enterprise clusters. If there is an explication between the
# the two it will remove it before creating the new one. 
# Usage: ./replication.sh <source> <target> <username> <password>

# Get the databases from a cluster 
function get_dbs () {
  local HOST="$1"
  local RESPONSE=$(curl -f -s "${HOST}/v1/bdbs" -H "Content-Type: application/json" -u "${USERNAME}:${PASSWORD}")

  if [ $? -ne 0 ]; then
    echo "Failed to connect to ${HOST}." 2>&1
    exit 1
  fi

  if [ -z "${RESPONSE}" ]; then
    echo "No databases found on ${HOST}." 2>&1
    exit 1
  fi

  echo "${RESPONSE}"
}



# Extract the info for a named database from a response 
function get_db_info () {
  local RESPONSE="$1"
  local DBNAME="$2"

  if [ -z "${RESPONSE}" ] || [ -z "${DBNAME}" ]; then
    echo "Response or DB name is empty." 2>&1
    exit 1
  fi

  local DBINFO=$(echo "${RESPONSE}" | jq -r ".[] | select(.name == \"${DBNAME}\")")
  if [ -z "${DBINFO}" ]; then
    echo "Database ${DBNAME} not found in the response." 2>&1
    exit 1
  fi

  echo "${DBINFO}"
}

 # Get a database endpoint from the db info (either internal or external, preferring internal)
function get_database_endpoint () {
  local DBINFO="$1"

  if [ -z "${DBINFO}" ]; then
    echo "Database info is empty." 2>&1
    exit 1
  fi

  local DNS_NAME=$(echo "${DBINFO}" | jq -r ".endpoints | .[] | select(.addr_type == \"internal\") | .dns_name")
  if [ -z "${DNS_NAME}" ]; then
    DNS_NAME=$(echo "${DBINFO}" | jq -r ".endpoints | .[] | select(.addr_type == \"external\") | .dns_name")
    if [ -z "${DNS_NAME}" ]; then
      echo "Endpoint not found." 2>&1
      exit 1
    fi
  fi

  echo "${DNS_NAME}"
}

# Get the database id from the db info 
function get_database_id () {
  local DBINFO="$1"

  if [ -z "${DBINFO}" ]; then
    echo "Database info is empty." 2>&1
    exit 1
  fi

  local DBID=$(echo "${DBINFO}" | jq -r ".uid")
  if [ -z "${DBID}" ]; then
    echo "Database ID not found in the database info." 2>&1
    exit 1
  fi

  echo "${DBID}"
}
 

# Get a database endpoint's port from the db info (either internal or external, preferring internal)
function get_database_port () {

  local DBINFO="$1"

  if [ -z "${DBINFO}" ]; then
    echo "Database info is empty." 2>&1
    exit 1
  fi

  local PORT=$(echo "${DBINFO}" | jq -r ".endpoints | .[] | select(.addr_type == \"internal\") | .port")
  if [ -z "${PORT}" ]; then
    PORT=$(echo "${DBINFO}" | jq -r ".endpoints | .[] | select(.addr_type == \"external\") | .port")
    if [ -z "${PORT}" ]; then
      echo "Port not found ." 2>&1
      exit 1
    fi
  fi

  echo "${PORT}"
  
}



# Get the admin password for a database from the db info
function get_database_password () {
  local DBINFO="$1"

  if [ -z "${DBINFO}" ]; then
    echo "Database info is empty." 2>&1
    exit 1
  fi

  local PASSWORD=$(echo "${DBINFO}" | jq -r ".authentication_admin_pass")
  if [ -z "${PASSWORD}" ]; then
    echo "Password not found in the database info." 2>&1
    exit 1
  fi

  echo "${PASSWORD}"
}

# Build a replication URL for a database 
function build_replication_url () {

  local DBINFO="$1"
  if [ -z "${DBINFO}" ]; then
    echo "Database info is empty." 2>&1
    exit 1
  fi

  local ENDPOINT=$(get_database_endpoint "${DBINFO}")
  local PORT=$(get_database_port "${DBINFO}") 
  local PASSWORD=$(get_database_password "${DBINFO}")
  
  echo "redis://admin:${PASSWORD}@${ENDPOINT}:${PORT}"
}


SOURCE=$1
TARGET=$2
USERNAME=$3
PASSWORD=$4
DBNAME=$5

# Check if jq is installed
if ! command -v jq &> /dev/null; then
  echo "jq is not installed. Please install jq to run this script." 2>&1
  exit 1
fi

# Check if curl is installed
if ! command -v curl &> /dev/null; then
  echo "curl is not installed. Please install curl to run this script." 2>&1
  exit 1
fi


if [ -z "${SOURCE}" ] || [ -z "${TARGET}" ] || [ -z "${USERNAME}" ] || [ -z "${PASSWORD}" ] || [ -z "${DBNAME}" ]; then
  echo "Usage: $0 <source> <target> <username> <password> <dbname>" 2>&1  
  exit 1
fi

echo Getting databases 2>&1
# Get the dbs on source cluster
SOURCE_DB_LIST=$(get_dbs "${SOURCE}")
# Get the dbs on target cluster
TARGET_DB_LIST=$(get_dbs "${TARGET}")


echo Parsing out ${DBNAME} 2>&1
# Get the database we need from each
SOURCE_DB=$(get_db_info "${SOURCE_DB_LIST}" "${DBNAME}")
TARGET_DB=$(get_db_info "${TARGET_DB_LIST}" "${DBNAME}")

echo Building replication URLs 2>&1
# Get a replication URL for each database
SOURCE_REP_URL=$(build_replication_url "${SOURCE_DB}")
TARGET_REP_URL=$(build_replication_url "${TARGET_DB}")


# If the source database is already a replication target for the new target, remove it. 
SOURCE_REPLICAS=$(echo "${SOURCE_DB}" | jq -r ".replica_sources | .[] | select(.uri == \"${TARGET_REP_URL}\")")

if [ -n "${SOURCE_REPLICAS}" ]; then
  echo "Removing existing replication target"
  NEWREPLICAS=$(echo "${SOURCE_DB}" | jq -r "{replica_sources: [.replica_sources[] | select(.uri != \"${TARGET_REP_URL}\")]}")
  curl -s -X PUT "${SOURCE}/v1/bdbs/$(get_database_id "${SOURCE_DB}")" -H "Content-Type: application/json" -u "${USERNAME}:${PASSWORD}" -d "${NEWREPLICAS}" > /dev/null
  if [ $? -ne 0 ]; then
    echo "Failed to remove existing replication target for ${DBNAME} on ${SOURCE}."
    exit 1
  fi
fi


# Add the new replication target. 
NEWREPLICAS=$(echo ${TARGET_DB} | jq -r "{\"replica_sources\": [.replica_sources[], {\"uri\": \"${SOURCE_REP_URL}\"}]}")

# curl -s -X POST "${TARGET}/v1/bdbs/$(get_database_id "${TARGET_DB}")" -H "Content-Type: application/json" -u "${USERNAME}:${PASSWORD}" -d "${NEWREPLICAS}"