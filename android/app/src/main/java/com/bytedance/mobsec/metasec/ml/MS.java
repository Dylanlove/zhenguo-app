package com.bytedance.mobsec.metasec.ml;

import android.content.Context;
import android.content.ContextWrapper;
import android.content.SharedPreferences;
import android.graphics.Point;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.Uri;
import android.os.Build;
import android.telephony.TelephonyManager;
import android.view.Display;
import android.view.WindowManager;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.UUID;
import java.util.regex.Pattern;
import ms.bd.c.ep0;
import ms.bd.c.f0;
import ms.bd.c.lp0;
import ms.bd.c.qy0;
import org.json.JSONArray;
import org.json.JSONObject;

public class MS extends f0 {
    private static Context application;
    private static byte[] certificate;
    private static JSONObject configuration;
    private static String deviceId;
    private static String directory;
    private static String fetchedDid = "";
    private static String installId;
    private static long managerHandle;
    private static final qy0 platform = new qy0();
    private static boolean ready;
    private static long responseHandle;
    private static long signingHandle;
    private static Throwable signingStack;

    public static Object callback(int type, int sub, long value, String payload, Object args) {
        String zero = "0";
        String emptyArray = "[]";
        Object nullValue = null;
        Context context = application;
        switch (type) {
            case 0x10001:
            case 0x1000011:
                return "6.9.5.32";
            case 0x10002:
            case 0x1000016:
                return "com.phoenix.read";
            case 0x10003:
                return directory;
            case 0x1000001:
                if (context == null) {
                    return null;
                }
                return context.getApplicationInfo().sourceDir;
            case 0x1000002:
                if (certificate == null) {
                    return null;
                }
                return certificate.clone();
            case 0x1000010:
                return Integer.valueOf(69532);
            case 0x1000012:
                if (configuration == null) {
                    return "";
                }
                return configuration.optString("channel");
            case 0x1000026:
                Throwable stack = signingStack;
                if (stack == null) {
                    return null;
                }
                return Arrays.toString(stack.getStackTrace());
            case 0x2000001:
                signingHandle = value;
                return Boolean.TRUE;
            case 0x2000002:
                responseHandle = value;
                return Boolean.TRUE;
            case 0x1000000e:
                return Long.valueOf(3);
            case 0x1000000f:
                return Long.valueOf(2000);
            default:
                break;
        }
        switch (type) {
            case 0x10006:
                return decode("1df6ac", new byte[]{0x0e, 0x69, 0x1b, 0x47});
            case 0x10008:
            case 0x1000031:
            case 0x1000039:
            case 0x10000004:
            case 0x10000005:
            case 0x100003e:
                return "";
            case 0x30001:
            case 0x30002:
            case 0x30003:
                return lp0.u(context, type, payload, args);
            case 0x1000003:
                return qy0.a(context);
            case 0x1000005:
                return String.valueOf(context.getResources().getDisplayMetrics().densityDpi);
            case 0x1000006:
                return qy0.c(context);
            case 0x1000007:
                return Integer.valueOf(255);
            case 0x1000009: {
                java.util.TimeZone zone = java.util.TimeZone.getDefault();
                try {
                    return zone.getID() + MS.decode("dac325", new byte[]{0x39}) + (zone.getRawOffset() / 3600000);
                } catch (Throwable ignored) {
                    return zone.getID();
                }
            }
            case 0x100000a: {
                java.util.Locale locale = context.getResources().getConfiguration().locale;
                return qy0.e(locale.getLanguage() + MS.decode("a78191", new byte[]{0x4f}) + locale.getCountry());
            }
            case 0x100000c: {
                File base = context.getFilesDir();
                File target = new File(base, MS.decode("57e7ad", new byte[]{
                    0x6a, 0x38, 0x05, 0x47, 0x5f, 0x67, 0x37}));
                target.mkdirs();
                return target.getAbsolutePath();
            }
            case 0x1000017:
                return String.valueOf(qy0.b(context, "level"));
            case 0x100001a: {
                java.util.Locale locale = context.getResources().getConfiguration().locale;
                return qy0.e(locale.getLanguage() + MS.decode("f1b2aa", new byte[]{0x48}) + locale.getCountry());
            }
            case 0x100001c:
                return qy0.g(context);
            case 0x100001d: {
                Object phone = context.getSystemService("phone");
                boolean result = false;
                if (phone instanceof TelephonyManager) {
                    result = ((TelephonyManager) phone).getSimState() == 5;
                }
                return Boolean.valueOf(result);
            }
            case 0x100001f:
                return new int[0];
            case 0x1000020:
                return Integer.valueOf(qy0.b(context, "status"));
            case 0x1000021:
                return Integer.valueOf(qy0.b(context, "voltage"));
            case 0x1000022: {
                Object[] list = args instanceof Object[] ? (Object[]) args : null;
                String key = list != null && list.length > 0 && list[0] instanceof String ? (String) list[0] : null;
                SharedPreferences prefs = context.getSharedPreferences(payload, 0);
                return prefs.getString(key, null);
            }
            case 0x1000023: {
                String separator = MS.decode("0cc163", new byte[]{0x1d, 0x7d});
                String[] parts = payload.split(Pattern.quote(separator), 2);
                if (parts.length == 2) {
                    Object[] list = args instanceof Object[] ? (Object[]) args : null;
                    String stored = list != null && list.length > 0 && list[0] instanceof String ? (String) list[0] : null;
                    SharedPreferences.Editor editor = context.getSharedPreferences(parts[0], 0).edit();
                    editor.putString(parts[1], stored);
                    editor.commit();
                    return null;
                }
                SharedPreferences prefs = context.getSharedPreferences(payload, 0);
                Object[] list = args instanceof Object[] ? (Object[]) args : null;
                String key = list != null && list.length > 0 && list[0] instanceof String ? (String) list[0] : null;
                return prefs.getString(key, null);
            }
            case 0x1000024: {
                Object service = context.getSystemService("connectivity");
                boolean result = false;
                if (service instanceof ConnectivityManager) {
                    android.net.NetworkInfo info = ((ConnectivityManager) service).getActiveNetworkInfo();
                    if (info != null) {
                        result = info.isConnected();
                    }
                }
                return Boolean.valueOf(result);
            }
            case 0x1000025:
                return UUID.randomUUID().toString();
            case 0x1000028:
                return decode("29a222", new byte[]{0x73});
            case 0x100002c:
                return Integer.valueOf(qy0.b(context, "health"));
            case 0x100002d: {
                Object service = context.getSystemService("connectivity");
                if (service instanceof ConnectivityManager) {
                    Network network = ((ConnectivityManager) service).getActiveNetwork();
                    NetworkCapabilities capabilities = network == null ? null : ((ConnectivityManager) service).getNetworkCapabilities(network);
                    if (capabilities != null && capabilities.hasTransport(4)) {
                        return decode("782aa7", new byte[]{0x77});
                    }
                }
                return decode("aa658b", new byte[]{0x20});
            }
            case 0x100002e:
                return qy0.d();
            case 0x1000032:
                return qy0.f();
            case 0x1000033:
                return Integer.valueOf(qy0.i(context));
            case 0x1000036:
                return decode("4b9991", new byte[]{0x75});
            case 0x100003a:
            case 0x100003b:
            case 0x100003c:
            case 0x100003d:
                return "0";
            case 0x10000001: {
                Point size = new Point();
                Object window = context.getSystemService("window");
                if (window instanceof WindowManager) {
                    Display display = ((WindowManager) window).getDefaultDisplay();
                    display.getRealSize(size);
                    return size.x + "*" + size.y;
                }
                return "0";
            }
            case 0x10000002:
            case 0x10000003:
                return "np";
            case 0x10000007:
                return "[]";
            case 0x10000008:
                return "null[<!>]null[<!>]0[<!>]";
            case 0x10000009:
                return qy0.h(context, true);
            case 0x1000000d:
                return qy0.h(context, false);
            default:
                break;
        }
        switch (type) {
            case 0x1000003:
                return emptyArray;
            case 0x1000006:
                return zero;
            case 0x1000007:
                return Integer.valueOf(255);
            case 0x100001c:
                return emptyArray;
            case 0x100001d:
                return Boolean.FALSE;
            case 0x100002d:
                return decode("8fb4bc", new byte[]{0x79});
            case 0x1000033:
                return Integer.valueOf(0);
            case 0x10000007:
                return emptyArray;
            default:
                return Integer.valueOf(0);
        }
    }

    public static void configure(Context base) {
        application = new ep0(base.getApplicationContext());
        configureDirectory(new File(base.getFilesDir(), "hongguo-runtime"));
    }

    public static void configureCertificate(byte[] value) {
        certificate = value == null ? null : value.clone();
    }

    public static void configureDirectory(File dir) {
        dir.mkdirs();
        File data = new File(dir, ".msdata");
        data.mkdirs();
        directory = data.getAbsolutePath();
    }

    public static String decode(String key, byte[] data) {
        Object result = ms.bd.c.m.a(16777217, 0, 0, key, data);
        if (result instanceof String) {
            return (String) result;
        }
        return "";
    }

    private static JSONArray flatten(JSONObject object) {
        JSONArray array = new JSONArray();
        if (object != null) {
            java.util.Iterator<String> keys = object.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                if (key.isEmpty()) {
                    continue;
                }
                array.put(key.trim());
                array.put(object.optString(key).trim());
            }
        }
        return array;
    }

    public static synchronized int initializeSdk(File configFile, String identity) {
        synchronized (MS.class) {
            if (ready) {
                return 0;
            }
            if (application == null) {
                return 40;
            }
            JSONObject config;
            try {
                java.io.ByteArrayOutputStream buffer = new java.io.ByteArrayOutputStream();
                java.io.InputStream input = new java.io.FileInputStream(configFile);
                try {
                    byte[] chunk = new byte[4096];
                    int read;
                    while ((read = input.read(chunk)) > 0) {
                        buffer.write(chunk, 0, read);
                    }
                } finally {
                    input.close();
                }
                config = new JSONObject(new String(buffer.toByteArray(), StandardCharsets.UTF_8));
            } catch (Throwable error) {
                return 41;
            }
            try {
                if (config.getInt("schemaVersion") != 1) {
                    return 41;
                }
                if (!"6.9.5.32".equals(config.getString("sdkVersion"))) {
                    return 41;
                }
                if (!"8662".equals(config.getString("appId"))) {
                    return 41;
                }
                if (config.getString("license").isEmpty()) {
                    return 41;
                }
            } catch (Throwable error) {
                return 41;
            }
            configuration = config;
            ms.bd.c.m.a(16777219, 0, 0, null, application);
            Object decoded = ms.bd.c.m.a(16777217, 0, 0, "23f920", new byte[]{
                0x35, 0x61, 0x41, 0x03, 0x5d, 0x70, 0x7f, 0x42, 0x66, 0x24,
                0x21, 0x24, 0x12, 0x4b, 0x04, 0x3f, 0x63});
            if (!(decoded instanceof String)) {
                return 42;
            }
            JSONArray fields = new JSONArray();
            try {
                fields.put(config.getString("appId").trim());
                fields.put(config.optString("sdkLicense").trim());
                fields.put(config.optString("sdkId").trim());
                fields.put(config.getString("license").trim());
                fields.put(((String) decoded).trim());
                fields.put(config.getString("channel").trim());
                fields.put("");
                fields.put("");
                fields.put("");
                fields.put("");
                fields.put(String.valueOf(config.getInt("clientType")));
                fields.put(String.valueOf(config.getInt("ovRegionType")));
                fields.put(String.valueOf(config.getInt("collectMode")));
                fields.put("");
                fields.put("0");
                fields.put(flatten(config.optJSONObject("customInfo")));
                fields.put(flatten(config.optJSONObject("advanceInfo")));
            } catch (Throwable error) {
                return 41;
            }
            Object initialized = ms.bd.c.m.a(67108865, 0, 0, fields.toString(), null);
            if (!Boolean.TRUE.equals(initialized)) {
                return 43;
            }
            Object handle = ms.bd.c.m.a(67108866, 0, 0, config.getString("appId"), null);
            if (handle instanceof Long) {
                long value = (Long) handle;
                if (value != -1 && value != 0 && managerHandle == 0) {
                    managerHandle = value;
                }
            }
            String settings = config.optString("defaultSettings");
            if (!settings.isEmpty()) {
                ms.bd.c.m.a(33554447, 0, managerHandle, settings, application);
            }
            ready = true;
            synchronizeIdentity(identity);
            ms.bd.c.m.a(33554433, 0, managerHandle, "cold_start", application);
            SharedPreferences state = application.getSharedPreferences("hongguo-sdk-state", 0);
            if (state.getBoolean("first_time", true)) {
                ms.bd.c.m.a(33554433, 0, managerHandle, "first_time", application);
                state.edit().putBoolean("first_time", false).apply();
            }
            return 0;
        }
    }

    public static synchronized String sign(String identity, String fields) {
        synchronized (MS.class) {
            if (!ready) {
                throw new IllegalStateException("红果 SDK 尚未完成初始化");
            }
            if (signingHandle == 0 && managerHandle == 0) {
                throw new IllegalStateException("红果 SDK 尚未完成初始化");
            }
            synchronizeIdentity(identity);
            ArrayList<String> list;
            try {
                String[] parts = fields.split("\r\n", -1);
                list = new ArrayList<String>(Arrays.asList(parts));
                if (!list.isEmpty() && list.get(list.size() - 1).isEmpty()) {
                    list.remove(list.size() - 1);
                }
            } catch (Throwable error) {
                signingStack = error;
                throw new IllegalArgumentException("红果签名请求字段无效");
            }
            if (list.size() % 2 != 0) {
                signingStack = new Throwable();
                throw new IllegalArgumentException("红果签名请求字段无效");
            }
            Object result = ms.bd.c.m.a(50331649, 0, signingHandle, identity, list.toArray(new String[0]));
            if (!(result instanceof String[])) {
                return null;
            }
            String[] values = (String[]) result;
            if (values.length % 2 != 0) {
                return null;
            }
            StringBuilder text = new StringBuilder();
            for (String value : values) {
                if (value == null) {
                    continue;
                }
                if (value.indexOf('\r') >= 0) {
                    continue;
                }
                if (value.indexOf('\n') >= 0) {
                    continue;
                }
                text.append(value).append("\r\n");
            }
            return text.toString();
        }
    }

    private static void synchronizeIdentity(String identity) {
        if (identity == null || identity.isEmpty()) {
            return;
        }
        boolean changed = false;
        try {
            Uri uri = Uri.parse(identity);
            String did = uri.getQueryParameter("device_id");
            String iid = uri.getQueryParameter("iid");
            if (did != null && !did.isEmpty() && !"0".equals(did) && !did.equals(deviceId)) {
                if (fetchedDid.isEmpty()) {
                    ms.bd.c.m.a(33554446, 0, managerHandle, did, Integer.valueOf(0));
                }
                fetchedDid = did;
                ms.bd.c.m.a(33554434, 0, managerHandle, did, application);
                deviceId = did;
                changed = true;
            }
            if (iid != null && !iid.isEmpty() && !"0".equals(iid) && !iid.equals(installId)) {
                ms.bd.c.m.a(33554435, 0, managerHandle, iid, application);
                installId = iid;
                changed = true;
            }
            if (changed) {
                ms.bd.c.m.a(33554433, 0, managerHandle, "did-iid-update", application);
            }
        } catch (Throwable ignored) {
        }
    }
}
