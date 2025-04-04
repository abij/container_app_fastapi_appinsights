# Setup infra for Azure Container Apps using terraform to deploy the infrastructure.
#
# 1. Configure your Azure Subscription:
#      export ARM_SUBSCRIPTION_ID="your-subscription-id"
# 2. terraform init
# 3. terraform plan
# 4. terraform apply

resource "random_string" "random_acr_name" {
  length  = 10
  special = false
  upper   = false
}

locals {
  # You can also use a unique fixed value for the ACR:
  unique_acr_name = "acr${random_string.random_acr_name.result}demo"
}

# ==========================================================================
# Providers
# ==========================================================================

terraform {
  required_providers {
    azapi = {
      source = "azure/azapi"
    }
  }
}

provider "azurerm" {
  features {}
  # Export the environment variable ARM_SUBSCRIPTION_ID
  #   or specify the subscription id
  # subscription_id = "id here"
}

provider "azapi" {
  # Export the environment variable ARM_SUBSCRIPTION_ID
  #   or specify the subscription id
  # subscription_id = "id here"
}

# ==========================================================================
# Resources
# ==========================================================================

resource "azurerm_resource_group" "demo" {
  name     = "alexander-bij-sandbox"
  location = "westeurope"
}

resource "azurerm_log_analytics_workspace" "demo" {
  name                = "demo-law"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
}

resource "azurerm_network_security_group" "demo" {
  name                = "default-nsg"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
}

resource "azurerm_container_registry" "demo" {
  name                = local.unique_acr_name
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  sku                 = "Basic"
}

resource "azurerm_virtual_network" "demo" {
  name                = "demo-vnet"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  address_space = ["10.0.0.0/20"]

  subnet {
    name = "subnet1"
    address_prefixes = ["10.0.0.0/21"]
  }
}

# Missing Identity block:
# https://github.com/hashicorp/terraform-provider-azurerm/issues/26271
resource "azurerm_container_app_environment" "demo" {
  name                       = "ace-demo-test"
  location                   = azurerm_resource_group.demo.location
  resource_group_name        = azurerm_resource_group.demo.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.demo.id
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

# Create a Managed Identity which can be used by the Container Apps for pulling the images from ACR
resource "azurerm_user_assigned_identity" "demo" {
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  name                = "msi-apps-demo"
}

# Allow AppContainerEnvironment to access ACR to be able to pull images
resource "azurerm_role_assignment" "demo" {
  scope                = azurerm_container_registry.demo.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.demo.principal_id
}

# Track web-app metrics, logs, and events using OpenTelemetry
resource "azurerm_application_insights" "demo" {
  name                = "demo-appinsights"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.demo.id
}

resource "azapi_update_resource" "app_insights_open_telemetry_integration" {
  name      = azurerm_container_app_environment.demo.name
  parent_id = azurerm_resource_group.demo.id
  type      = "Microsoft.App/managedEnvironments@2023-11-02-preview"
  body = {
    properties = {
      appInsightsConfiguration = {
        connectionString = azurerm_application_insights.demo.connection_string
      }
      appLogsConfiguration = {
        destination = "log-analytics"
        logAnalyticsConfiguration = {
          customerId = azurerm_log_analytics_workspace.demo.workspace_id
          sharedKey  = azurerm_log_analytics_workspace.demo.primary_shared_key
        }
      }
      openTelemetryConfiguration = {
        tracesConfiguration = {
          destinations = ["appInsights"]
        }
        logsConfiguration = {
          destinations = ["appInsights"]
        }
      }
    }
  }
  response_export_values = ["properties"]
}

# ==========================================================================
# Outputs
# ==========================================================================

output "deploy_replace_envs" {
  sensitive = true
  value = {
    "AZURE_MSI_RESOURCE_ID"                 = azurerm_user_assigned_identity.demo.id
    "AZURE_CONTAINER_APP_ENVIRONMENT_ID"    = azurerm_container_app_environment.demo.id
    "AZURE_CONTAINER_REGISTRY_NAME"         = azurerm_container_registry.demo.name
    "AZURE_CONTAINER_REGISTRY_DOMAIN"       = azurerm_container_registry.demo.login_server
    "AZURE_RESOURCE_GROUP"                  = azurerm_resource_group.demo.name
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.demo.connection_string
  }
  description = "Set these Environment variables to fill the placeholders in the template yaml."
}