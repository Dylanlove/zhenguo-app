#include <jni.h>

JavaVM *duanjuJavaVM = NULL;
jclass duanjuMetasecClass = NULL;
jmethodID duanjuMetasecSignMethod = NULL;

jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    duanjuJavaVM = vm;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        return JNI_VERSION_1_6;
    }
    jclass local = (*env)->FindClass(env, "com/bytedance/mobsec/metasec/ml/MS");
    if (local != NULL) {
        duanjuMetasecClass = (jclass)(*env)->NewGlobalRef(env, local);
        (*env)->DeleteLocalRef(env, local);
        duanjuMetasecSignMethod = (*env)->GetStaticMethodID(
            env, duanjuMetasecClass, "sign",
            "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
        if (duanjuMetasecSignMethod == NULL) {
            (*env)->ExceptionClear(env);
        }
    } else {
        (*env)->ExceptionClear(env);
    }
    return JNI_VERSION_1_6;
}
