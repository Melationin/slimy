import java.io.*;
import java.nio.file.*;

/**
 * Loads the Slimy native library, extracting it from the JAR if needed.
 */
public class SlimyLoader {
    private static volatile boolean loaded = false;

    /** Call once before using SlimyJNI. Safe to call multiple times. */
    public static synchronized void load() {
        if (loaded) return;

        try {
            // Try java.library.path first
            System.loadLibrary("slimy_jni");
            loaded = true;
            return;
        } catch (UnsatisfiedLinkError e) {
            // Not on library path, extract from JAR
        }

        try {
            String os = System.getProperty("os.name").toLowerCase();
            String arch = System.getProperty("os.arch").toLowerCase();
            String libName;
            if (os.contains("win")) {
                libName = "slimy_jni.dll";
            } else if (os.contains("mac")) {
                libName = "libslimy_jni.dylib";
            } else {
                libName = "libslimy_jni.so";
            }
            // Map arch to our build names
            String archDir;
            if (arch.contains("aarch64") || arch.contains("arm64")) {
                archDir = "aarch64";
            } else {
                archDir = "x86_64";
            }

            String osDir = os.contains("win") ? "windows" : os.contains("mac") ? "macos" : "linux";
            String resourcePath = "/lib/" + archDir + "/" + osDir + "/" + libName;
            InputStream in = SlimyLoader.class.getResourceAsStream(resourcePath);
            if (in == null) {
                // Fallback: try root of lib/
                in = SlimyLoader.class.getResourceAsStream("/lib/" + libName);
            }
            if (in == null) {
                throw new UnsatisfiedLinkError("Cannot find slimy_jni native library in JAR. "
                    + "Tried: " + resourcePath + " and /lib/" + libName);
            }

            Path tmp = Files.createTempFile("slimy_jni_", "." + libName);
            tmp.toFile().deleteOnExit();
            Files.copy(in, tmp, StandardCopyOption.REPLACE_EXISTING);
            in.close();

            System.load(tmp.toAbsolutePath().toString());
            loaded = true;
        } catch (IOException ex) {
            throw new UnsatisfiedLinkError("Failed to extract native library: " + ex.getMessage());
        }
    }
}
