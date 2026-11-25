//go:build android && cgo

package core

/*
#include <jni.h>
#include <stdlib.h>
#include <string.h>

extern JavaVM *duanjuJavaVM;
extern jclass duanjuMetasecClass;
extern jmethodID duanjuMetasecSignMethod;

static int hongguoRuntimeReadyC(void) {
    return duanjuJavaVM != NULL && duanjuMetasecClass != NULL && duanjuMetasecSignMethod != NULL;
}

static char *hongguoRuntimeSignCall(const char *identity, const char *fields) {
    if (duanjuJavaVM == NULL || duanjuMetasecClass == NULL || duanjuMetasecSignMethod == NULL) {
        return NULL;
    }
    JNIEnv *env = NULL;
    jint status = (*duanjuJavaVM)->GetEnv(duanjuJavaVM, (void **)&env, JNI_VERSION_1_6);
    int attached = 0;
    if (status == JNI_EDETACHED) {
        if ((*duanjuJavaVM)->AttachCurrentThread(duanjuJavaVM, (void **)&env, NULL) != JNI_OK) {
            return NULL;
        }
        attached = 1;
    } else if (status != JNI_OK || env == NULL) {
        return NULL;
    }
    jstring identityString = (*env)->NewStringUTF(env, identity);
    jstring fieldsString = fields == NULL ? NULL : (*env)->NewStringUTF(env, fields);
    char *output = NULL;
    if (identityString == NULL || fieldsString == NULL) {
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
        }
    } else {
        jstring result = (jstring)(*env)->CallStaticObjectMethod(
            env, duanjuMetasecClass, duanjuMetasecSignMethod, identityString, fieldsString);
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
        } else if (result != NULL) {
            const char *utf = (*env)->GetStringUTFChars(env, result, NULL);
            if (utf != NULL) {
                output = strdup(utf);
                (*env)->ReleaseStringUTFChars(env, result, utf);
            }
            (*env)->DeleteLocalRef(env, result);
        }
    }
    if (identityString != NULL) (*env)->DeleteLocalRef(env, identityString);
    if (fieldsString != NULL) (*env)->DeleteLocalRef(env, fieldsString);
    if (attached) (*duanjuJavaVM)->DetachCurrentThread(duanjuJavaVM);
    return output;
}
*/
import "C"
import "unsafe"

func hongguoRuntimeAvailable() bool {
    return C.hongguoRuntimeReadyC() != 0
}

func hongguoRuntimeSign(identity, fields string) string {
    cIdentity := C.CString(identity)
    defer C.free(unsafe.Pointer(cIdentity))
    cFields := C.CString(fields)
    defer C.free(unsafe.Pointer(cFields))
    result := C.hongguoRuntimeSignCall(cIdentity, cFields)
    if result == nil {
        return ""
    }
    text := C.GoString(result)
    C.free(unsafe.Pointer(result))
    return text
}
