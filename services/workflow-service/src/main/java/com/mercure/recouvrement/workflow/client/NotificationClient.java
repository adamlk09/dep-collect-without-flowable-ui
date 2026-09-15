package com.mercure.recouvrement.workflow.client;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.util.Map;

@Component
public class NotificationClient {

    private static final Logger log = LoggerFactory.getLogger(NotificationClient.class);

    private final RestClient restClient;

    public NotificationClient(RestClient.Builder builder,
                              @Value("${app.notification-service.url:http://localhost:8095}") String baseUrl) {
        this.restClient = builder.baseUrl(baseUrl).build();
    }

    public void sendEmail(String tenantId, String to, String subject, String templateName,
                          Map<String, String> variables, String triggerType) {
        try {
            restClient.post()
                    .uri("/api/v1/notifications/email")
                    .header("X-Tenant-Id", tenantId)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(new SendEmailRequest(to, subject, templateName, variables, triggerType))
                    .retrieve()
                    .toBodilessEntity();
        } catch (Exception e) {
            log.warn("notification-service unavailable, email not sent to={} template={}: {}",
                    to, templateName, e.getMessage());
        }
    }

    public record SendEmailRequest(String to, String subject, String templateName,
                                   Map<String, String> variables, String triggerType) {}
}
