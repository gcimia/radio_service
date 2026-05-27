#include "include/radio_service/radio_service_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "radio_service_plugin.h"

void RadioServicePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  radio_service::RadioServicePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
