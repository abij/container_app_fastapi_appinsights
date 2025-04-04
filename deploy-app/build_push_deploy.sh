#!/bin/bash
set -e  # Exit on errors

# Get current script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Optionally change:
app_name="my-fastapi-aca"
image_name="my-fastapi-aca"
image_tag="latest"

echo "1. Load environment variables from terraform output..."
$(cd "$SCRIPT_DIR/../infra-as-code" && terraform output --json \
  | jq -r '.deploy_replace_envs.value | to_entries.[] | "export \(.key)=\(.value)"')

full_image_name="${AZURE_CONTAINER_REGISTRY_DOMAIN}/${image_name}:${image_tag}"
echo "2. Image tag name: '${full_image_name}'  (based on terraform output)"

echo "3. Building image ${full_image_name}..."
podman build --arch amd64 -t "${full_image_name}" "${SCRIPT_DIR}/.."
echo
echo "3.5. Login into ACR (manually) by executing these commands copy & paste ready!"
echo "  ACR_TOKEN=\$(az acr login --name ${AZURE_CONTAINER_REGISTRY_NAME} --expose-token --query \"accessToken\"  -o tsv)"
echo "  podman login $AZURE_CONTAINER_REGISTRY_DOMAIN --username=00000000-0000-0000-0000-000000000000 --password \$ACR_TOKEN"
echo
echo "4. Pushing image ${full_image_name} to ACR..."
podman push "${full_image_name}"
echo
echo "5. Deploy to Azure Container Environment..."
echo "5.1. Create app.yaml from template using env variables & secrets (auto-remove file)..."
envsubst < app.template.yaml > app.yaml

# Automatically remove the app.yaml file when the script exits
trap 'rm -f app.yaml' EXIT

echo "5.2. Create or update the app using Azure CLI..."
az containerapp create --name $app_name --resource-group "${AZURE_RESOURCE_GROUP}" --yaml app.yaml -o none

echo "Finished deploying the app!"