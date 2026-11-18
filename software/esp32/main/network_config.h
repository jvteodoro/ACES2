#pragma once

#include <stdint.h>
#include "esp_err.h"

typedef struct {
    char ssid[33];
    char password[65];
    char destination_ip[16];
    uint16_t destination_port;
    uint32_t udp_magic;
} aces2_network_config_t;

void aces2_network_config_load(aces2_network_config_t *config);
esp_err_t aces2_network_config_save(const aces2_network_config_t *config);
