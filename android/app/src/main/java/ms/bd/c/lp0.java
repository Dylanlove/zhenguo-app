package ms.bd.c;

import com.bytedance.mobsec.metasec.ml.MS;
import android.content.Context;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.zip.GZIPInputStream;

public class lp0 {
    public static Object[] u(Context context, int command, String payload, Object args) {
        String url = null;
        String extra = null;
        byte[] body = null;
        File target = null;
        Object[] list = args instanceof Object[] ? (Object[]) args : null;
        if (command == 196609) {
            body = (byte[]) list[0];
            url = (String) list[1];
            extra = (String) list[2];
        } else if (command == 196610) {
            url = (String) list[0];
            extra = (String) list[1];
        } else if (command == 196611) {
            url = (String) list[1];
            extra = (String) list[2];
        }
        HttpURLConnection connection = null;
        OutputStream output = null;
        InputStream input = null;
        try {
            connection = (HttpURLConnection) new URL(payload).openConnection();
            connection.setConnectTimeout(12000);
            connection.setReadTimeout(12000);
            connection.setRequestProperty(MS.decode("8ebbf6", new byte[]{0x0a, 0x68, 0x1e, 0x1d, 0x50, 0x24}),
                MS.decode("85aa8a", new byte[]{0x3a, 0x32, 0x01, 0x06, 0x0e, 0x79, 0x35, 0x1d, 0x34, 0x6c}) + url);
            connection.setRequestProperty(MS.decode("233e42", new byte[]{0x02, 0x32, 0x43, 0x14, 0x1b, 0x31}),
                MS.decode("3d2dca", new byte[]{0x68, 0x29, 0x0b}));
            connection.setRequestProperty(MS.decode("b3c63f", new byte[]{0x46, 0x22, 0x15, 0x50, 0x41, 0x50, 0x66, 0x17, 0x3c, 0x72}),
                MS.decode("d84eff", new byte[]{0x57, 0x23, 0x53, 0x14, 0x7d, 0x70, 0x69, 0x1a, 0x60, 0x78, 0x58, 0x09, 0x74, 0x35, 0x72}));
            connection.setRequestProperty(MS.decode("cbac71", new byte[]{0x51, 0x6f, 0x1c, 0x03, 0x0d, 0x28, 0x74, 0x0e, 0x04, 0x2a, 0x62, 0x65}),
                MS.decode("ddc726", new byte[]{0x74, 0x76, 0x00, 0x4f, 0x04, 0x22, 0x66, 0x51, 0x3b, 0x68, 0x7b, 0x29, 0x1f, 0x40, 0x19, 0x24, 0x73, 0x08, 0x21, 0x73, 0x67, 0x63, 0x11, 0x4e}));
            if (extra != null && !extra.trim().isEmpty()) {
                connection.setRequestProperty(MS.decode("0effb1", new byte[]{0x39, 0x2a, 0x01, 0x06, 0x10, 0x34, 0x36, 0x55, 0x22, 0x33, 0x32, 0x73, 0x58, 0x06, 0x5c, 0x21}), extra);
            }
            if (body != null) {
                connection.setRequestMethod("POST");
                connection.setDoOutput(true);
                connection.setFixedLengthStreamingMode(body.length);
                output = connection.getOutputStream();
                output.write(body);
                output.close();
            }
            int code = connection.getResponseCode();
            input = code < 400 ? connection.getInputStream() : connection.getErrorStream();
            if (input == null) {
                connection.disconnect();
                return new Object[]{String.valueOf(code), null, Integer.valueOf(524293)};
            }
            if ("gzip".equalsIgnoreCase(connection.getContentEncoding())) {
                input = new GZIPInputStream(input);
            }
            byte[] result = null;
            if (command == 196611) {
                File requested = new File((String) list[0]).getCanonicalFile();
                String path = requested.getPath();
                String dataDir = context.getApplicationInfo().dataDir;
                if (!path.startsWith(new File(dataDir).getCanonicalPath() + File.separator)) {
                    connection.disconnect();
                    return new Object[]{"-1", null, Integer.valueOf(90000)};
                }
                target = requested;
                output = new FileOutputStream(target);
            } else {
                ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                output = buffer;
            }
            byte[] chunk = new byte[1024];
            int read;
            while ((read = input.read(chunk)) > 0) {
                output.write(chunk, 0, read);
            }
            output.flush();
            output.close();
            input.close();
            int status = code == 200 ? 200 : 524293;
            if (command == 196611) {
                return new Object[]{String.valueOf(code), null, Integer.valueOf(status)};
            }
            result = ((ByteArrayOutputStream) output).toByteArray();
            return new Object[]{String.valueOf(code), result, Integer.valueOf(status)};
        } catch (Throwable error) {
            if (output != null) {
                try {
                    output.close();
                } catch (Throwable ignored) {
                }
            }
            if (input != null) {
                try {
                    input.close();
                } catch (Throwable ignored) {
                }
            }
            int code = connection == null ? 99999 : 99999;
            return new Object[]{String.valueOf(code), null, Integer.valueOf(99999)};
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }
}
