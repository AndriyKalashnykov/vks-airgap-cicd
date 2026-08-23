package com.vmware.vks.demo.javawebapp;

import java.net.HttpURLConnection;
import java.net.URI;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/** Entry point for the air-gapped VKS CI/CD demo web UI. */
@SpringBootApplication
public class JavaWebappApplication {

    /** Exit code convention for the container HEALTHCHECK: 0 = healthy, 1 = not. */
    private static final int HEALTHY = 0;
    private static final int UNHEALTHY = 1;

    /** Matches the HEALTHCHECK's --timeout, so the probe cannot outlive the deadline Docker gives it. */
    private static final int PROBE_TIMEOUT_MS = 3000;

    private static final String HEALTHCHECK_FLAG = "--healthcheck";
    private static final String DEFAULT_PORT = "8080";
    private static final String HEALTH_PATH = "/healthz";

    /**
     * Probes this container's own HTTP endpoint for the Docker/podman HEALTHCHECK.
     *
     * <p>This exists so the runtime image needs NO extra package. It used to be {@code curl}, which the
     * runtime stage installed with {@code apt-get} — a network reach in the one stage kaniko builds
     * IN-CLUSTER, where there is no egress. Every sibling app already probes with its own runtime
     * ({@code gowebapp -healthcheck}, {@code node -e fetch(...)}, {@code python -c urllib}); Java was
     * the only outlier, because it was written before those apps existed.
     *
     * <p>A JRE cannot run {@code java Health.java} — single-file source launch needs the compiler a JRE
     * does not ship — so the probe has to be a flag on this class, exactly like gowebapp's.
     *
     * <p>127.0.0.1, never "localhost": on some images localhost resolves to ::1 first, and an
     * IPv4-only listener would refuse the probe and mark the container unhealthy forever.
     */
    static int healthcheck(String port) {
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) URI.create("http://127.0.0.1:" + port + HEALTH_PATH).toURL().openConnection();
            conn.setConnectTimeout(PROBE_TIMEOUT_MS);
            conn.setReadTimeout(PROBE_TIMEOUT_MS);
            conn.setRequestMethod("GET");
            int status = conn.getResponseCode();
            if (status != HttpURLConnection.HTTP_OK) {
                System.err.println("healthcheck: status " + status);
                return UNHEALTHY;
            }
            return HEALTHY;
        } catch (Exception e) {
            System.err.println("healthcheck: " + e);
            return UNHEALTHY;
        } finally {
            if (conn != null) {
                conn.disconnect();
            }
        }
    }

    public static void main(String[] args) {
        // Short-circuit BEFORE SpringApplication.run: the probe must be a bare JVM start plus one
        // HTTP call, not a full Spring context boot, or it cannot finish inside the HEALTHCHECK
        // timeout and would cost a second application's worth of memory every interval.
        if (args.length > 0 && HEALTHCHECK_FLAG.equals(args[0])) {
            String port = System.getenv("APP_INTERNAL_PORT");
            System.exit(healthcheck(port == null || port.isBlank() ? DEFAULT_PORT : port));
        }
        SpringApplication.run(JavaWebappApplication.class, args);
    }
}
