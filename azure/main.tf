resource "azurerm_resource_group" "faig" {
  name     = "${var.name_prefix}-rg"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "faig" {
  name                = "${var.name_prefix}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = coalesce(var.vm_location, azurerm_resource_group.faig.location)
  resource_group_name = azurerm_resource_group.faig.name
  tags                = var.tags
}

resource "azurerm_subnet" "faig" {
  name                 = "${var.name_prefix}-subnet"
  resource_group_name  = azurerm_resource_group.faig.name
  virtual_network_name = azurerm_virtual_network.faig.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_network_security_group" "faig" {
  name                = "${var.name_prefix}-nsg"
  location            = coalesce(var.vm_location, azurerm_resource_group.faig.location)
  resource_group_name = azurerm_resource_group.faig.name
  tags                = var.tags
}

resource "azurerm_network_security_rule" "ssh" {
  name                        = "AllowSSH"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = var.ssh_source_ips
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.faig.name
  network_security_group_name = azurerm_network_security_group.faig.name
}

resource "azurerm_network_security_rule" "https" {
  name                        = "AllowHTTPS"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefixes     = var.https_source_ips
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.faig.name
  network_security_group_name = azurerm_network_security_group.faig.name
}

resource "azurerm_network_security_rule" "http" {
  count                       = var.enable_http ? 1 : 0
  name                        = "AllowHTTP"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefixes     = var.https_source_ips
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.faig.name
  network_security_group_name = azurerm_network_security_group.faig.name
}

resource "azurerm_network_security_rule" "deny_inbound" {
  name                        = "DenyAllOtherInbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.faig.name
  network_security_group_name = azurerm_network_security_group.faig.name
}

resource "azurerm_public_ip" "faig" {
  count               = var.vm_count
  name                = "${var.name_prefix}-pip-${count.index + 1}"
  location            = coalesce(var.vm_location, azurerm_resource_group.faig.location)
  resource_group_name = azurerm_resource_group.faig.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "faig" {
  count               = var.vm_count
  name                = "${var.name_prefix}-nic-${count.index + 1}"
  location            = coalesce(var.vm_location, azurerm_resource_group.faig.location)
  resource_group_name = azurerm_resource_group.faig.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.faig.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.faig[count.index].id
  }

  tags = var.tags
}

resource "azurerm_network_interface_security_group_association" "faig" {
  count                     = var.vm_count
  network_interface_id      = azurerm_network_interface.faig[count.index].id
  network_security_group_id = azurerm_network_security_group.faig.id
}

resource "azurerm_linux_virtual_machine" "faig" {
  count               = var.vm_count
  name                = "${var.name_prefix}-${count.index + 1}"
  resource_group_name = azurerm_resource_group.faig.name
  location            = coalesce(var.vm_location, azurerm_resource_group.faig.location)
  size                = var.instance_type
  admin_username      = var.admin_username

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  source_image_id = var.source_image_id != "" ? var.source_image_id : null

  dynamic "source_image_reference" {
    for_each = var.source_image_id == "" ? [1] : []
    content {
      publisher = "Canonical"
      offer     = "0001-com-ubuntu-server-jammy"
      sku       = "22_04-lts-gen2"
      version   = "latest"
    }
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.disk_type
    disk_size_gb         = var.disk_size_gb
  }

  network_interface_ids = [azurerm_network_interface.faig[count.index].id]

  custom_data = base64encode(file("${path.module}/cloud-init/user-data.yml"))

  priority        = var.spot ? "Spot" : "Regular"
  eviction_policy = var.spot ? "Deallocate" : null
  max_bid_price   = var.spot ? var.spot_max_price : null

  tags = var.tags
}
