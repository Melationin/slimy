/**
 * Simple test for SlimyJNI.
 * <p>
 * Before running, ensure slimy_jni.dll is on java.library.path:
 * <pre>
 *   java -Djava.library.path=../zig-out/bin jni-test.SlimyTest
 * </pre>
 * Or copy slimy_jni.dll to the current directory / system path.
 */
public class SlimyTest {

    // Known test data from the Slimy project benchmarks
    static final long TEST_SEED = -2152535657050944081L;
    static final int[][] EXPECTED = {
        { 949, -923, 43 },
        { 950, -924, 42 },
        { 245,  481, 40 },
        { 246,  484, 40 },
        {-624, -339, 40 },
        { 669, -643, 40 },
        {-623, -701, 40 },
        { 948, -923, 40 },
        { 949, -924, 40 },
        { 950, -923, 40 },
        { 950, -926, 40 },
        { 327, -140, 39 },
        {-423,   50, 39 },
        { 430,  298, 39 },
        {-554,  270, 39 },
        { 664,  356, 39 },
        { 715, -375, 39 },
        { 716, -375, 39 },
        {-309,  800, 39 },
        {-310,  800, 39 },
        {-726, -575, 39 },
        {-725, -579, 39 },
        {-726, -579, 39 },
        { 671, -644, 39 },
        {-624, -701, 39 },
        {-883,  338, 39 },
        { 684, -752, 39 },
        {-700,  758, 39 },
        {-636,  843, 39 },
        { 949, -922, 39 },
        { 951, -923, 39 },
        { 949, -926, 39 },
        { 951, -924, 39 },
        { 950, -928, 39 },
    };

    public static void main(String[] args) {
        System.out.println("SlimyJNI test");
        System.out.println("=============");
        System.out.println();

        long t0 = System.nanoTime();
        int[] raw = SlimyJNI.search(
            TEST_SEED,
            -1000, -1000, 1000, 1000,
            39,
            10000,
            Runtime.getRuntime().availableProcessors()
        );
        long t1 = System.nanoTime();
        double elapsed = (t1 - t0) / 1_000_000_000.0;

        int resultCount = raw.length / 3;
        System.out.printf("Found %,d results in %.3f s%n%n", resultCount, elapsed);

        if (resultCount != EXPECTED.length) {
            System.err.printf("FAIL: expected %d results, got %d%n", EXPECTED.length, resultCount);
            System.exit(1);
        }

        int mismatches = 0;
        for (int i = 0; i < resultCount; i++) {
            int x = raw[i * 3];
            int z = raw[i * 3 + 1];
            int count = raw[i * 3 + 2];
            if (i < EXPECTED.length) {
                if (x != EXPECTED[i][0] || z != EXPECTED[i][1] || count != EXPECTED[i][2]) {
                    System.err.printf("MISMATCH at #%d: expected (%d,%d,%d) got (%d,%d,%d)%n",
                        i, EXPECTED[i][0], EXPECTED[i][1], EXPECTED[i][2], x, z, count);
                    mismatches++;
                }
            }
        }

        if (mismatches > 0) {
            System.err.printf("%nFAIL: %d mismatches%n", mismatches);
            System.exit(1);
        } else {
            System.out.println("All results match expected values — PASS");
        }

        // Print top 5
        System.out.println();
        System.out.println("Top 5 results:");
        for (int i = 0; i < Math.min(5, resultCount); i++) {
            System.out.printf("  (%5d, %5d) → %d%n", raw[i * 3], raw[i * 3 + 1], raw[i * 3 + 2]);
        }
    }
}
