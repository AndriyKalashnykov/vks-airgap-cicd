package com.vmware.vks.demo.javawebapp;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

/**
 * THE SHARED-UI CONTRACT PRODUCER (plan Phase B).
 *
 * <p>Owner requirement: every app renders the SAME layout, differing only in app-specific data.
 * Today this Thymeleaf template and gowebapp's inline html/template hold the CSS block VERBATIM
 * TWICE with nothing asserting they stay identical — measured byte-identical 2026-08-22, which is
 * exactly when to gate it rather than after the first drift. Six apps means six copies.
 *
 * <p>The contract is deliberately OBSERVABLE: each app renders with the fixed inputs below and
 * writes the result to $UI_CONTRACT_OUT; a language-agnostic gate masks the app-specific fields and
 * requires every app's output to be byte-identical. Comparing template SOURCES cannot work across
 * Thymeleaf / html-template / Razor / Jinja2 / JSX — only the rendered page is comparable.
 *
 * <p>Renders through the REAL Spring+Thymeleaf pipeline (MockMvc), not a hand-rolled TemplateEngine,
 * so the artifact is what a user would actually be served. Skipped unless the env var is set, so a
 * normal `mvn test` is unaffected.
 */
@WebMvcTest(HomeController.class)
@TestPropertySource(properties = {
        "spring.application.name=APPNAME",
        "app.message=MESSAGE",
        "info.app.version=VERSION",
        "info.app.declared-version=APPVERSION",
        "info.app.commit=COMMIT"
})
@EnabledIfEnvironmentVariable(named = "UI_CONTRACT_OUT", matches = ".+")
class UiContractRenderTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void writeRenderedPage() throws Exception {
        String html = mockMvc.perform(get("/"))
                .andReturn()
                .getResponse()
                .getContentAsString();
        Files.writeString(Path.of(System.getenv("UI_CONTRACT_OUT")), html);
    }
}
