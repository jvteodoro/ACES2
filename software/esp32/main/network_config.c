#include "network_config.h"

#include <string.h>
#include "nvs.h"
#include "wifi_config.h"

#define CONFIG_NAMESPACE "aces2"

static void load_string(nvs_handle_t handle, const char *key,
                        char *destination, size_t capacity)
{
    size_t length = capacity;
    esp_err_t err = nvs_get_str(handle, key, destination, &length);
    if (err != ESP_OK)
        destination[0] = '\0';
}

void aces2_network_config_load(aces2_network_config_t *config)
{
    memset(config, 0, sizeof(*config));
    strlcpy(config->ssid, ACES2_WIFI_SSID, sizeof(config->ssid));
    strlcpy(config->password, ACES2_WIFI_PASSWORD, sizeof(config->password));
    strlcpy(config->destination_ip, ACES2_UDP_DEST_IP,
            sizeof(config->destination_ip));
    config->destination_port = ACES2_UDP_DEST_PORT;
    config->udp_magic = ACES2_UDP_MAGIC;

    nvs_handle_t handle;
    if (nvs_open(CONFIG_NAMESPACE, NVS_READONLY, &handle) != ESP_OK)
        return;

    char stored_ssid[sizeof(config->ssid)] = {0};
    char stored_password[sizeof(config->password)] = {0};
    char stored_ip[sizeof(config->destination_ip)] = {0};
    uint16_t stored_port;
    uint32_t stored_magic;
    load_string(handle, "wifi_ssid", stored_ssid, sizeof(stored_ssid));
    load_string(handle, "wifi_pass", stored_password, sizeof(stored_password));
    load_string(handle, "udp_ip", stored_ip, sizeof(stored_ip));
    if (stored_ssid[0] != '\0') {
        strlcpy(config->ssid, stored_ssid, sizeof(config->ssid));
        strlcpy(config->password, stored_password, sizeof(config->password));
        strlcpy(config->destination_ip, stored_ip,
                sizeof(config->destination_ip));
        if (nvs_get_u16(handle, "udp_port", &stored_port) == ESP_OK &&
            stored_port != 0)
            config->destination_port = stored_port;
        if (nvs_get_u32(handle, "udp_magic", &stored_magic) == ESP_OK)
            config->udp_magic = stored_magic;
    }
    nvs_close(handle);
}

esp_err_t aces2_network_config_save(const aces2_network_config_t *config)
{
    nvs_handle_t handle;
    esp_err_t err = nvs_open(CONFIG_NAMESPACE, NVS_READWRITE, &handle);
    if (err != ESP_OK)
        return err;
    err = nvs_set_str(handle, "wifi_ssid", config->ssid);
    if (err == ESP_OK) err = nvs_set_str(handle, "wifi_pass", config->password);
    if (err == ESP_OK) err = nvs_set_str(handle, "udp_ip", config->destination_ip);
    if (err == ESP_OK) err = nvs_set_u16(handle, "udp_port", config->destination_port);
    if (err == ESP_OK) err = nvs_set_u32(handle, "udp_magic", config->udp_magic);
    if (err == ESP_OK) err = nvs_commit(handle);
    nvs_close(handle);
    return err;
}
