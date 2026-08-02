#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

typedef struct TouchHLEIOSGameMetadata TouchHLEIOSGameMetadata;

TouchHLEIOSGameMetadata *touchhle_ios_game_metadata_create(const char *path);
const char *touchhle_ios_game_metadata_display_name(const TouchHLEIOSGameMetadata *metadata);
const char *touchhle_ios_game_metadata_bundle_identifier(const TouchHLEIOSGameMetadata *metadata);
uint32_t touchhle_ios_game_metadata_orientation_capabilities(const TouchHLEIOSGameMetadata *metadata);
const uint8_t *touchhle_ios_game_metadata_icon_rgba(const TouchHLEIOSGameMetadata *metadata);
uint32_t touchhle_ios_game_metadata_icon_width(const TouchHLEIOSGameMetadata *metadata);
uint32_t touchhle_ios_game_metadata_icon_height(const TouchHLEIOSGameMetadata *metadata);
void touchhle_ios_game_metadata_free(TouchHLEIOSGameMetadata *metadata);

int32_t touchhle_ios_launch_game(
    const char *path,
    int32_t scale_hack,
    int32_t orientation,
    int32_t network_access,
    int32_t analog_stick_tilt_controls
);

void touchhle_ios_request_exit(void);
float touchhle_ios_current_fps(void);

bool touchhle_ios_jit_available(void);
bool touchhle_ios_jit_is_from_debugger(void);

/// Raw signals behind the JIT verdict, so a wrong verdict can be diagnosed on
/// device instead of guessed at.
typedef struct {
    int csops_result;
    int csops_errno;
    unsigned int cs_flags;
    bool cs_debugged;
    bool has_dynamic_codesigning;
    bool mmap_rwx_ok;
    bool mprotect_exec_ok;
} TouchHLEJITDiagnostics;

void touchhle_ios_jit_diagnostics(TouchHLEJITDiagnostics *out);
void touchhle_ios_log_jit_status(const char *context);
