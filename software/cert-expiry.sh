#!/bin/bash

# This script extracts the expiry dates from the certificates in a Redis cluster 
# Usage: ./replication.sh <cluster.fqdn>  <username> <password>

declare -a CERT_TYPES=("cm" "proxy" "metrics_exporter" "api" "syncer")

# Get the certificates databases from a cluster 
function get_certificates {
  local HOST="$1"
  local RESPONSE 
  
  if ! RESPONSE=$(curl -f -s "${HOST}/v1/cluster/certificates" -H "Content-Type: application/json" -u "${USERNAME}:${PASSWORD}"); then
    echo "Failed to connect to ${HOST}." 2>&1
    exit 1
  fi

  if [ -z "${RESPONSE}" ]; then
    echo "No certificates found on ${HOST}." 2>&1
    exit 1
  fi

  echo "${RESPONSE}"
}

# Get the certificate expiry and return as an ISO timestamp
function get_certificate_expiry {
  local TYPE=$1
  local CERT=$2
  local EXPIRY 

  if ! EXPIRY=$(echo "${CERT}" | openssl x509 -enddate -dateopt iso_8601 -noout); then 
    echo "unable to parse an end date from the ${TYPE} certificate" 2>&1
    exit 1
  fi  

  echo "${EXPIRY//notAfter=/}"

}


CLUSTER=$1
USERNAME=$2
PASSWORD=$3


# Check if jq is installed
if ! command -v jq &> /dev/null; then
  echo "jq is not installed. Please install jq to run this script." 
  exit 1
fi

# Check if curl is installed
if ! command -v curl &> /dev/null; then
  echo "curl is not installed. Please install curl to run this script." 
  exit 1
fi

# Check if openssl is installed
if ! command -v openssl &> /dev/null; then 
  echo "openssl is not installed. Please install openssl to run this script."
fi

if  [ -z "${CLUSTER}" ] || [ -z "${USERNAME}" ] || [ -z "${PASSWORD}" ]; then
  echo "Usage: $0 <host> <username> <password>"   
  exit 1
fi

# Get the certificates 
CERT_LIST=$(get_certificates "${CLUSTER}")


# For each  of the important certs, get the cert and extract the expiry date.
for CERT_NAME in "${CERT_TYPES[@]}"
do
  KEY="${CERT_NAME}"_cert
  if ! CERT=$(echo "${CERT_LIST}" | jq -r  ."${KEY}" ); then 
    echo "unable to get certificate ${CERT_NAME} from list" 2>&1
    exit 1
  fi

  if ! EXPIRY=$(get_certificate_expiry "${CERT_NAME}" "${CERT}"); then 
    echo "unable to get expiry date from certificate ${CERT_NAME}" 2>&1
    exit 1
  fi

  printf '%-24s%s\n' "${CERT_NAME}" "${EXPIRY}"

done