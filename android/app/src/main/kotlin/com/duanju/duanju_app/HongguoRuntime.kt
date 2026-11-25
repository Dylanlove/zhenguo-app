package com.duanju.duanju_app

import android.content.Context
import android.util.Log
import com.bytedance.mobsec.metasec.ml.MS
import java.io.File

object HongguoRuntime {
    private const val TAG = "HongguoRuntime"
    private const val RUNTIME_DIR = "hongguo-runtime"
    private const val ASSET_DIR = "hongguo_runtime"

    @Volatile
    private var booted = false

    fun bootstrap(context: Context) {
        if (booted) return
        synchronized(this) {
            if (booted) return
            booted = true
            try {
                System.loadLibrary("duanju_core")
            } catch (error: Throwable) {
                Log.w(TAG, "duanju_core 加载失败: ${error.message}")
            }
            try {
                System.loadLibrary("metasec_ml")
            } catch (error: Throwable) {
                Log.w(TAG, "metasec 加载失败: ${error.message}")
                return
            }
            try {
                val application = context.applicationContext
                val directory = File(application.filesDir, RUNTIME_DIR)
                directory.mkdirs()
                val config = prepareAsset(application, "sdk-config.json")
                val certificate = prepareAsset(application, "apk-signer-certificate.der")
                MS.configure(application)
                MS.configureCertificate(certificate.readBytes())
                val code = MS.initializeSdk(config, "")
                Log.i(TAG, "metasec 初始化返回 $code")
            } catch (error: Throwable) {
                Log.w(TAG, "metasec 初始化失败: ${error.message}")
            }
        }
    }

    private fun prepareAsset(context: Context, name: String): File {
        val target = File(File(context.filesDir, RUNTIME_DIR), name)
        context.assets.open("$ASSET_DIR/$name").use { input ->
            val expected = input.available().toLong()
            val existing = if (target.exists()) target.length() else -1L
            if (existing == expected) {
                return target
            }
            val temporary = File(target.parentFile, "$name.tmp")
            temporary.outputStream().use { output -> input.copyTo(output) }
            if (!temporary.renameTo(target) && target.exists()) {
                target.delete()
                if (!temporary.renameTo(target)) throw IllegalStateException("红果运行时资产释放失败: $name")
            }
        }
        return target
    }
}
