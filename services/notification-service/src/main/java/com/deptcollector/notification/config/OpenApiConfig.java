package com.deptcollector.notification.config;

import io.swagger.v3.oas.models.Components;
import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.security.SecurityRequirement;
import io.swagger.v3.oas.models.security.SecurityScheme;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class OpenApiConfig {

    private static final String TENANT_HEADER = "X-Tenant-Id";

    @Bean
    public OpenAPI notificationOpenAPI() {
        return new OpenAPI()
                .info(new Info()
                        .title("Notification Service API")
                        .version("v1")
                        .description("Email delivery endpoints. "
                                + "Every request requires the X-Tenant-Id header — set it once via the Authorize button."))
                .addSecurityItem(new SecurityRequirement().addList(TENANT_HEADER))
                .components(new Components().addSecuritySchemes(TENANT_HEADER,
                        new SecurityScheme()
                                .type(SecurityScheme.Type.APIKEY)
                                .in(SecurityScheme.In.HEADER)
                                .name(TENANT_HEADER)
                                .description("Mandatory tenant identifier, e.g. tenant-demo")));
    }
}
