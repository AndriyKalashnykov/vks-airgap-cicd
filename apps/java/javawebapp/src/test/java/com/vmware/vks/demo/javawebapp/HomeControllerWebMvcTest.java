package com.vmware.vks.demo.javawebapp;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.web.servlet.MockMvc;

/** Slim controller-slice test: no full context, no server socket. */
@WebMvcTest(HomeController.class)
@TestPropertySource(properties = {
        "app.message=Hello from web mvc test",
        "info.app.version=9.9.9",
        "info.app.commit=abc1234"
})
class HomeControllerWebMvcTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void indexRendersGreetingVersionAndCommit() throws Exception {
        mockMvc.perform(get("/"))
                .andExpect(status().isOk())
                .andExpect(content().string(org.hamcrest.Matchers.containsString("Hello from web mvc test")))
                .andExpect(content().string(org.hamcrest.Matchers.containsString("9.9.9")))
                .andExpect(content().string(org.hamcrest.Matchers.containsString("abc1234")));
    }

    /**
     * The icon route must answer at the path the RENDERED PAGE points to — extracted from the page,
     * never typed as a literal here.
     *
     * <p>{@code make check-ui-contract} proves {@code href="/favicon.svg"} is byte-identical in all
     * six apps and this proves a route answers; nothing else JOINS those two strings, so a
     * hardcoded path here would let a route registered elsewhere pass both gates over a broken
     * image. It also fixes the icon route to HomeController: this is a SLICED
     * {@code @WebMvcTest(HomeController.class)}, so a route on any other bean would 404 here.
     */
    @Test
    void iconRouteAnswersAtTheHrefThePageRenders() throws Exception {
        String body = mockMvc.perform(get("/"))
                .andExpect(status().isOk())
                .andReturn().getResponse().getContentAsString();

        Matcher m = Pattern.compile("<link rel=\"icon\"[^>]*href=\"([^\"]+)\"").matcher(body);
        Assertions.assertTrue(m.find(), "the rendered page has no <link rel=\"icon\" ... href=\"...\">");
        String href = m.group(1);

        mockMvc.perform(get(href))
                .andExpect(status().isOk())
                .andExpect(content().contentTypeCompatibleWith("image/svg+xml"))
                // Compared against the app's OWN constant, so the colour lives in exactly ONE place.
                .andExpect(content().string(HomeController.ICON));

        Assertions.assertTrue(body.contains("src=\"" + href + "\""),
                "the <img> and the <link> disagree");
    }
}
