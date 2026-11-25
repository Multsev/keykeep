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
JNIEXPORT jlong JNICALL NATIVE(open)(JNIEnv *env, jclass cls, jbyteArray path) {
    char *name = text(env, path);
    void *session = kk_new(name);
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

static jboolean supply_key(JNIEnv *env, jlong handle, jbyteArray key, bool finishing) {
    if ((*env)->GetArrayLength(env, key) != 32) return JNI_FALSE;
    uint8_t device[32];
    (*env)->GetByteArrayRegion(env, key, 0, 32, (jbyte *)device);
    void *session = (void *)(intptr_t)handle;
    jboolean result = finishing ? kk_finish_erasure(session, device) : kk_initialize_device(session, device);
    volatile uint8_t *clear = device;
    for (size_t i = 0; i < sizeof(device); i++) clear[i] = 0;
    return result;
}

JNIEXPORT jboolean JNICALL NATIVE(finishErasure)(JNIEnv *env,jclass cls,jlong handle,jbyteArray key){
    return supply_key(env,handle,key,true);
}
JNIEXPORT jboolean JNICALL NATIVE(initializeDevice)(JNIEnv *env,jclass cls,jlong handle,jbyteArray key){
    return supply_key(env,handle,key,false);
}
JNIEXPORT jboolean JNICALL NATIVE(erasing)(JNIEnv *env,jclass cls,jlong handle){
    return kk_erasing((void *)(intptr_t)handle);
}
