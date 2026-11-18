idf_component_register(SRCS "main.c" "network_config.c" "provisioning_ble.c"
                       INCLUDE_DIRS "."
                       REQUIRES esp_driver_spi esp_driver_gpio esp_wifi esp_event
                                nvs_flash lwip bt mbedtls)
