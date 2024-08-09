#!/bin/bash
 
set -e
 
# Ensure necessary environment variables are set
if [ -z "$AZP_URL" ]; then
  echo 1>&2 "error: missing AZP_URL environment variable"
  exit 1
fi
 
if [ -z "$SERVICE_PRINCIPAL_CLIENT_ID" ] || [ -z "$SERVICE_PRINCIPAL_CLIENT_SECRET" ] || [ -z "$SERVICE_PRINCIPAL_TENANT_ID" ]; then
  echo 1>&2 "error: missing Service Principal environment variables"
  exit 1
fi
 
# Log in to Azure using the Service Principal
echo "Logging in to Azure using Service Principal..."
az login --service-principal -u "$SERVICE_PRINCIPAL_CLIENT_ID" -p "$SERVICE_PRINCIPAL_CLIENT_SECRET" --tenant "$SERVICE_PRINCIPAL_TENANT_ID"
 
# Retrieve Azure AD token
echo "Retrieving Azure AD token..."
AZP_TOKEN=$(curl -X POST \
  -d "grant_type=client_credentials&client_id=$SERVICE_PRINCIPAL_CLIENT_ID&client_secret=$SERVICE_PRINCIPAL_CLIENT_SECRET&resource=499b84ac-1321-427f-aa17-267ca6975798/.default" \
https://login.microsoftonline.com/$SERVICE_PRINCIPAL_TENANT_ID/oauth2/token | jq -r '.access_token')
 
if [ -z "$AZP_TOKEN" ]; then
  echo 1>&2 "error: unable to retrieve Azure AD token"
  exit 1
fi
 
AZP_TOKEN_FILE=$(pwd)/.token
echo -n $AZP_TOKEN > "$AZP_TOKEN_FILE"
 
export AGENT_ALLOW_RUNASROOT="1"
 
cleanup() {
  if [ -n "$AZP_PLACEHOLDER" ]; then
    echo 'Running in placeholder mode, skipping cleanup'
    return
  fi
 
  if [ -e config.sh ]; then
    print_header "Cleanup. Removing Azure Pipelines agent..."
    while true; do
      ./config.sh remove --unattended --auth bearer --token $(cat "$AZP_TOKEN_FILE") && break
      echo "Retrying in 30 seconds..."
      sleep 30
    done
  fi
}
 
print_header() {
  lightcyan='\033[1;36m'
  nocolor='\033[0m'
  echo -e "${lightcyan}$1${nocolor}"
}
 
# Let the agent ignore the token env variables
export VSO_AGENT_IGNORE=AZP_TOKEN,AZP_TOKEN_FILE
 
print_header "1. Determining matching Azure Pipelines agent..."
 
AZP_AGENT_PACKAGES=$(curl -LsS \
    -H "Authorization: Bearer $(cat "$AZP_TOKEN_FILE")" \
    -H 'Accept:application/json;' \
    "$AZP_URL/_apis/distributedtask/packages/agent?platform=$TARGETARCH&top=1")
 
AZP_AGENT_PACKAGE_LATEST_URL=$(echo "$AZP_AGENT_PACKAGES" | jq -r '.value[0].downloadUrl')
 
if [ -z "$AZP_AGENT_PACKAGE_LATEST_URL" -o "$AZP_AGENT_PACKAGE_LATEST_URL" == "null" ]; then
  echo 1>&2 "error: could not determine a matching Azure Pipelines agent"
  echo 1>&2 "check that account '$AZP_URL' is correct and the token is valid for that account"
  exit 1
fi
 
print_header "2. Downloading and extracting Azure Pipelines agent..."
 
echo "Agent package URL: $AZP_AGENT_PACKAGE_LATEST_URL"
curl -LsS $AZP_AGENT_PACKAGE_LATEST_URL | tar -xz & wait $!
 
source ./env.sh
 
trap 'cleanup; exit 0' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
 
print_header "3. Configuring Azure Pipelines agent..."
 
./config.sh --unattended \
  --agent "${AZP_AGENT_NAME:-$(hostname)}" \
  --url "$AZP_URL" \
  --auth bearer \
  --token $(cat "$AZP_TOKEN_FILE") \
  --pool "${AZP_POOL:-Default}" \
  --replace \
  --acceptTeeEula & wait $!
 
print_header "4. Running Azure Pipelines agent..."
 
trap 'cleanup; exit 0' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
 
chmod +x ./run.sh
 
# If $AZP_PLACEHOLDER is set, skipping running the agent
if [ -n "$AZP_PLACEHOLDER" ]; then
  echo 'Running in placeholder mode, skipping running the agent'
else
  ./run.sh --once & wait $!
fi
