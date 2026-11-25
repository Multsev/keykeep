#include <stdint.h>
void *kk_new(const char *path, const uint8_t *device_key);
char *kk_call(void *session, const char *request);
void kk_free_text(char *response);
void kk_close(void *session);
char *kk_authenticated_pin(void *session);
