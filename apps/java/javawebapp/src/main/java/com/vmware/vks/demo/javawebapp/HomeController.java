package com.vmware.vks.demo.javawebapp;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.ResponseBody;

/**
 * Renders the demo landing page. The greeting {@code message} is the value we
 * change between deploys to demonstrate the GitOps CD flow visibly in the UI.
 */
@Controller
public class HomeController {

    private final String appName;
    private final String message;
    private final String version;
    private final String commit;

    public HomeController(
            @Value("${spring.application.name:javawebapp}") String appName,
            @Value("${app.message:Hello from vks-airgap-cicd}") String message,
            @Value("${info.app.version:dev}") String version,
            @Value("${info.app.commit:unknown}") String commit) {
        this.appName = appName;
        this.message = message;
        this.version = version;
        this.commit = commit;
    }

    @GetMapping("/")
    public String index(Model model) {
        model.addAttribute("appName", appName);
        model.addAttribute("message", message);
        model.addAttribute("version", version);
        model.addAttribute("commit", commit);
        return "index";
    }

    /**
     * The app's icon, served at a CONSTANT path.
     *
     * WHY A ROUTE AND NOT AN INLINE data: URI. Not because of any escaper -- a literal data URI in
     * the template survives Thymeleaf and Go's html/template untouched (measured). The reason is
     * `make check-ui-contract`: the six apps' rendered pages must be BYTE-IDENTICAL, so a per-app
     * icon CANNOT live in the shared markup at all. Behind a constant URL it can: the markup is the
     * same six times, and the per-app difference is the response body of this route.
     *
     * It lives on HomeController, not a new @RestController, because the UI-contract producer is a
     * SLICED @WebMvcTest(HomeController.class) -- a route on another bean would not load there.
     *
     * The colour is an APPROXIMATION of the language's brand family, not an official value, and the
     * label is an abbreviation ("Jv"), not a wordmark. `rgb()` not `#rrggbb`: `#` would truncate the
     * SVG at a URL fragment if anyone ever inlines it.
     */
    @GetMapping(value = "/favicon.svg", produces = "image/svg+xml")
    @ResponseBody
    public String favicon() {
        return ICON;
    }

    static final String ICON = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="32" height="32" role="img" aria-label="javawebapp"><rect width="32" height="32" rx="7" fill="rgb(240,138,32)"/><text x="16" y="21" text-anchor="middle" font-family="system-ui,sans-serif" font-size="13" font-weight="700" fill="rgb(255,255,255)">Jv</text></svg>""";
}
