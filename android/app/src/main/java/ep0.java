import android.content.Context;
import android.content.ContextWrapper;
import android.content.pm.ApplicationInfo;

public class ep0 extends ContextWrapper {
    public ep0(Context base) {
        super(base);
        attachBaseContext(base);
    }

    @Override
    public Context getApplicationContext() {
        return this;
    }

    @Override
    public ApplicationInfo getApplicationInfo() {
        ApplicationInfo info = new ApplicationInfo(super.getApplicationInfo());
        info.packageName = "com.phoenix.read";
        return info;
    }

    @Override
    public String getPackageName() {
        return "com.phoenix.read";
    }
}
