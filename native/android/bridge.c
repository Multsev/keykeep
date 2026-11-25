#include "KeyKeep.h"
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#define NATIVE(name) Java_com_max_keykeep_1passwords_VaultBridge_##name

// Transport UTF-8 bytes explicitly. JNI modified UTF-8 breaks supplementary Unicode characters.
static char *text(JNIEnv *env, jbyteArray input) {
    jsize n = (*env)->GetArrayLength(env, input);
    char *result = calloc((size_t)n + 1, 1);
    if (result) (*env)->GetByteArrayRegion(env, input, 0, n, (jbyte *)result);
    return result;
}
static jbyteArray answer(JNIEnv *env, char *result) {
    if (!result) return NULL;
    size_t n = strlen(result);
    jbyteArray bytes = (*env)->NewByteArray(env, (jsize)n);
    if (bytes) (*env)->SetByteArrayRegion(env, bytes, 0, (jsize)n, (jbyte *)result);
    kk_free_text(result);
    return bytes;
}
JNIEXPORT jlong JNICALL NATIVE(open)(JNIEnv *env, jclass cls, jbyteArray path, jbyteArray key) {
    if ((*env)->GetArrayLength(env, key) != 32) return 0;
    uint8_t device[32];
    (*env)->GetByteArrayRegion(env, key, 0, 32, (jbyte *)device);
    char *name = text(env, path);
    void *session = kk_new(name, device);
    free(name);
    return (jlong)(intptr_t)session;
}
JNIEXPORT jbyteArray JNICALL NATIVE(request)(JNIEnv *env, jclass cls, jlong handle, jbyteArray input) {
    char *query = text(env, input);
    char *response = kk_call((void *)(intptr_t)handle, query);
    free(query);
    return answer(env, response);
}
JNIEXPORT jbyteArray JNICALL NATIVE(authenticatedPin)(JNIEnv *env, jclass cls, jlong handle) {
    return answer(env, kk_authenticated_pin((void *)(intptr_t)handle));
}
JNIEXPORT void JNICALL NATIVE(close)(JNIEnv *env, jclass cls, jlong handle) {
    kk_close((void *)(intptr_t)handle);
}
