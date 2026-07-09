package com.vmware.vks.demo.webui;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/** Entry point for the air-gapped VKS CI/CD demo web UI. */
@SpringBootApplication
public class WebuiApplication {

    public static void main(String[] args) {
        SpringApplication.run(WebuiApplication.class, args);
    }
}
