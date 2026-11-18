#include "provisioning_ble.h"

#include <stdbool.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "esp_log.h"
#include "esp_random.h"
#include "esp_system.h"
#include "esp_check.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "os/os_mbuf.h"
#include "psa/crypto.h"
#include "network_config.h"
#include "provisioning_config.h"
#include "wifi_config.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "wifi_config.h"

#ifndef ACES2_BLE_SETUP_PASSWORD
#error "Set ACES2_BLE_SETUP_PASSWORD in provisioning_config.h"
#endif

#define BLE_DEVICE_NAME "ACES2-AUDIO"
#define COMMAND_MAX_LEN 244

static const char *TAG = "aces2_ble";
static uint16_t connection_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t challenge_handle;
static uint16_t command_handle;
static uint16_t status_handle;
static uint8_t address_type;
static bool authenticated;
static bool nonce_valid;
static uint8_t nonce[16];
static uint8_t session_key[32];
static char nonce_hex[33];
static char status_value[48] = "LOCKED";

static const ble_uuid128_t service_uuid = BLE_UUID128_INIT(
    0x6a, 0x5c, 0x42, 0x81, 0x3e, 0x92, 0x4a, 0x7c,
    0xb1, 0x30, 0x6d, 0xe8, 0x20, 0x00, 0xa2, 0xac);
static const ble_uuid128_t challenge_uuid = BLE_UUID128_INIT(
    0x6a, 0x5c, 0x42, 0x81, 0x3e, 0x92, 0x4a, 0x7c,
    0xb1, 0x30, 0x6d, 0xe8, 0x21, 0x00, 0xa2, 0xac);
static const ble_uuid128_t command_uuid = BLE_UUID128_INIT(
    0x6a, 0x5c, 0x42, 0x81, 0x3e, 0x92, 0x4a, 0x7c,
    0xb1, 0x30, 0x6d, 0xe8, 0x22, 0x00, 0xa2, 0xac);
static const ble_uuid128_t status_uuid = BLE_UUID128_INIT(
    0x6a, 0x5c, 0x42, 0x81, 0x3e, 0x92, 0x4a, 0x7c,
    0xb1, 0x30, 0x6d, 0xe8, 0x23, 0x00, 0xa2, 0xac);

static void start_advertising(void);

static void set_status(const char *status)
{
    strlcpy(status_value, status, sizeof(status_value));
    if (status_handle != 0)
        (void)ble_gatts_chr_updated(status_handle);
}

static void restart_after_save(void *arg)
{
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(1200));
    esp_restart();
}

static int hex_to_bytes(const char *hex, uint8_t *output, size_t output_len)
{
    if (strlen(hex) != output_len * 2)
        return -1;
    for (size_t i = 0; i < output_len; ++i) {
        unsigned int value;
        if (sscanf(hex + 2 * i, "%2x", &value) != 1)
            return -1;
        output[i] = (uint8_t)value;
    }
    return 0;
}

static void bytes_to_hex(const uint8_t *bytes, size_t length, char *hex)
{
    static const char alphabet[] = "0123456789abcdef";
    for (size_t i = 0; i < length; ++i) {
        hex[2 * i] = alphabet[bytes[i] >> 4];
        hex[2 * i + 1] = alphabet[bytes[i] & 0x0f];
    }
    hex[2 * length] = '\0';
}

static bool valid_ipv4(const char *ip)
{
    unsigned int a, b, c, d;
    char tail;
    if (sscanf(ip, "%u.%u.%u.%u%c", &a, &b, &c, &d, &tail) != 4)
        return false;
    return a <= 255 && b <= 255 && c <= 255 && d <= 255;
}

static bool verify_response(const char *response_hex)
{
    uint8_t received[32];
    uint8_t expected[32];
    if (!nonce_valid || strlen(ACES2_BLE_SETUP_PASSWORD) < 16 ||
        hex_to_bytes(response_hex, received, sizeof(received)) != 0)
        return false;
    psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attributes, PSA_KEY_TYPE_HMAC);
    psa_set_key_bits(&attributes, strlen(ACES2_BLE_SETUP_PASSWORD) * 8);
    psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_SIGN_MESSAGE);
    psa_set_key_algorithm(&attributes, PSA_ALG_HMAC(PSA_ALG_SHA_256));
    mbedtls_svc_key_id_t key_id = 0;
    psa_status_t crypto_result = psa_import_key(
        &attributes, (const uint8_t *)ACES2_BLE_SETUP_PASSWORD,
        strlen(ACES2_BLE_SETUP_PASSWORD), &key_id);
    psa_reset_key_attributes(&attributes);
    size_t mac_length = 0;
    if (crypto_result == PSA_SUCCESS)
        crypto_result = psa_mac_compute(key_id, PSA_ALG_HMAC(PSA_ALG_SHA_256),
                                        nonce, sizeof(nonce), expected,
                                        sizeof(expected), &mac_length);
    if (crypto_result == PSA_SUCCESS)
        (void)psa_destroy_key(key_id);
    if (crypto_result != PSA_SUCCESS || mac_length != sizeof(expected))
        return false;
    uint8_t difference = 0;
    for (size_t i = 0; i < sizeof(expected); ++i)
        difference |= (uint8_t)(expected[i] ^ received[i]);
    if (difference != 0) {
        nonce_valid = false;
        return false;
    }

    uint8_t session_context[sizeof(nonce) + sizeof("ACES2-SESSION") - 1];
    memcpy(session_context, nonce, sizeof(nonce));
    memcpy(session_context + sizeof(nonce), "ACES2-SESSION",
           sizeof("ACES2-SESSION") - 1);
    attributes = (psa_key_attributes_t)PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attributes, PSA_KEY_TYPE_HMAC);
    psa_set_key_bits(&attributes, strlen(ACES2_BLE_SETUP_PASSWORD) * 8);
    psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_SIGN_MESSAGE);
    psa_set_key_algorithm(&attributes, PSA_ALG_HMAC(PSA_ALG_SHA_256));
    crypto_result = psa_import_key(&attributes,
                                   (const uint8_t *)ACES2_BLE_SETUP_PASSWORD,
                                   strlen(ACES2_BLE_SETUP_PASSWORD), &key_id);
    psa_reset_key_attributes(&attributes);
    mac_length = 0;
    if (crypto_result == PSA_SUCCESS)
        crypto_result = psa_mac_compute(key_id, PSA_ALG_HMAC(PSA_ALG_SHA_256),
                                        session_context, sizeof(session_context),
                                        session_key, sizeof(session_key),
                                        &mac_length);
    if (crypto_result == PSA_SUCCESS)
        (void)psa_destroy_key(key_id);
    memset(session_context, 0, sizeof(session_context));
    nonce_valid = false;
    return crypto_result == PSA_SUCCESS && mac_length == sizeof(session_key);
}

static int handle_auth(const uint8_t *frame, size_t frame_len)
{
    char response[65] = {0};
    if (frame_len == 65) {
        memcpy(response, frame + 1, 64);
    }
    if (frame_len == 65 && verify_response(response)) {
        authenticated = true;
        set_status("AUTH_OK");
        ESP_LOGI(TAG, "BLE config client authenticated");
        return 0;
    }

    authenticated = false;
    memset(session_key, 0, sizeof(session_key));
    set_status("AUTH_FAILED");
    ESP_LOGW(TAG, "BLE config authentication failed; disconnecting client");
    if (connection_handle != BLE_HS_CONN_HANDLE_NONE)
        (void)ble_gap_terminate(connection_handle, BLE_ERR_AUTH_FAIL);
    return -1;
}

static int handle_config(const uint8_t *frame, size_t frame_len)
{
    if (!authenticated)
        return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    if (frame_len < 1 + 12 + 17)
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;

    uint8_t plaintext[COMMAND_MAX_LEN + 1];
    const uint8_t *iv = frame + 1;
    const uint8_t *sealed = frame + 13;
    size_t sealed_len = frame_len - 13;

    size_t ciphertext_len = sealed_len - 16;
    psa_key_attributes_t attributes = PSA_KEY_ATTRIBUTES_INIT;
    psa_set_key_type(&attributes, PSA_KEY_TYPE_AES);
    psa_set_key_bits(&attributes, 256);
    psa_set_key_usage_flags(&attributes, PSA_KEY_USAGE_DECRYPT);
    psa_set_key_algorithm(&attributes, PSA_ALG_GCM);
    mbedtls_svc_key_id_t key_id = 0;
    psa_status_t crypto_result = psa_import_key(&attributes, session_key,
                                                 sizeof(session_key), &key_id);
    psa_reset_key_attributes(&attributes);
    size_t plaintext_len = 0;
    if (crypto_result == PSA_SUCCESS)
        crypto_result = psa_aead_decrypt(key_id, PSA_ALG_GCM, iv, 12,
                                         NULL, 0, sealed, sealed_len,
                                         plaintext, sizeof(plaintext),
                                         &plaintext_len);
    if (key_id != 0 && crypto_result != PSA_ERROR_INVALID_HANDLE)
        (void)psa_destroy_key(key_id);
    if (crypto_result != PSA_SUCCESS || plaintext_len != ciphertext_len) {
        memset(plaintext, 0, sizeof(plaintext));
        return BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    }
    plaintext[plaintext_len] = '\0';
    char *fields[5] = {0};
    size_t field_count = 1;
    fields[0] = (char *)plaintext;
    for (char *separator = strchr(fields[0], '\n'); separator != NULL;
         separator = strchr(fields[field_count - 1], '\n')) {
        if (field_count >= sizeof(fields) / sizeof(fields[0])) {
            memset(plaintext, 0, sizeof(plaintext));
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        *separator = '\0';
        fields[field_count++] = separator + 1;
    }
    if (field_count != 4 && field_count != 5) {
        memset(plaintext, 0, sizeof(plaintext));
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }

    size_t ssid_len = strlen(fields[0]);
    size_t password_len = strlen(fields[1]);
    size_t ip_len = strlen(fields[2]);
    char *port_end = NULL;
    long port_value = strtol(fields[3], &port_end, 10);
    uint32_t magic_value = ACES2_UDP_MAGIC;
    if (field_count == 5) {
        const char *magic_digits = fields[4];
        if (magic_digits[0] == '0' &&
            (magic_digits[1] == 'x' || magic_digits[1] == 'X'))
            magic_digits += 2;
        size_t magic_length = strlen(magic_digits);
        bool valid_magic = magic_length > 0 && magic_length <= 8;
        for (size_t i = 0; i < magic_length && valid_magic; ++i)
            valid_magic = isxdigit((unsigned char)magic_digits[i]) != 0;
        if (!valid_magic) {
            memset(plaintext, 0, sizeof(plaintext));
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        char *magic_end = NULL;
        unsigned long parsed_magic = strtoul(fields[4], &magic_end, 16);
        if (magic_end == fields[4] || *magic_end != '\0' ||
            parsed_magic > UINT32_MAX) {
            memset(plaintext, 0, sizeof(plaintext));
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        magic_value = (uint32_t)parsed_magic;
    }
    if (ssid_len == 0 || ssid_len > 32 || password_len > 64 ||
        ip_len > 15 || !valid_ipv4(fields[2]) || port_end == fields[3] ||
        *port_end != '\0' || port_value < 1 || port_value > 65535) {
        memset(plaintext, 0, sizeof(plaintext));
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }

    aces2_network_config_t config = {0};
    strlcpy(config.ssid, fields[0], sizeof(config.ssid));
    strlcpy(config.password, fields[1], sizeof(config.password));
    strlcpy(config.destination_ip, fields[2],
            sizeof(config.destination_ip));
    config.destination_port = (uint16_t)port_value;
    config.udp_magic = magic_value;
    memset(plaintext, 0, sizeof(plaintext));
    if (aces2_network_config_save(&config) != ESP_OK) {
        set_status("SAVE_FAILED");
        return BLE_ATT_ERR_UNLIKELY;
    }

    set_status("SAVED_REBOOTING");
    ESP_LOGI(TAG, "network settings saved to NVS; restarting");
    if (xTaskCreate(restart_after_save, "cfg_restart", 2048, NULL, 5, NULL) != pdPASS)
        esp_restart();
    return 0;
}

static int process_command(uint16_t conn_handle, struct os_mbuf *om)
{
    uint8_t command[COMMAND_MAX_LEN] = {0};
    uint16_t length = 0;
    if (OS_MBUF_PKTLEN(om) > COMMAND_MAX_LEN ||
        ble_hs_mbuf_to_flat(om, command, sizeof(command), &length) != 0)
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;

    int result;
    if (command[0] == 0x01)
        result = handle_auth(command, length) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_AUTHEN;
    else if (command[0] == 0x02)
        result = handle_config(command, length);
    else
        result = BLE_ATT_ERR_UNLIKELY;
    (void)conn_handle;
    return result;
}

static int gatt_access(uint16_t conn_handle, uint16_t attr_handle,
                       struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)arg;
    if (attr_handle == challenge_handle && ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        esp_fill_random(nonce, sizeof(nonce));
        bytes_to_hex(nonce, sizeof(nonce), nonce_hex);
        nonce_valid = true;
        return os_mbuf_append(ctxt->om, nonce_hex, strlen(nonce_hex)) == 0
                   ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (attr_handle == command_handle && ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR)
        return process_command(conn_handle, ctxt->om);
    if (attr_handle == status_handle && ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR)
        return os_mbuf_append(ctxt->om, status_value, strlen(status_value)) == 0
                   ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &service_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &challenge_uuid.u,
                .access_cb = gatt_access,
                .flags = BLE_GATT_CHR_F_READ,
                .val_handle = &challenge_handle,
            },
            {
                .uuid = &command_uuid.u,
                .access_cb = gatt_access,
                .flags = BLE_GATT_CHR_F_WRITE,
                .val_handle = &command_handle,
            },
            {
                .uuid = &status_uuid.u,
                .access_cb = gatt_access,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &status_handle,
            },
            {0},
        },
    },
    {0},
};

static void on_sync(void)
{
    int result = ble_hs_id_infer_auto(0, &address_type);
    if (result == 0)
        start_advertising();
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            connection_handle = event->connect.conn_handle;
            authenticated = false;
            nonce_valid = false;
            set_status("LOCKED");
            ESP_LOGI(TAG, "BLE config client connected");
        } else {
            start_advertising();
        }
        return 0;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "BLE config client disconnected; reason=%d",
                 event->disconnect.reason);
        connection_handle = BLE_HS_CONN_HANDLE_NONE;
        authenticated = false;
        nonce_valid = false;
        memset(session_key, 0, sizeof(session_key));
        set_status("LOCKED");
        start_advertising();
        return 0;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        start_advertising();
        return 0;
    default:
        return 0;
    }
}

static void start_advertising(void)
{
    struct ble_hs_adv_fields fields = {0};
    const char *name = BLE_DEVICE_NAME;
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (const uint8_t *)name;
    fields.name_len = strlen(name);
    fields.name_is_complete = 1;
    (void)ble_gap_adv_set_fields(&fields);

    struct ble_gap_adv_params params = {0};
    params.conn_mode = BLE_GAP_CONN_MODE_UND;
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    params.itvl_min = 160; /* 100 ms; limit radio airtime beside Wi-Fi audio */
    params.itvl_max = 320; /* 200 ms */
    int result = ble_gap_adv_start(address_type, NULL, BLE_HS_FOREVER,
                                   &params, gap_event, NULL);
    if (result != 0 && result != BLE_HS_EALREADY)
        ESP_LOGE(TAG, "BLE advertising start failed: %d", result);
}

static void host_task(void *arg)
{
    (void)arg;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

esp_err_t provisioning_ble_start(void)
{
    if (strlen(ACES2_BLE_SETUP_PASSWORD) < 16) {
        ESP_LOGE(TAG, "BLE setup passphrase must be at least 16 characters");
        return ESP_ERR_INVALID_ARG;
    }
    if (psa_crypto_init() != PSA_SUCCESS)
        return ESP_FAIL;
    ESP_RETURN_ON_ERROR(nimble_port_init(), TAG, "NimBLE init failed");
    ble_hs_cfg.sync_cb = on_sync;
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ESP_RETURN_ON_ERROR(ble_svc_gap_device_name_set(BLE_DEVICE_NAME), TAG,
                        "BLE name set failed");
    ESP_RETURN_ON_ERROR(ble_gatts_count_cfg(services), TAG,
                        "GATT count failed");
    ESP_RETURN_ON_ERROR(ble_gatts_add_svcs(services), TAG,
                        "GATT service registration failed");
    nimble_port_freertos_init(host_task);
    ESP_LOGI(TAG, "BLE provisioning ready as %s", BLE_DEVICE_NAME);
    return ESP_OK;
}
