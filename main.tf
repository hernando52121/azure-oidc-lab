# 1. Configuración del Proveedor
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# 2. Grupo de Recursos (Contenedor lógico - Costo: $0)
resource "azurerm_resource_group" "sec_lab_rg" {
  name     = "rg-security-lab-01"
  location = "East US"
}

# 3. GOBIERNO: Asignación de Azure Policy (Costo: $0)
resource "azurerm_resource_group_policy_assignment" "restrict_locations" {
  name                 = "enforce-allowed-locations"
  resource_group_id    = azurerm_resource_group.sec_lab_rg.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"
  
  parameters = jsonencode({
    "listOfAllowedLocations": {
      "value": ["eastus", "eastus2"]
    }
  })
}

# 4. SEGURIDAD DE RED: NSG y VNet (Costo: $0)
resource "azurerm_network_security_group" "sec_lab_nsg" {
  name                = "nsg-zerotrust-01"
  location            = azurerm_resource_group.sec_lab_rg.location
  resource_group_name = azurerm_resource_group.sec_lab_rg.name

  security_rule {
    name                       = "Deny-SSH-RDP-Internet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_virtual_network" "sec_lab_vnet" {
  name                = "vnet-security-lab"
  location            = azurerm_resource_group.sec_lab_rg.location
  resource_group_name = azurerm_resource_group.sec_lab_rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "sec_lab_subnet" {
  name                 = "snet-workloads"
  resource_group_name  = azurerm_resource_group.sec_lab_rg.name
  virtual_network_name = azurerm_virtual_network.sec_lab_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet_network_security_group_association" "nsg_association" {
  subnet_id                 = azurerm_subnet.sec_lab_subnet.id
  network_security_group_id = azurerm_network_security_group.sec_lab_nsg.id
}

# 5. SEGURIDAD DE DATOS: Storage Account Seguro (Costo: $0)
resource "random_string" "random" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_storage_account" "sec_lab_storage" {
  name                     = "stseclab${random_string.random.result}"
  resource_group_name      = azurerm_resource_group.sec_lab_rg.name
  location                 = azurerm_resource_group.sec_lab_rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
}
# 6. GESTIÓN DE SECRETOS: Azure Key Vault
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "sec_lab_kv" {
  name                        = "kv-seclab-${random_string.random.result}"
  location                    = azurerm_resource_group.sec_lab_rg.location
  resource_group_name         = azurerm_resource_group.sec_lab_rg.name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false

  sku_name = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = [
      "Get", "Set", "List", "Delete", "Purge"
    ]
  }
}

# Generador de contraseña aleatoria segura
resource "random_password" "db_pwd" {
  length           = 16
  special          = true
  override_special = "!@#$%"
}

# Guardar la contraseña generada en el Key Vault
resource "azurerm_key_vault_secret" "db_password" {
  name            = "AdminDatabasePassword"
  value           = random_password.db_pwd.result
  key_vault_id    = azurerm_key_vault.sec_lab_kv.id
  
  # Políticas de seguridad adicionales requeridas por SAST
  content_type    = "Password"
  expiration_date = "2027-12-31T23:59:59Z"
}