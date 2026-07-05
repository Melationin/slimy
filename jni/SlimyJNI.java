/**
 * JNI wrapper for the Slimy slime chunk cluster finder.
 *
 * <h3>Coordinate system</h3>
 * All x/z coordinates are in <b>chunk</b> units, not block units.
 * Multiply by 16 to get block coordinates.
 * <p>
 * Example: chunk (949, -923) = block (15184, -14768).
 *
 * <h3>Usage</h3>
 * <pre>
 *   System.loadLibrary("slimy_jni");
 *   int[] raw = SlimyJNI.search(seed, x0, z0, x1, z1, threshold, maxResults, threads);
 *   // raw = {x, z, count, x, z, count, ...} (3 ints per result, sorted by count desc)
 * </pre>
 */
public class SlimyJNI {
    static {
        SlimyLoader.load();
    }

    /**
     * Search for slime chunk clusters in the given rectangular region.
     *
     * @param worldSeed   Minecraft world seed
     * @param x0          left chunk coordinate (inclusive), in chunks
     * @param z0          top chunk coordinate (inclusive), in chunks
     * @param x1          right chunk coordinate (exclusive), in chunks
     * @param z1          bottom chunk coordinate (exclusive), in chunks
     * @param threshold   minimum slime chunk count in the despawn sphere (ring: 2..8 chunk radius)
     * @param maxResults  maximum number of results to return (excess silently dropped)
     * @param threadCount number of CPU threads to use (1 = single-threaded)
     * @return flat int array, 3 ints per result: {x, z, count} in chunks,
     *         sorted by count descending then distance from origin
     */
    public static native int[] search(
        long worldSeed,
        int x0, int z0,
        int x1, int z1,
        int threshold,
        int maxResults,
        int threadCount
    );
}
