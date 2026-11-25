package ms.bd.c;

import com.bytedance.mobsec.metasec.ml.MS;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.KeyguardManager;
import android.content.Context;
import android.net.DhcpInfo;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.PowerManager;
import android.provider.Settings;
import android.telephony.TelephonyManager;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityManager;
import android.view.inputmethod.InputMethodInfo;
import android.view.inputmethod.InputMethodManager;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.util.HashSet;
import java.util.Iterator;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

public class qy0 {
    public static String a(Context context) {
        JSONArray array = new JSONArray();
        Object service = context.getSystemService("accessibility");
        if (service instanceof AccessibilityManager) {
            List<AccessibilityServiceInfo> enabled = ((AccessibilityManager) service).getEnabledAccessibilityServiceList(-1);
            if (enabled != null) {
                Iterator<AccessibilityServiceInfo> it = enabled.iterator();
                while (it.hasNext()) {
                    AccessibilityServiceInfo info = it.next();
                    try {
                        JSONObject item = new JSONObject();
                        item.put(MS.decode("f8c8c1", new byte[]{0x72, 0x2c}), info.eventTypes);
                        item.put(MS.decode("f78076", new byte[]{0x7e, 0x31}), info.getId());
                        array.put(item);
                    } catch (Throwable ignored) {
                    }
                }
            }
        }
        return array.toString();
    }

    public static int b(Context context, String key) {
        try {
            android.content.Intent intent = context.registerReceiver(null, new android.content.IntentFilter("android.intent.action.BATTERY_CHANGED"));
            if (intent == null) {
                return -1;
            }
            if (key.equals("level")) {
                int level = intent.getIntExtra("level", -1);
                int scale = intent.getIntExtra("scale", -1);
                if (scale <= 0) {
                    return -1;
                }
                return Math.round(level * 100.0f / scale);
            }
            return intent.getIntExtra(key, -1);
        } catch (Throwable ignored) {
            return -1;
        }
    }

    public static String c(Context context) {
        try {
            Class<?> profile = Class.forName("com.android.internal.os.PowerProfile");
            Constructor<?> ctor = profile.getConstructor(Context.class);
            Object instance = ctor.newInstance(new Object[]{context});
            Method method = profile.getMethod("getAveragePower", String.class);
            Object value = method.invoke(instance, new Object[]{"battery.capacity"});
            return String.valueOf(((Double) value).intValue());
        } catch (Throwable ignored) {
            return "0";
        }
    }

    public static String d() {
        String[] features = new String[]{
            MS.decode("5a833f", new byte[]{0x2b, 0x73, 0x5b, 0x48}),
            MS.decode("4caac2", new byte[]{0x28, 0x68, 0x07, 0x1c}),
            MS.decode("92445b", new byte[]{0x3e, 0x39, 0x51, 0x4f}),
            MS.decode("91d3dd", new byte[]{0x25, 0x36, 0x1e, 0x5d, 0x4e}),
            MS.decode("860935", new byte[]{0x3b, 0x31, 0x47, 0x40, 0x05}),
            MS.decode("f670be", new byte[]{0x6f, 0x3d, 0x45, 0x4b, 0x50, 0x7b}),
            MS.decode("5c154a", new byte[]{0x2c, 0x74, 0x43, 0x56, 0x0e, 0x7f}),
            MS.decode("542692", new byte[]{0x2b, 0x38, 0x44, 0x52, 0x0a, 0x30, 0x25}),
            MS.decode("ff8baa", new byte[]{0x7b, 0x6d, 0x45, 0x13, 0x5f, 0x71, 0x60}),
            MS.decode("b6a642", new byte[]{0x60, 0x35, 0x1f, 0x51, 0x1e, 0x2b, 0x66}),
            MS.decode("58fd17", new byte[]{0x3c, 0x2a, 0x1a, 0x03, 0x0b, 0x24}),
            MS.decode("35746d", new byte[]{0x6c, 0x3b, 0x41, 0x55, 0x00, 0x3d}),
            MS.decode("9db538", new byte[]{0x3a, 0x63, 0x10, 0x4d, 0x01, 0x2a}),
            MS.decode("837700", new byte[]{0x28, 0x22, 0x51, 0x50}),
            MS.decode("90669f", new byte[]{0x2a, 0x3e, 0x44, 0x41, 0x0d, 0x62, 0x32, 0x10, 0x75, 0x6d}),
            MS.decode("8ab30c", new byte[]{0x24, 0x66, 0x18, 0x53, 0x1a}),
            MS.decode("28429c", new byte[]{0x2f, 0x33, 0x45, 0x55, 0x13}),
            MS.decode("b20c69", new byte[]{0x7c, 0x20, 0x4f, 0x02, 0x1a}),
            MS.decode("485c55", new byte[]{0x2d, 0x35, 0x48, 0x18, 0x18})
        };
        HashSet<String> found = new HashSet<String>();
        try {
            Class<?> target = Class.forName(MS.decode("ebec1b", new byte[]{
                0x75, 0x6e, 0x12, 0x05, 0x01, 0x7c, 0x62, 0x0d, 0x3b, 0x20,
                0x3a, 0x53, 0x13, 0x05, 0x18, 0x7c, 0x65, 0x46, 0x19, 0x32,
                0x7a, 0x61, 0x11, 0x12, 0x1c}));
            Method getter = target.getDeclaredMethod(MS.decode("4779b3", new byte[]{
                0x29, 0x3c, 0x57, 0x59, 0x6e, 0x21, 0x25, 0x00, 0x6f, 0x6a, 0x20, 0x26}));
            getter.setAccessible(true);
            String[] values = (String[]) getter.invoke(null, new Object[]{null});
            if (values != null) {
                for (String value : values) {
                    for (int i = 0; i < 19 && i < features.length; i++) {
                        if (value.toLowerCase().contains(features[i])) {
                            found.add(features[i]);
                        }
                    }
                }
            }
        } catch (Throwable ignored) {
        }
        return found.toString();
    }

    public static String e(String value) {
        return value.trim()
            .replace('\'', ' ')
            .replace('"', ' ')
            .replace('\r', ' ')
            .replace('\n', ' ');
    }

    public static String f() {
        JSONObject object = new JSONObject();
        try {
            object.put(MS.decode("b8ada5", new byte[]{0x22}), Build.MODEL);
            object.put(MS.decode("840d1f", new byte[]{0x7b}), Build.BRAND);
            object.put(MS.decode("41181f", new byte[]{0x76}), Build.BOARD);
            object.put(MS.decode("a55528", new byte[]{0x24}), Build.VERSION.RELEASE);
            object.put(MS.decode("def8d9", new byte[]{0x20}), Build.DISPLAY);
            object.put(MS.decode("84f821", new byte[]{0x7f}), Build.HARDWARE);
            object.put(MS.decode("0eac08", new byte[]{0x7f}), Build.FINGERPRINT);
        } catch (Throwable ignored) {
        }
        return object.toString();
    }

    public static String g(Context context) {
        JSONArray array = new JSONArray();
        try {
            WifiManager wifi = (WifiManager) context.getApplicationContext().getSystemService("wifi");
            DhcpInfo info = wifi == null ? null : wifi.getDhcpInfo();
            if (info != null) {
                int[] servers = {info.dns1, info.dns2};
                for (int i = 0; i < 2; i++) {
                    int raw = servers[i];
                    array.put(((raw) & 255) + "." + ((raw >> 8) & 255) + "." + ((raw >> 16) & 255) + "." + ((raw >> 24) & 255));
                }
            }
        } catch (Throwable ignored) {
        }
        return array.toString();
    }

    public static String h(Context context, boolean detailed) {
        String current = Settings.Secure.getString(context.getContentResolver(), "default_input_method");
        StringBuilder builder;
        if (current != null && !current.isEmpty()) {
            builder = new StringBuilder(current.split("/")[0]);
        } else {
            builder = new StringBuilder("null_");
        }
        if (detailed) {
            Object service = context.getSystemService("input_method");
            if (service instanceof InputMethodManager) {
                List<InputMethodInfo> methods = ((InputMethodManager) service).getInputMethodList();
                if (methods != null) {
                    for (InputMethodInfo info : methods) {
                        String pkg = info.getPackageName();
                        if (pkg == null || pkg.isEmpty() || builder.indexOf(pkg) >= 0) {
                            continue;
                        }
                        builder.append("[<!>]").append(pkg);
                    }
                }
            }
        }
        return builder.toString();
    }

    public static int i(Context context) {
        Object power = context.getSystemService("power");
        if (power instanceof PowerManager) {
            if (!((PowerManager) power).isInteractive()) {
                return 1;
            }
        } else {
            return 1;
        }
        Object keyguard = context.getSystemService("keyguard");
        if (keyguard instanceof KeyguardManager) {
            if (((KeyguardManager) keyguard).inKeyguardRestrictedInputMode()) {
                return 2;
            }
            return 3;
        }
        return 0;
    }
}
