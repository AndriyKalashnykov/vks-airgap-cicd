package com.vmware.vks.demo.javawebapp;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.resttestclient.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

/**
 * Full-context integration test on a real server socket (RANDOM_PORT so parallel
 * runs never collide). Asserts the landing page renders the greeting and the
 * actuator health endpoint reports UP.
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = "app.message=Hello from integration test")
class JavaWebappApplicationIntegrationTest {

    @LocalServerPort
    private int port;

    private final TestRestTemplate rest = new TestRestTemplate();

    private String url(String path) {
        return "http://127.0.0.1:" + port + path;
    }

    @Test
    void rootReturns200AndRendersGreeting() {
        ResponseEntity<String> resp = rest.getForEntity(url("/"), String.class);
        assertThat(resp.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(resp.getBody()).contains("Hello from integration test");
    }

    @Test
    void actuatorHealthReturns200AndStatusUp() {
        ResponseEntity<String> resp = rest.getForEntity(url("/actuator/health"), String.class);
        assertThat(resp.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(resp.getBody()).contains("\"status\":\"UP\"");
    }

    @Test
    void livenessAndReadinessProbesUp() {
        assertThat(rest.getForEntity(url("/actuator/health/liveness"), String.class).getBody())
                .contains("\"status\":\"UP\"");
        assertThat(rest.getForEntity(url("/actuator/health/readiness"), String.class).getBody())
                .contains("\"status\":\"UP\"");
    }

    @Test
    void unknownPathReturns404() {
        ResponseEntity<String> resp = rest.getForEntity(url("/no-such-page"), String.class);
        assertThat(resp.getStatusCode()).isEqualTo(HttpStatus.NOT_FOUND);
    }
}
