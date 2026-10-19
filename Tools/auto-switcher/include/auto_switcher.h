#ifndef ULTRACAM_AUTO_SWITCHER_H
#define ULTRACAM_AUTO_SWITCHER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AutoSwitcherHandle AutoSwitcherHandle;

AutoSwitcherHandle *auto_switcher_create(const char *config_json);
char *auto_switcher_process_json(AutoSwitcherHandle *handle, const char *event_json);
void auto_switcher_free_string(char *value);
void auto_switcher_destroy(AutoSwitcherHandle *handle);
const char *auto_switcher_version(void);

#ifdef __cplusplus
}
#endif

#endif
