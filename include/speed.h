#ifndef SPEED_H
#define SPEED_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    SPEED_PHASE_LATENCY,
    SPEED_PHASE_DOWNLOAD,
    SPEED_PHASE_UPLOAD,
} speed_phase;

typedef enum {
    SPEED_OK,
    /* The server is throttling this IP; retry in a few minutes. */
    SPEED_RATE_LIMITED,
    SPEED_DNS,
    SPEED_NETWORK,
    SPEED_OUT_OF_MEMORY,
    /* duration_ms below 2000. */
    SPEED_INVALID_OPTIONS,
} speed_status;

/* Zero fields take their defaults. */
typedef struct {
    const char *host;     /* "speed.cloudflare.com" */
    uint8_t streams;      /* 6 parallel connections */
    uint32_t duration_ms; /* 8000 per direction, less once throughput settles */
    uint16_t pings;       /* 20 idle latency samples */
} speed_options;

typedef struct {
    double p10, p50, p90;
} speed_summary;

typedef struct {
    speed_summary bps;
    speed_summary latency_ms;         /* round trip while saturated */
    speed_summary gateway_latency_ms; /* to the router while saturated; NaN if unknown */
} speed_load;

typedef struct {
    speed_summary latency_ms; /* idle round trip to the router; NaN if unknown */
    uint8_t wireless;         /* 1 when reached over Wi-Fi */
} speed_gateway;

typedef enum {
    SPEED_SEGMENT_NONE, /* nothing noticeable, or the router is unknown */
    SPEED_SEGMENT_LOCAL, /* Wi-Fi, cabling or the router */
    SPEED_SEGMENT_ISP,   /* the line beyond the router */
} speed_segment;

/* Which side of the router makes the connection feel slow. */
typedef struct {
    speed_segment segment;
    speed_phase phase; /* LATENCY: every request; DOWNLOAD/UPLOAD: while busy that way */
    double added_ms;
} speed_verdict;

typedef struct {
    char colo[4]; /* edge location code, e.g. "CDG"; empty if unknown */
    uint32_t asn; /* 0 if unknown */
    double dns_ms;
    speed_summary latency_ms;
    double jitter_ms;
    double loss; /* fraction of ICMP echoes lost; NaN if ICMP is denied */
    speed_load download;
    speed_load upload;
    speed_gateway gateway;
    speed_verdict verdict;
    char isp[64]; /* network operator, e.g. "Orange S.A."; empty if unknown */
} speed_result;

/* `value` is ms during SPEED_PHASE_LATENCY, bits per second otherwise.
 * `progress` is the completion of the phase in [0, 1]. Called on the thread
 * that called speed_run. */
typedef void (*speed_progress)(void *context, speed_phase phase, double value, float progress);

/* Blocks for the whole test (about 20 seconds). `options` and `progress` may
 * be NULL. Thread-safe; each call is independent. */
speed_status speed_run(const speed_options *options, speed_progress progress, void *context, speed_result *out);

#ifdef __cplusplus
}
#endif

#endif
