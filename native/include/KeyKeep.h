#include <stdbool.h>
#include <stdint.h>
void *kk_new(const char *path);
char *kk_call(void *session, const char *request);
void kk_free_text(char *response);
void kk_close(void *session);
char *kk_authenticated_pin(void *session);
bool kk_finish_erasure(void *session, const uint8_t *new_key);
bool kk_erasing(void *session);
bool kk_initialize_device(void *session, const uint8_t *key);
