resource "azurerm_private_dns_zone" "spring_cloud_zone" {
  name                = "private.azuremicroservices.io"
  resource_group_name = var.resource_group_name
}

# RBAC Access for Spoke VNET

data "azuread_service_principal" "resource_provider" {
   display_name = "Azure Spring Cloud Resource Provider"
 }

resource "azurerm_role_assignment" "scowner" {
  scope                 = var.spoke_virtual_network_id
  role_definition_name = "Owner"
  principal_id = data.azuread_service_principal.resource_provider.object_id
}

resource "azurerm_application_insights" "sc_app_insights" {
  name                = var.app_insights_name
  location            = var.location
  resource_group_name = var.resource_group_name
  application_type    = "web"
}



resource "azurerm_monitor_diagnostic_setting" "sc_diag" {
  name                        = "monitoring"
  target_resource_id          = azurerm_spring_cloud_service.sc.id
  log_analytics_workspace_id  = var.sc_law_id

  log {
    category = "ApplicationConsole"
    enabled  = true

    retention_policy {
      enabled = false
    }
  }

  metric {
    category = "AllMetrics"

    retention_policy {
      enabled = false
    }
  }
}

resource "azurerm_spring_cloud_service" "sc" {
  name                = var.sc_service_name 
  resource_group_name = var.resource_group_name
  location            = var.location
  
  network {
    app_subnet_id                               = var.app_subnet_id
    service_runtime_subnet_id                   = var.service_runtime_subnet_id
    cidr_ranges                                 = var.sc_cidr
    app_network_resource_group                  = "${var.sc_service_name}-apps-rg"
    service_runtime_network_resource_group      = "${var.sc_service_name}-runtime-rg"
  }
  
  timeouts {
      create = "60m"
      delete = "2h"
  }

  trace {
    instrumentation_key = azurerm_application_insights.sc_app_insights.instrumentation_key
  }
  depends_on = [azurerm_role_assignment.scowner]

}

resource "azurerm_private_dns_zone_virtual_network_link" "hub-link" {
  name                  = "azure-spring-cloud-hub-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.spring_cloud_zone.name
  virtual_network_id    = var.hub_virtual_network_id
}

resource "azurerm_private_dns_zone_virtual_network_link" "spoke-link" {
  name                  = "azure-spring-cloud-spoke-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.spring_cloud_zone.name
  virtual_network_id    = var.spoke_virtual_network_id
}

data "azurerm_lb" "svc_load_balancer" {
  name                = var.internal_lb_svc_load_balancer_name
  resource_group_name = "${var.sc_service_name}-runtime-rg"
  depends_on = [azurerm_spring_cloud_service.sc]
}

resource "azurerm_private_dns_a_record" "a_record" {
  name                = var.private_dns_a_record_a_record_name
  zone_name           = azurerm_private_dns_zone.spring_cloud_zone.name
  resource_group_name = var.resource_group_name
  ttl                 = var.private_dns_a_record_a_record_ttl
  records             = [data.azurerm_lb.svc_load_balancer.frontend_ip_configuration[0].private_ip_address]
}

data "azurerm_resources" "route_table_apps" {
  type = "Microsoft.Network/routeTables"
  resource_group_name           = "${var.sc_service_name}-apps-rg"
  depends_on = [time_sleep.wait_600_seconds]
}

resource "azurerm_route" "default_egress_apps" {
  name                          = "default" 
  route_table_name              = data.azurerm_resources.route_table_apps.resources[0].name

  resource_group_name           = "${var.sc_service_name}-apps-rg"
  address_prefix              = "0.0.0.0/0"
  next_hop_type               = "VirtualAppliance"
  next_hop_in_ip_address      =  var.azure_fw_private_ip  
}

resource "time_sleep" "wait_600_seconds" {
  depends_on = [azurerm_spring_cloud_service.sc]
  create_duration = "600s"
}

data "azurerm_resources" "route_table_runtime" {
  type = "Microsoft.Network/routeTables"
  resource_group_name           = "${var.sc_service_name}-runtime-rg"
  depends_on = [time_sleep.wait_600_seconds]
}

resource "azurerm_route" "default_egress_runtime" {
  name                          = "default" 
  route_table_name              = data.azurerm_resources.route_table_runtime.resources[0].name

  resource_group_name           = "${var.sc_service_name}-runtime-rg"
  address_prefix              = "0.0.0.0/0"
  next_hop_type               = "VirtualAppliance"
  next_hop_in_ip_address      =  var.azure_fw_private_ip  
}