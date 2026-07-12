package com.vmware.vks.demo.javawebapp;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

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
}
