package com.vmware.vks.demo.javawebapp;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;

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
}
