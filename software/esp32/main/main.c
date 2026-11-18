#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include "driver/spi_slave.h"
#include "driver/gpio.h"
#include "esp_err.h"
#include "esp_attr.h"
#include "esp_event.h"
#include "esp_intr_alloc.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "lwip/sockets.h"
#include "nvs_flash.h"
#include "soc/gpio_struct.h"

#include "network_config.h"
#include "provisioning_ble.h"
#include "wifi_config.h"

/* FPGA-to-ESP32 SPI wiring. */
/* GPIO18/19/23/5 are the ESP32 classic SPI3 (VSPI) IO_MUX pins. */
#define ACES2_SPI_HOST       SPI3_HOST
#define ACES2_SPI_MOSI_GPIO 23
#define ACES2_SPI_MISO_GPIO 19
#define ACES2_SPI_SCLK_GPIO 18
#define ACES2_SPI_CS_GPIO    5

#define ACES2_SPI_WORD_BITS       32
#define ACES2_SPI_WORDS_PER_FRAME 16
#define ACES2_SPI_FRAME_BITS      (ACES2_SPI_WORD_BITS * ACES2_SPI_WORDS_PER_FRAME)
#define ACES2_SPI_FRAME_BYTES     (ACES2_SPI_FRAME_BITS / 8)
#define ACES2_FRAME_MAGIC         0xACED0000u
#define ACES2_SPI_QUEUE_LEN  64
#define ACES2_SPI_DIAG_RECENT 16
#define ACES2_SPI_DIAG_LEN_BINS (ACES2_SPI_FRAME_BITS / ACES2_SPI_WORD_BITS + 1)

/* One queue operation is performed per block, not per sample. */
#define ACES2_BLOCK_SAMPLES  256
#define ACES2_BLOCK_COUNT    16
#define WIFI_CONNECTED_BIT   BIT0

static const char *TAG = "aces2_spi";
static QueueHandle_t free_blocks;
static aces2_network_config_t active_network_config;
#if ACES2_WIFI_ENABLE
static QueueHandle_t ready_blocks;
static EventGroupHandle_t wifi_events;
#endif

typedef struct {
    spi_slave_transaction_t transaction;
    uint8_t rx_buffer[ACES2_SPI_FRAME_BYTES] __attribute__((aligned(4)));
} spi_slot_t;

typedef struct {
    uint32_t samples[ACES2_BLOCK_SAMPLES];
    uint16_t count;
    uint16_t reserved;
    uint32_t sequence;
} audio_block_t;

typedef struct __attribute__((packed)) {
    uint32_t magic_be;
    uint32_t sequence_be;
    uint16_t sample_count_be;
    uint16_t flags_be;
} audio_udp_header_t;

static spi_slot_t slots[ACES2_SPI_QUEUE_LEN];
static audio_block_t block_pool[ACES2_BLOCK_COUNT];
static uint64_t received_words;
static uint32_t malformed_transactions;
static uint32_t invalid_frames;
static uint32_t crc_errors;
static uint32_t sequence_errors;
static uint32_t resync_events;
static uint32_t dropped_samples;
static uint32_t dropped_blocks;
static uint32_t udp_send_errors;
/* Detailed physical transaction diagnostics, written by the SPI task and
 * snapshotted once per second by stats_task. Bin n counts transactions with
 * at least n complete 32-bit words (the last bin includes >=512 bits). */
static portMUX_TYPE spi_diag_mux = portMUX_INITIALIZER_UNLOCKED;
static uint32_t spi_len_bins[ACES2_SPI_DIAG_LEN_BINS];
static uint32_t spi_len_remainders[ACES2_SPI_WORD_BITS];
static uint32_t spi_len_recent[ACES2_SPI_DIAG_RECENT];
static uint32_t spi_len_total;
static uint32_t spi_len_exact;
static uint32_t spi_len_min = UINT32_MAX;
static uint32_t spi_len_max;
static uint32_t spi_len_recent_write;
static bool spi_bad_frame_dumped;
/* Count the actual CS pad edges independently of the SPI peripheral's
 * trans_len result. This distinguishes real short CS pulses from a slave
 * peripheral length-reporting problem. */
static volatile uint32_t spi_cs_rising_edges;

static void IRAM_ATTR spi_cs_edge_isr(void *arg)
{
    (void)arg;
    ++spi_cs_rising_edges;
}

static uint32_t decode_word(const uint8_t *data)
{
    return ((uint32_t)data[0] << 24) |
           ((uint32_t)data[1] << 16) |
           ((uint32_t)data[2] << 8)  |
           ((uint32_t)data[3]);
}

static uint32_t crc32_word(uint32_t crc, uint32_t data)
{
    for (int byte_index = 3; byte_index >= 0; --byte_index) {
        crc ^= (data >> (byte_index * 8)) & 0xffu;
        for (int bit_index = 0; bit_index < 8; ++bit_index)
            crc = (crc & 1u) ? ((crc >> 1) ^ 0xedb88320u) : (crc >> 1);
    }
    return crc;
}

static void prepare_slot(spi_slot_t *slot)
{
    memset(slot, 0, sizeof(*slot));
    slot->transaction.length = ACES2_SPI_FRAME_BITS;
    slot->transaction.rx_buffer = slot->rx_buffer;
}

static void init_spi_slave(void)
{
    const spi_bus_config_t bus_config = {
        .mosi_io_num = ACES2_SPI_MOSI_GPIO,
        .miso_io_num = ACES2_SPI_MISO_GPIO,
        .sclk_io_num = ACES2_SPI_SCLK_GPIO,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = ACES2_SPI_FRAME_BYTES,
        /* Keep the SPI ISR beside spi_receive_task; core 0 runs Wi-Fi. */
        .isr_cpu_id = ESP_INTR_CPU_AFFINITY_1,
    };
    const spi_slave_interface_config_t slave_config = {
        .spics_io_num = ACES2_SPI_CS_GPIO,
        .flags = 0,
        .queue_size = ACES2_SPI_QUEUE_LEN,
        .mode = 1,
        .post_setup_cb = NULL,
        .post_trans_cb = NULL,
    };

#if ACES2_SPI_USE_DMA
    spi_dma_chan_t dma_channel = SPI_DMA_CH_AUTO;
#else
    spi_dma_chan_t dma_channel = SPI_DMA_DISABLED;
#endif
    ESP_ERROR_CHECK(spi_slave_initialize(ACES2_SPI_HOST, &bus_config,
                                          &slave_config, dma_channel));

    /* Observe the same physical CS pad used by the SPI slave. The edge
     * counters run independently of spi_slave_get_trans_result(). */
    esp_err_t gpio_isr_err = gpio_install_isr_service(ESP_INTR_FLAG_IRAM);
    if (gpio_isr_err != ESP_OK && gpio_isr_err != ESP_ERR_INVALID_STATE)
        ESP_ERROR_CHECK(gpio_isr_err);
    ESP_ERROR_CHECK(gpio_set_intr_type(ACES2_SPI_CS_GPIO, GPIO_INTR_POSEDGE));
    ESP_ERROR_CHECK(gpio_isr_handler_add(ACES2_SPI_CS_GPIO,
                                         spi_cs_edge_isr, NULL));
}

static void publish_block(audio_block_t **current)
{
    audio_block_t *block = *current;
    if (block == NULL || block->count == 0)
        return;

#if ACES2_WIFI_ENABLE
    if (xQueueSend(ready_blocks, &block, 0) != pdTRUE) {
        ++dropped_blocks;
        xQueueSend(free_blocks, &block, 0);
    }
#else
    /* Wi-Fi is disabled during SPI throughput characterization. */
    xQueueSend(free_blocks, &block, 0);
#endif
    *current = NULL;
}

static audio_block_t *get_block(void)
{
    audio_block_t *block = NULL;
    if (xQueueReceive(free_blocks, &block, 0) == pdTRUE) {
        block->count = 0;
        block->reserved = 0;
    }
    return block;
}

static void spi_receive_task(void *arg)
{
    audio_block_t *current = get_block();
    uint16_t expected_sequence = 0;
    bool have_sequence = false;

    while (true) {
        spi_slave_transaction_t *completed = NULL;
        ESP_ERROR_CHECK(spi_slave_get_trans_result(ACES2_SPI_HOST, &completed,
                                                   portMAX_DELAY));
        spi_slot_t *slot = (spi_slot_t *)completed;
        uint32_t frame_words[ACES2_SPI_WORDS_PER_FRAME];
        bool valid_frame = completed->trans_len == ACES2_SPI_FRAME_BITS;
        uint32_t actual_bits = completed->trans_len;
        uint32_t len_bin = actual_bits / ACES2_SPI_WORD_BITS;
        if (len_bin >= ACES2_SPI_DIAG_LEN_BINS)
            len_bin = ACES2_SPI_DIAG_LEN_BINS - 1;
        portENTER_CRITICAL(&spi_diag_mux);
        ++spi_len_total;
        ++spi_len_bins[len_bin];
        ++spi_len_remainders[actual_bits % ACES2_SPI_WORD_BITS];
        spi_len_recent[spi_len_recent_write % ACES2_SPI_DIAG_RECENT] = actual_bits;
        ++spi_len_recent_write;
        if (actual_bits < spi_len_min)
            spi_len_min = actual_bits;
        if (actual_bits > spi_len_max)
            spi_len_max = actual_bits;
        if (valid_frame)
            ++spi_len_exact;
        portEXIT_CRITICAL(&spi_diag_mux);
        if (valid_frame) {
            for (size_t i = 0; i < ACES2_SPI_WORDS_PER_FRAME; ++i)
                frame_words[i] = decode_word(&slot->rx_buffer[i * 4]);
        }

        /* Re-arm before block management. This minimizes the CS-to-next-
         * transaction dead time seen by the FPGA. */
        ESP_ERROR_CHECK(spi_slave_queue_trans(ACES2_SPI_HOST,
                                              &slot->transaction,
                                              portMAX_DELAY));

        if (valid_frame) {
            uint32_t crc = crc32_word(0xffffffffu, frame_words[0]);
            for (size_t i = 1; i <= ACES2_SPI_WORDS_PER_FRAME - 2; ++i)
                crc = crc32_word(crc, frame_words[i]);
            crc ^= 0xffffffffu;

            bool header_ok = (frame_words[0] & 0xffff0000u) == ACES2_FRAME_MAGIC;
            bool crc_ok = crc == frame_words[ACES2_SPI_WORDS_PER_FRAME - 1];
            uint16_t sequence = (uint16_t)(frame_words[0] & 0xffffu);
            if (!header_ok || !crc_ok) {
                ++invalid_frames;
                if (!crc_ok)
                    ++crc_errors;
                if (!spi_bad_frame_dumped) {
                    spi_bad_frame_dumped = true;
                    ESP_LOGE(TAG, "SPI quadro 512b mas inválido: header=%08" PRIx32
                             " header_ok=%d crc_calc=%08" PRIx32
                             " crc_rx=%08" PRIx32 " seq=%u dados=%08" PRIx32
                             ",%08" PRIx32 ",%08" PRIx32 ",%08" PRIx32,
                             frame_words[0], header_ok, crc,
                             frame_words[ACES2_SPI_WORDS_PER_FRAME - 1],
                             (unsigned)sequence,
                             frame_words[1], frame_words[2], frame_words[3],
                             frame_words[4]);
                }
                for (size_t i = 1; i < ACES2_SPI_WORDS_PER_FRAME; ++i) {
                    if ((frame_words[i] & 0xffff0000u) == ACES2_FRAME_MAGIC) {
                        ++resync_events;
                        break;
                    }
                }
                continue;
            }
            if (have_sequence && sequence != expected_sequence)
                ++sequence_errors;
            expected_sequence = sequence + 1u;
            have_sequence = true;
            received_words += ACES2_SPI_WORDS_PER_FRAME - 2;

            for (size_t i = 1; i < ACES2_SPI_WORDS_PER_FRAME - 1; ++i) {
                if (current == NULL)
                    current = get_block();

                if (current != NULL) {
                    current->samples[current->count++] = frame_words[i];
                    if (current->count == ACES2_BLOCK_SAMPLES) {
                        current->sequence = (uint32_t)(received_words /
                                                       ACES2_BLOCK_SAMPLES);
                        publish_block(&current);
                    }
                } else {
                    ++dropped_samples;
                }
            }
        } else {
            ++malformed_transactions;
        }
    }
}

static void stats_task(void *arg)
{
    uint32_t prev_total = 0;
    uint32_t prev_exact = 0;
    uint32_t prev_cs_rising = 0;
    while (true) {
        uint32_t len_bins[ACES2_SPI_DIAG_LEN_BINS];
        uint32_t remainders[ACES2_SPI_WORD_BITS];
        uint32_t recent[ACES2_SPI_DIAG_RECENT];
        uint32_t total, exact, min_bits, max_bits, recent_write;
        portENTER_CRITICAL(&spi_diag_mux);
        memcpy(len_bins, spi_len_bins, sizeof(len_bins));
        memcpy(remainders, spi_len_remainders, sizeof(remainders));
        memcpy(recent, spi_len_recent, sizeof(recent));
        total = spi_len_total;
        exact = spi_len_exact;
        min_bits = spi_len_min;
        max_bits = spi_len_max;
        recent_write = spi_len_recent_write;
        portEXIT_CRITICAL(&spi_diag_mux);

        char bins_text[160] = {0};
        char rem_text[128] = {0};
        char recent_text[160] = {0};
        size_t used = 0;
        for (size_t i = 0; i < ACES2_SPI_DIAG_LEN_BINS; ++i) {
            if (len_bins[i] == 0)
                continue;
            int n = snprintf(bins_text + used, sizeof(bins_text) - used,
                             "%s%u:%" PRIu32, used ? "," : "", (unsigned)i,
                             len_bins[i]);
            if (n < 0 || (size_t)n >= sizeof(bins_text) - used)
                break;
            used += (size_t)n;
        }
        used = 0;
        for (size_t i = 1; i < ACES2_SPI_WORD_BITS; ++i) {
            if (remainders[i] == 0)
                continue;
            int n = snprintf(rem_text + used, sizeof(rem_text) - used,
                             "%s%u:%" PRIu32, used ? "," : "", (unsigned)i,
                             remainders[i]);
            if (n < 0 || (size_t)n >= sizeof(rem_text) - used)
                break;
            used += (size_t)n;
        }
        uint32_t recent_count = recent_write < ACES2_SPI_DIAG_RECENT
                                    ? recent_write : ACES2_SPI_DIAG_RECENT;
        uint32_t recent_start = recent_write - recent_count;
        used = 0;
        for (uint32_t i = 0; i < recent_count; ++i) {
            uint32_t value = recent[(recent_start + i) % ACES2_SPI_DIAG_RECENT];
            int n = snprintf(recent_text + used, sizeof(recent_text) - used,
                             "%s%" PRIu32, used ? "," : "", value);
            if (n < 0 || (size_t)n >= sizeof(recent_text) - used)
                break;
            used += (size_t)n;
        }

        ESP_LOGI(TAG, "quadros_PCM=%" PRIu64 " SPI_incompletas=%" PRIu32
                 " quadros_invalidos=%" PRIu32 " crc=%" PRIu32
                 " seq=%" PRIu32 " descartadas=%" PRIu32
                 " blocos_descartados=%" PRIu32
                 " udp_erros=%" PRIu32 " blocos_livres=%u",
                 received_words, malformed_transactions, invalid_frames,
                 crc_errors, sequence_errors, dropped_samples,
                 dropped_blocks, udp_send_errors,
                 (unsigned)uxQueueMessagesWaiting(free_blocks));
        ESP_LOGI(TAG, "SPI len bits: total=%" PRIu32 " +1s=%" PRIu32
                 " exatos512=%" PRIu32 " +1s=%" PRIu32
                 " min=%" PRIu32 " max=%" PRIu32
                 " bins32{palavras:contagem}={%s} resto_mod32{resto:contagem}={%s}"
                 " recent_bits_oldest_first={%s}",
                 total, total - prev_total, exact, exact - prev_exact,
                 min_bits == UINT32_MAX ? 0 : min_bits, max_bits,
                 bins_text[0] ? bins_text : "none",
                 rem_text[0] ? rem_text : "none",
                 recent_text[0] ? recent_text : "none");
        uint32_t cs_rising = spi_cs_rising_edges;
        ESP_LOGI(TAG, "CS GPIO5 positive edges/s: %" PRIu32,
                 cs_rising - prev_cs_rising);
        prev_total = total;
        prev_exact = exact;
        prev_cs_rising = cs_rising;
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}

#if ACES2_WIFI_ENABLE
static void wifi_event_handler(void *arg, esp_event_base_t event_base,
                               int32_t event_id, void *event_data)
{
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        ESP_ERROR_CHECK(esp_wifi_connect());
    } else if (event_base == WIFI_EVENT &&
               event_id == WIFI_EVENT_STA_DISCONNECTED) {
        xEventGroupClearBits(wifi_events, WIFI_CONNECTED_BIT);
        esp_wifi_connect();
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "Wi-Fi conectado, IP=" IPSTR,
                 IP2STR(&event->ip_info.ip));
        xEventGroupSetBits(wifi_events, WIFI_CONNECTED_BIT);
    }
}

static void init_wifi(void)
{
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();

    wifi_init_config_t init_config = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init_config));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                                &wifi_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                &wifi_event_handler, NULL));

    wifi_config_t config = {0};
    strncpy((char *)config.sta.ssid, active_network_config.ssid,
            sizeof(config.sta.ssid) - 1);
    strncpy((char *)config.sta.password, active_network_config.password,
            sizeof(config.sta.password) - 1);
    config.sta.threshold.authmode = WIFI_AUTH_OPEN;
    config.sta.pmf_cfg.capable = true;
    config.sta.pmf_cfg.required = false;

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &config));
    ESP_ERROR_CHECK(esp_wifi_start());
}

static void udp_stream_task(void *arg)
{
    audio_block_t *block = NULL;
    uint32_t packet_count = 0;

    xEventGroupWaitBits(wifi_events, WIFI_CONNECTED_BIT, pdFALSE, pdTRUE,
                        portMAX_DELAY);
    int socket_fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    ESP_ERROR_CHECK(socket_fd >= 0 ? ESP_OK : ESP_FAIL);

    struct sockaddr_in destination = {0};
    destination.sin_family = AF_INET;
    destination.sin_port = htons(active_network_config.destination_port);
    destination.sin_addr.s_addr = inet_addr(active_network_config.destination_ip);

    while (true) {
        if (xQueueReceive(ready_blocks, &block, portMAX_DELAY) != pdTRUE)
            continue;

        audio_udp_header_t header = {
            .magic_be = htonl(active_network_config.udp_magic),
            .sequence_be = htonl(block->sequence),
            .sample_count_be = htons(block->count),
            .flags_be = 0,
        };

        /* Payload is already in host order. The receiver may use little-endian
         * payload directly; the header remains explicitly big-endian. */
        struct iovec vectors[2] = {
            { .iov_base = &header, .iov_len = sizeof(header) },
            { .iov_base = block->samples,
              .iov_len = block->count * sizeof(block->samples[0]) },
        };
        struct msghdr message = {
            .msg_name = &destination,
            .msg_namelen = sizeof(destination),
            .msg_iov = vectors,
            .msg_iovlen = 2,
        };
        if (sendmsg(socket_fd, &message, 0) < 0) {
            ++udp_send_errors;
            ESP_LOGW(TAG, "falha UDP: errno=%d", errno);
        } else {
            ++packet_count;
        }

        xQueueSend(free_blocks, &block, portMAX_DELAY);
        if ((packet_count & 0x3Fu) == 0u)
            ESP_LOGI(TAG, "UDP pacotes=%" PRIu32, packet_count);
    }
}
#endif

void app_main(void)
{
    /* The IDF SPI slave emits this alignment warning with ESP_EARLY_LOGW
     * from its ISR, so per-tag filtering does not suppress it. Silence early
     * warnings globally to avoid serial output in the hot path, then retain
     * INFO for this application's compact once-per-second diagnostics. */
    esp_log_level_set("*", ESP_LOG_ERROR);
    esp_log_level_set(TAG, ESP_LOG_INFO);
    esp_log_level_set("aces2_ble", ESP_LOG_INFO);

    free_blocks = xQueueCreate(ACES2_BLOCK_COUNT, sizeof(audio_block_t *));
#if ACES2_WIFI_ENABLE
    ready_blocks = xQueueCreate(ACES2_BLOCK_COUNT, sizeof(audio_block_t *));
    wifi_events = xEventGroupCreate();
#endif
    assert(free_blocks != NULL);

    for (size_t i = 0; i < ACES2_BLOCK_COUNT; ++i) {
        audio_block_t *block = &block_pool[i];
        xQueueSend(free_blocks, &block, 0);
    }

    init_spi_slave();
    for (size_t i = 0; i < ACES2_SPI_QUEUE_LEN; ++i) {
        prepare_slot(&slots[i]);
        ESP_ERROR_CHECK(spi_slave_queue_trans(ACES2_SPI_HOST,
                                              &slots[i].transaction,
                                              portMAX_DELAY));
    }

    ESP_LOGI(TAG, "SPI em blocos: CPU1, fila=%d, %d palavras/CS, %d blocos x %d",
             ACES2_SPI_QUEUE_LEN, ACES2_SPI_WORDS_PER_FRAME,
             ACES2_BLOCK_COUNT, ACES2_BLOCK_SAMPLES);

    esp_err_t nvs_result = nvs_flash_init();
    if (nvs_result == ESP_ERR_NVS_NO_FREE_PAGES ||
        nvs_result == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        nvs_result = nvs_flash_init();
    }
    ESP_ERROR_CHECK(nvs_result);
    aces2_network_config_load(&active_network_config);
    ESP_ERROR_CHECK(provisioning_ble_start());

#if ACES2_WIFI_ENABLE
    init_wifi();
    xTaskCreatePinnedToCore(udp_stream_task, "udp_stream", 6144, NULL, 4,
                            NULL, 0);
#endif

    xTaskCreatePinnedToCore(spi_receive_task, "spi_receive", 4096, NULL, 10,
                            NULL, 1);
    xTaskCreatePinnedToCore(stats_task, "spi_stats", 2048, NULL, 1,
                            NULL, 0);
    vTaskDelete(NULL);
}
